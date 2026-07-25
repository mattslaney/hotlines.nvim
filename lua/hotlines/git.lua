local M = {}

local root_pending = {}
local branch_cache = {}
local branch_pending = {}
local detected_cache = {}
local detected_pending = {}
local merge_base_cache = {}
local merge_base_pending = {}
local blob_cache = {}
local blob_pending = {}
local detection_epoch = 0
local comparison_epoch = 0

local function trim(value)
  return (value:gsub("%s+$", ""))
end

local function finish(callback, ...)
  local args = { ... }
  vim.schedule(function()
    callback(unpack(args))
  end)
end

function M.run(args, cwd, callback)
  local command = { "git" }
  vim.list_extend(command, args)

  if vim.system then
    vim.system(command, { cwd = cwd, text = true }, function(result)
      finish(callback, result.code, result.stdout or "", result.stderr or "")
    end)
    return
  end

  local stdout = {}
  local stderr = {}
  local job = vim.fn.jobstart(command, {
    cwd = cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data or {}
    end,
    on_stderr = function(_, data)
      stderr = data or {}
    end,
    on_exit = function(_, code)
      finish(callback, code, table.concat(stdout, "\n"), table.concat(stderr, "\n"))
    end,
  })

  if job <= 0 then
    finish(callback, 1, "", "failed to start git")
  end
end

local function dispatch_pending(pending, key, ...)
  local callbacks = pending[key] or {}
  pending[key] = nil
  for _, callback in ipairs(callbacks) do
    callback(...)
  end
end

function M.repo_root(path, callback)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  local directory = stat and stat.type == "directory" and path or vim.fs.dirname(path)
  if root_pending[directory] then
    table.insert(root_pending[directory], callback)
    return
  end

  root_pending[directory] = { callback }
  M.run({ "rev-parse", "--show-toplevel" }, directory, function(code, stdout)
    local root = code == 0 and trim(stdout) or nil
    dispatch_pending(root_pending, directory, root)
  end)
end

function M.touched_files(repo, merge_base, callback)
  local paths = {}
  local remaining = 2
  local error_message

  local function collect(code, stdout, stderr)
    if code ~= 0 then
      error_message = error_message or trim(stderr)
    else
      for path in stdout:gmatch("[^\r\n]+") do
        paths[path] = true
      end
    end

    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    if error_message then
      callback(nil, error_message)
      return
    end

    local result = vim.tbl_keys(paths)
    table.sort(result)
    callback(result)
  end

  M.run(
    { "-c", "core.quotepath=false", "diff", "--name-only", "--diff-filter=ACMRTUXB", merge_base, "--" },
    repo,
    collect
  )
  M.run({ "-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard" }, repo, collect)
end

function M.branches(repo, callback)
  if branch_cache[repo] then
    callback(branch_cache[repo])
    return
  end
  if branch_pending[repo] then
    table.insert(branch_pending[repo], callback)
    return
  end

  branch_pending[repo] = { callback }
  M.run({ "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" }, repo, function(code, stdout)
    local branches = {}
    if code == 0 then
      for branch in stdout:gmatch("[^\r\n]+") do
        if not branch:match("/HEAD$") then
          branches[#branches + 1] = branch
        end
      end
    end
    branch_cache[repo] = branches
    dispatch_pending(branch_pending, repo, branches)
  end)
end

function M.cached_branches(repo)
  return branch_cache[repo] or {}
end

function M.resolve_branch(repo, branch, callback)
  local refs
  if vim.startswith(branch, "refs/") then
    refs = { branch }
  elseif branch:find("/", 1, true) then
    refs = { "refs/heads/" .. branch, "refs/remotes/" .. branch }
  else
    refs = { "refs/heads/" .. branch, "refs/remotes/origin/" .. branch }
  end

  local index = 1
  local function next_ref()
    local ref = refs[index]
    index = index + 1
    if not ref then
      callback(nil)
      return
    end
    M.run({ "rev-parse", "--verify", "--quiet", ref }, repo, function(code)
      if code == 0 then
        callback({ name = branch, ref = ref })
      else
        next_ref()
      end
    end)
  end
  next_ref()
end

local function branch_creation_source(repo, branch, callback)
  M.run({ "reflog", "show", "--format=%H%x00%gs", "refs/heads/" .. branch }, repo, function(code, stdout)
    if code ~= 0 then
      callback(nil, nil)
      return
    end

    local source
    local commit
    for entry in stdout:gmatch("[^\r\n]+") do
      local oid, message = entry:match("^([^%z]+)%z(.*)$")
      if oid then
        local created_from = message:match("^branch: Created from (.+)$")
        if created_from then
          source = created_from
          commit = oid
        end
      end
    end
    callback(source, commit)
  end)
end

local function checkout_creation_source(repo, branch, creation_commit, callback)
  M.run({ "reflog", "show", "--format=%H%x00%gs", "HEAD" }, repo, function(code, stdout)
    if code ~= 0 then
      callback(nil)
      return
    end

    local source
    for entry in stdout:gmatch("[^\r\n]+") do
      local oid, message = entry:match("^([^%z]+)%z(.*)$")
      if oid then
        local from, destination = message:match("^checkout: moving from (.+) to (.+)$")
        if oid == creation_commit and destination == branch then
          source = from
        end
      end
    end
    callback(source)
  end)
end

local function resolve_recorded_origin(repo, source, callback)
  local function verify(ref)
    M.run({ "rev-parse", "--verify", "--quiet", ref }, repo, function(code)
      callback(code == 0 and { name = source, ref = ref } or nil)
    end)
  end

  if vim.startswith(source, "refs/") then
    verify(source)
    return
  end
  if not source:find("/", 1, true) then
    verify("refs/heads/" .. source)
    return
  end

  M.run({ "remote" }, repo, function(code, stdout)
    local remote = source:match("^([^/]+)/")
    if code == 0 and remote and vim.tbl_contains(vim.split(trim(stdout), "\n", { trimempty = true }), remote) then
      verify("refs/remotes/" .. source)
    else
      verify("refs/heads/" .. source)
    end
  end)
end

local function resolve_origin(repo, branch, callback)
  branch_creation_source(repo, branch, function(source, creation_commit)
    if source == "HEAD" then
      checkout_creation_source(repo, branch, creation_commit, function(checkout_source)
        if checkout_source and checkout_source ~= "HEAD" then
          resolve_recorded_origin(repo, checkout_source, callback)
        else
          callback(nil)
        end
      end)
    elseif source then
      resolve_recorded_origin(repo, source, callback)
    else
      callback(nil)
    end
  end)
end

function M.detect_base(repo, callback)
  M.run({ "symbolic-ref", "--quiet", "--short", "HEAD" }, repo, function(code, stdout)
    local branch = code == 0 and trim(stdout) or nil
    if not branch or branch == "" then
      callback(nil)
      return
    end

    local epoch = detection_epoch
    local key = repo .. "\0" .. branch
    local pending_key = key .. "\0" .. epoch
    local cached = detected_cache[key]
    if cached ~= nil then
      callback(cached or nil)
      return
    end
    if detected_pending[pending_key] then
      table.insert(detected_pending[pending_key], callback)
      return
    end

    detected_pending[pending_key] = { callback }
    resolve_origin(repo, branch, function(base)
      base = base or { name = branch, ref = "refs/heads/" .. branch }
      if epoch == detection_epoch then
        detected_cache[key] = base
      end
      dispatch_pending(detected_pending, pending_key, base)
    end)
  end)
end

function M.merge_base(repo, base_ref, callback)
  local epoch = comparison_epoch
  M.run({ "rev-parse", "--verify", "HEAD" }, repo, function(head_code, head_stdout, head_stderr)
    if epoch ~= comparison_epoch then
      callback(nil, "comparison invalidated")
      return
    end
    local head = head_code == 0 and trim(head_stdout) or nil
    if not head or head == "" then
      callback(nil, trim(head_stderr))
      return
    end

    local key = repo .. "\0" .. base_ref .. "\0" .. head
    if merge_base_cache[key] then
      callback(merge_base_cache[key])
      return
    end
    local pending_key = key .. "\0" .. epoch
    if merge_base_pending[pending_key] then
      table.insert(merge_base_pending[pending_key], callback)
      return
    end

    merge_base_pending[pending_key] = { callback }
    M.run({ "merge-base", base_ref, head }, repo, function(code, stdout, stderr)
      local merge_base = code == 0 and trim(stdout) or nil
      if epoch == comparison_epoch and merge_base and merge_base ~= "" then
        merge_base_cache[key] = merge_base
      end
      dispatch_pending(merge_base_pending, pending_key, merge_base, trim(stderr))
    end)
  end)
end

function M.base_blob(repo, merge_base, relative_path, callback)
  local epoch = comparison_epoch
  local key = repo .. "\0" .. merge_base .. "\0" .. relative_path
  if blob_cache[key] ~= nil then
    callback(blob_cache[key])
    return
  end
  local pending_key = key .. "\0" .. epoch
  if blob_pending[pending_key] then
    table.insert(blob_pending[pending_key], callback)
    return
  end

  blob_pending[pending_key] = { callback }
  M.run({ "show", merge_base .. ":" .. relative_path }, repo, function(code, stdout, stderr)
    local text
    local error_message
    if code == 0 then
      text = stdout
    elseif stderr:find("does not exist in", 1, true) or stderr:find("exists on disk, but not in", 1, true) then
      text = ""
    else
      error_message = trim(stderr)
    end
    if epoch == comparison_epoch and text ~= nil then
      blob_cache[key] = text
    end
    dispatch_pending(blob_pending, pending_key, text, error_message)
  end)
end

function M.clear_detected()
  detection_epoch = detection_epoch + 1
  detected_cache = {}
end

function M.invalidate_comparison(repo)
  comparison_epoch = comparison_epoch + 1
  for key in pairs(merge_base_cache) do
    if not repo or vim.startswith(key, repo .. "\0") then
      merge_base_cache[key] = nil
    end
  end
  for key in pairs(blob_cache) do
    if not repo or vim.startswith(key, repo .. "\0") then
      blob_cache[key] = nil
    end
  end
end

function M.reset()
  detection_epoch = detection_epoch + 1
  comparison_epoch = comparison_epoch + 1
  branch_cache = {}
  detected_cache = {}
  merge_base_cache = {}
  blob_cache = {}
end

return M
