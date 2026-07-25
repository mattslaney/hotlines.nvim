local config = require("hotlines.config")
local diff = require("hotlines.diff")
local git = require("hotlines.git")
local highlight = require("hotlines.highlight")

local M = {}

local buffers = {}
local warned_repos = {}
local warned_errors = {}
local registered_keymaps = {}
local hunk_diff_buffer
local open_hunk_diff
local preview_diff_lines
local render_unified_diff

local function close_timer(state)
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

local function reset_buffers()
  for bufnr, state in pairs(buffers) do
    close_timer(state)
    highlight.clear(bufnr)
  end
  buffers = {}
end

local function state_for(bufnr)
  local state = buffers[bufnr]
  if not state then
    state = {
      enabled = config.get().enabled_on_start,
      generation = 0,
      ranges = {},
      hunks = {},
      deletions = {},
      base_text = nil,
    }
    buffers[bufnr] = state
  end
  return state
end

local function current(state, bufnr, generation)
  return buffers[bufnr] == state
    and state.enabled
    and state.generation == generation
    and vim.api.nvim_buf_is_valid(bufnr)
end

local function notify_once(key, message)
  if warned_errors[key] then
    return
  end
  warned_errors[key] = true
  vim.notify(message, vim.log.levels.WARN)
end

local function buffer_text(bufnr, stat)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 1 and lines[1] == "" and (vim.bo[bufnr].modified or (stat and stat.size == 0)) then
    return ""
  end
  local text = table.concat(lines, "\n")
  if #lines > 0 and vim.bo[bufnr].endofline then
    text = text .. "\n"
  end
  return text
end

local function relative_path(root, path)
  root = vim.fs.normalize(root)
  path = vim.fs.normalize(path)
  if path == root then
    return nil
  end
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  if not vim.startswith(path, prefix) then
    return nil
  end
  return path:sub(#prefix + 1)
end

local function resolve_base(repo, callback)
  local options = config.get()
  if options.base then
    git.resolve_branch(repo, options.base, function(base)
      if not base then
        notify_once(
          repo .. "\0configured\0" .. options.base,
          "hotlines.nvim: base branch '" .. options.base .. "' does not exist"
        )
      end
      callback(base)
    end)
    return
  end

  git.detect_base(repo, function(base)
    if not base and not warned_repos[repo] then
      warned_repos[repo] = true
      vim.notify(
        "hotlines.nvim: no base branch found; use :HotlinesSetBase {branch}",
        vim.log.levels.WARN
      )
    end
    callback(base)
  end)
end

function M.refresh(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local state = state_for(bufnr)
  if not state.enabled then
    highlight.clear(bufnr)
    return
  end

  state.generation = state.generation + 1
  local generation = state.generation

  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    state.repo = nil
    state.base = nil
    state.merge_base = nil
    state.ranges = {}
    state.hunks = {}
    state.deletions = {}
    state.base_text = nil
    highlight.clear(bufnr)
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local uv = vim.uv or vim.loop
  local link_stat = path ~= "" and uv.fs_lstat(path) or nil
  local stat = path ~= "" and uv.fs_stat(path) or nil
  if not stat or stat.type ~= "file" or not link_stat or link_stat.type == "link" then
    state.repo = nil
    state.base = nil
    state.merge_base = nil
    state.ranges = {}
    state.hunks = {}
    state.deletions = {}
    state.base_text = nil
    highlight.clear(bufnr)
    return
  end

  local text = buffer_text(bufnr, stat)
  git.repo_root(path, function(repo)
    if not current(state, bufnr, generation) then
      return
    end
    if not repo then
      state.repo = nil
      state.base = nil
      state.merge_base = nil
      state.ranges = {}
      state.hunks = {}
      state.deletions = {}
      state.base_text = nil
      highlight.clear(bufnr)
      return
    end

    state.repo = repo
    git.branches(repo, function() end)
    local relative = relative_path(repo, path)
    if not relative then
      state.base = nil
      state.merge_base = nil
      state.ranges = {}
      state.hunks = {}
      state.deletions = {}
      state.base_text = nil
      highlight.clear(bufnr)
      return
    end

    resolve_base(repo, function(base)
      if not current(state, bufnr, generation) then
        return
      end
      state.base = base and base.name or nil
      if not base then
        state.merge_base = nil
        state.ranges = {}
        state.hunks = {}
        state.deletions = {}
        state.base_text = nil
        highlight.clear(bufnr)
        return
      end

      if opts.force then
        git.invalidate_comparison(repo)
      end
      git.merge_base(repo, base.ref, function(merge_base, error_message)
        if not current(state, bufnr, generation) then
          return
        end
        if not merge_base then
          state.merge_base = nil
          state.ranges = {}
          state.hunks = {}
          state.deletions = {}
          state.base_text = nil
          highlight.clear(bufnr)
          notify_once(
            repo .. "\0" .. base.ref,
            "hotlines.nvim: cannot resolve merge base for '" .. base.name .. "'"
              .. (error_message ~= "" and ": " .. error_message or "")
          )
          return
        end
        state.merge_base = merge_base

        git.base_blob(repo, merge_base, relative, function(base_text, blob_error)
          if not current(state, bufnr, generation) then
            return
          end
          if base_text == nil then
            state.ranges = {}
            state.hunks = {}
            state.deletions = {}
            state.base_text = nil
            highlight.clear(bufnr)
            notify_once(
              repo .. "\0blob\0" .. merge_base .. "\0" .. relative,
              "hotlines.nvim: cannot read base version of '" .. relative .. "'"
                .. (blob_error and blob_error ~= "" and ": " .. blob_error or "")
            )
            return
          end
          local hunks, diff_error = diff.changed_hunks(base_text, text)
          if not hunks then
            state.ranges = {}
            state.hunks = {}
            state.deletions = {}
            state.base_text = nil
            highlight.clear(bufnr)
            notify_once(repo .. "\0diff", "hotlines.nvim: diff failed: " .. tostring(diff_error))
            return
          end
          local ranges = {}
          local deletions = {}
          for _, hunk in ipairs(hunks) do
            if hunk.new_count > 0 then
              ranges[#ranges + 1] = { hunk.new_start, hunk.new_count }
            elseif hunk.old_count > 0 then
              deletions[#deletions + 1] = hunk
            end
          end
          state.ranges = ranges
          state.hunks = hunks
          state.deletions = deletions
          state.base_text = base_text
          local options = config.get()
          local groups = highlight.groups(options)
          local highlights = diff.changed_highlights(base_text, text, hunks)
          highlight.render(
            bufnr,
            highlights,
            groups.added,
            groups.changed,
            groups.changed_text,
            groups.deleted
          )
        end)
      end)
    end)
  end)
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = state_for(bufnr)
  state.enabled = true
  M.refresh(bufnr)
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = state_for(bufnr)
  state.enabled = false
  state.generation = state.generation + 1
  if state.timer then
    state.timer:stop()
  end
  state.ranges = {}
  state.hunks = {}
  state.deletions = {}
  state.base_text = nil
  highlight.clear(bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if state_for(bufnr).enabled then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

function M.set_base(base)
  if base == "" then
    base = nil
  end
  config.set_base(base)
  git.clear_detected()
  git.invalidate_comparison()
  warned_repos = {}
  warned_errors = {}

  for bufnr, state in pairs(buffers) do
    if state.enabled and vim.api.nvim_buf_is_valid(bufnr) then
      M.refresh(bufnr)
    end
  end
end

function M.set_theme(theme)
  config.set_theme(theme)
  highlight.prepare(config.get())
  for bufnr, state in pairs(buffers) do
    if state.enabled and vim.api.nvim_buf_is_valid(bufnr) then
      M.refresh(bufnr)
    end
  end
end

function M.is_enabled(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return state_for(bufnr).enabled
end

function M.info(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  local changed_lines = 0
  for _, range in ipairs(state and state.ranges or {}) do
    changed_lines = changed_lines + range[2]
  end

  local details = {
    enabled = state and state.enabled or config.get().enabled_on_start,
    repo = state and state.repo or nil,
    base = state and state.base or nil,
    merge_base = state and state.merge_base or nil,
    hunks = state and #state.hunks or 0,
    lines = changed_lines,
  }
  local message = table.concat({
    "Status: " .. (details.enabled and "enabled" or "disabled"),
    "Repository: " .. (details.repo or "unresolved"),
    "Base: " .. (details.base or "unresolved"),
    "Merge base: " .. (details.merge_base or "unresolved"),
    "Changed hunks: " .. details.hunks,
    "Changed lines: " .. details.lines,
  }, "\n")
  vim.notify(message, vim.log.levels.INFO, { title = "hotlines.nvim" })
  return details
end

function M.get_touched_files(callback, opts)
  opts = opts or {}
  vim.validate({
    callback = { callback, "function" },
    opts = { opts, "table" },
  })
  vim.validate({
    cwd = { opts.cwd, "string", true },
    bufnr = { opts.bufnr, "number", true },
  })

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  local path = opts.cwd or (state and state.repo)
  if not path and vim.api.nvim_buf_is_valid(bufnr) then
    path = vim.api.nvim_buf_get_name(bufnr)
  end
  if not path or path == "" then
    path = (vim.uv or vim.loop).cwd()
  end

  git.repo_root(path, function(repo)
    if not repo then
      callback(nil, "not inside a Git work tree")
      return
    end

    resolve_base(repo, function(base)
      if not base then
        callback(nil, "no base branch found")
        return
      end

      git.merge_base(repo, base.ref, function(merge_base, merge_error)
        if not merge_base then
          callback(nil, "cannot resolve merge base for '" .. base.name .. "'"
            .. (merge_error and merge_error ~= "" and ": " .. merge_error or ""))
          return
        end

        git.touched_files(repo, merge_base, function(paths, files_error)
          if not paths then
            callback(nil, files_error and files_error ~= "" and files_error or "cannot list touched files")
            return
          end

          local files = {}
          for index, relative in ipairs(paths) do
            files[index] = vim.fs.joinpath(repo, relative)
          end
          callback(files, nil, {
            repo = repo,
            base = base.name,
            merge_base = merge_base,
          })
        end)
      end)
    end)
  end)
end

local function loaded_buffer(path)
  local normalized = vim.fs.normalize(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) == normalized then
      return bufnr
    end
  end
end

local function read_file(path, callback)
  local uv = vim.uv or vim.loop
  uv.fs_open(path, "r", 438, function(open_error, fd)
    if open_error or not fd then
      vim.schedule(function()
        callback(nil, open_error or "cannot open file")
      end)
      return
    end
    uv.fs_fstat(fd, function(stat_error, stat)
      if stat_error or not stat then
        uv.fs_close(fd)
        vim.schedule(function()
          callback(nil, stat_error or "cannot read file")
        end)
        return
      end
      uv.fs_read(fd, stat.size, 0, function(read_error, text)
        uv.fs_close(fd)
        vim.schedule(function()
          callback(read_error and nil or (text or ""), read_error)
        end)
      end)
    end)
  end)
end

local function current_file_text(path, callback)
  local bufnr = loaded_buffer(path)
  if bufnr then
    vim.schedule(function()
      callback(buffer_text(bufnr))
    end)
    return
  end
  read_file(path, callback)
end

function M.get_touched_file_hunks(callback, opts)
  M.get_touched_files(function(files, files_error, context)
    if not files then
      callback(nil, files_error)
      return
    end
    if #files == 0 then
      callback({}, nil, context)
      return
    end

    local pending = #files
    local results = {}
    local function finish()
      pending = pending - 1
      if pending > 0 then
        return
      end
      local entries = {}
      for _, result in ipairs(results) do
        if result then
          entries[#entries + 1] = result
        end
      end
      callback(entries, nil, context)
    end

    for index, path in ipairs(files) do
      local relative = relative_path(context.repo, path)
      local base_text
      local current_text
      local completed = 0
      local function collect()
        completed = completed + 1
        if completed < 2 then
          return
        end
        if base_text ~= nil and current_text ~= nil then
          local hunks = diff.changed_hunks(base_text, current_text)
          if hunks then
            results[index] = {
              path = path,
              relative_path = relative,
              hunks = hunks,
              base_text = base_text,
              current_text = current_text,
            }
          end
        end
        finish()
      end

      git.base_blob(context.repo, context.merge_base, relative, function(text)
        base_text = text
        collect()
      end)
      current_file_text(path, function(text)
        current_text = text
        collect()
      end)
    end
  end, opts)
end

local function hunk_label(hunk)
  local start = hunk.new_count == 0 and hunk.old_start or hunk.new_start
  local count = hunk.new_count == 0 and hunk.old_count or hunk.new_count
  local span = count <= 1 and tostring(start) or string.format("%d-%d", start, start + count - 1)
  return (hunk.new_count == 0 and "Deleted lines " or "Lines ") .. span
end

local function hunk_description(hunk)
  if hunk.old_count == 0 then
    return "+" .. hunk.new_count
  end
  if hunk.new_count == 0 then
    return "-" .. hunk.old_count
  end
  return string.format("-%d +%d", hunk.old_count, hunk.new_count)
end

local function file_change_counts(hunks)
  local counts = { added = 0, deleted = 0, modified = 0 }
  for _, hunk in ipairs(hunks) do
    counts.modified = counts.modified + math.min(hunk.old_count, hunk.new_count)
    counts.added = counts.added + math.max(hunk.new_count - hunk.old_count, 0)
    counts.deleted = counts.deleted + math.max(hunk.old_count - hunk.new_count, 0)
  end
  return counts
end

local function file_icon(path)
  local name = vim.fs.basename(path)
  local ok, icons = pcall(require, "mini.icons")
  if ok and type(icons.get) == "function" then
    local icon, group = icons.get("file", name)
    if icon and icon ~= "" then
      return icon, group
    end
  end
  ok, icons = pcall(require, "nvim-web-devicons")
  if ok and type(icons.get_icon) == "function" then
    local icon, group = icons.get_icon(name, vim.fn.fnamemodify(name, ":e"), { default = true })
    if icon and icon ~= "" then
      return icon, group
    end
  end
end

local function line_span(start, count)
  return count <= 1 and tostring(start) or string.format("%d-%d", start, start + count - 1)
end

local function hunk_search_text(hunk)
  return table.concat({
    hunk_label(hunk),
    hunk_description(hunk),
    "Base lines " .. line_span(hunk.old_start, hunk.old_count),
    "Current lines " .. line_span(hunk.new_start, hunk.new_count),
  }, " "):lower()
end

local function filtered_touched_files(files, query)
  query = query:lower()
  if query == "" then
    return files
  end
  local filtered = {}
  for _, file in ipairs(files) do
    if file.relative_path:lower():find(query, 1, true) then
      filtered[#filtered + 1] = file
    else
      local hunks = {}
      for _, hunk in ipairs(file.hunks) do
        if hunk_search_text(hunk):find(query, 1, true) then
          hunks[#hunks + 1] = hunk
        end
      end
      if #hunks > 0 then
        filtered[#filtered + 1] = {
          path = file.path,
          relative_path = file.relative_path,
          hunks = hunks,
          base_text = file.base_text,
          current_text = file.current_text,
        }
      end
    end
  end
  return filtered
end

local function touched_file_tree(files)
  local roots = {}
  local folders = {}
  for _, file in ipairs(files) do
    local children = roots
    local path = ""
    local parts = vim.split(file.relative_path, "/", { plain = true })
    for index, component in ipairs(parts) do
      local is_file = index == #parts
      if is_file then
        children[#children + 1] = { kind = "file", id = "file:" .. file.path, file = file }
      else
        path = path == "" and component or path .. "/" .. component
        local folder = folders[path]
        if not folder then
          folder = { kind = "folder", id = "folder:" .. path, label = component, children = {} }
          folders[path] = folder
          children[#children + 1] = folder
        end
        children = folder.children
      end
    end
  end
  local function sort(nodes)
    table.sort(nodes, function(left, right)
      if left.kind == "folder" and right.kind ~= "folder" then
        return true
      end
      if left.kind ~= "folder" and right.kind == "folder" then
        return false
      end
      local left_label = left.label or left.file.relative_path
      local right_label = right.label or right.file.relative_path
      return left_label < right_label
    end)
    for _, node in ipairs(nodes) do
      if node.kind == "folder" then
        sort(node.children)
      end
    end
  end
  sort(roots)
  return roots
end

function M.open_touched_files()
  local existing = vim.fn.bufnr("Hotlines Touched Files")
  if existing ~= -1 then
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(winid) == existing then
        vim.api.nvim_set_current_win(winid)
        return
      end
    end
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
  local source_win = vim.api.nvim_get_current_win()
  local source_bufnr = vim.api.nvim_win_get_buf(source_win)
  local panel = { files = {}, items = {}, query = "", view_mode = "list", expanded = {}, closing = false }
  panel.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[panel.bufnr].buftype = "nofile"
  vim.bo[panel.bufnr].bufhidden = "wipe"
  vim.bo[panel.bufnr].swapfile = false
  vim.bo[panel.bufnr].modifiable = false
  vim.bo[panel.bufnr].filetype = "hotlines"
  vim.api.nvim_buf_set_name(panel.bufnr, "Hotlines Touched Files")
  local total_width = math.min(math.max(math.floor(vim.o.columns * 0.9), 3), math.max(vim.o.columns - 4, 3))
  local gap = 1
  local panel_width = math.max(math.floor((total_width - gap) * 0.38), 1)
  local preview_width = math.max(total_width - gap - panel_width, 1)
  local height = math.min(math.max(math.floor(vim.o.lines * 0.65), 1), math.max(vim.o.lines - 4, 1))
  local panel_height = math.max(height - 3, 1)
  local col = math.max(math.floor((vim.o.columns - total_width) / 2), 0)
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
  panel.filter_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[panel.filter_bufnr].buftype = "nofile"
  vim.bo[panel.filter_bufnr].bufhidden = "wipe"
  vim.bo[panel.filter_bufnr].swapfile = false
  vim.bo[panel.filter_bufnr].filetype = "hotlinesfilter"
  vim.api.nvim_buf_set_name(panel.filter_bufnr, "Hotlines Touched Files Filter")
  panel.filter_win = vim.api.nvim_open_win(panel.filter_bufnr, false, {
    relative = "editor",
    width = panel_width,
    height = 1,
    row = row + panel_height + 2,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Filter ",
    title_pos = "left",
  })
  panel.win = vim.api.nvim_open_win(panel.bufnr, true, {
    relative = "editor",
    width = panel_width,
    height = panel_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Hotlines Touched Files ",
    title_pos = "center",
  })
  vim.wo[panel.win].cursorline = true
  vim.wo[panel.win].wrap = false
  panel.preview_bufnr = hunk_diff_buffer({ " Loading Hotlines touched files..." }, "diff")
  vim.api.nvim_buf_set_name(panel.preview_bufnr, "Hotlines Touched Files Preview")
  vim.bo[panel.preview_bufnr].readonly = true
  panel.preview_win = vim.api.nvim_open_win(panel.preview_bufnr, false, {
    relative = "editor",
    width = preview_width,
    height = height,
    row = row,
    col = col + panel_width + gap,
    style = "minimal",
    border = "rounded",
    title = " Unified Diff Preview ",
    title_pos = "center",
    focusable = false,
  })
  vim.wo[panel.preview_win].wrap = false

  local update_preview
  local icon_namespace = vim.api.nvim_create_namespace("hotlines_touched_file_icons")
  local badge_namespace = vim.api.nvim_create_namespace("hotlines_touched_file_badges")

  local function item_key(item)
    if not item then
      return
    end
    if item.kind == "hunk" then
      return table.concat({ item.path, item.hunk.old_start, item.hunk.new_start }, ":")
    end
    return item.id
  end

  local function render()
    if not vim.api.nvim_buf_is_valid(panel.bufnr) then
      return
    end
    local cursor_line = vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_win_get_cursor(panel.win)[1] or 1
    local selected_key = item_key(panel.items[cursor_line])
    local lines = {
      " Hotlines Touched Files [" .. panel.view_mode .. "]",
      " <CR> open  o toggle  a expand all  c collapse all  t list/tree  f filter  <C-d/u> preview  r refresh  d diff  q close",
      " ",
    }
    panel.items = {}
    panel.icon_highlights = {}
    panel.badge_highlights = {}

    local function append_file(file, depth, label)
      local id = "file:" .. file.path
      local expanded = panel.query ~= "" or panel.expanded[id]
      local marker = #file.hunks == 0 and " " or (expanded and "v" or ">")
      local prefix = " " .. string.rep("  ", depth) .. marker .. " "
      local icon, icon_group = file_icon(file.path)
      local icon_text = icon and icon .. "  " or ""
      local file_label = label or file.relative_path
      local counts = file_change_counts(file.hunks)
      local summary = string.format("+%d -%d ~%d", counts.added, counts.deleted, counts.modified)
      local summary_col = #(prefix .. icon_text .. file_label .. "  ")
      lines[#lines + 1] = prefix .. icon_text .. file_label .. "  " .. summary
      if icon and icon_group then
        panel.icon_highlights[#panel.icon_highlights + 1] = {
          line = #lines - 1,
          start_col = #prefix,
          end_col = #prefix + #icon,
          group = icon_group,
        }
      end
      local added = "+" .. counts.added
      local deleted = "-" .. counts.deleted
      panel.badge_highlights[#panel.badge_highlights + 1] = {
        line = #lines - 1,
        start_col = summary_col,
        end_col = summary_col + #added,
        group = "DiffAdd",
      }
      panel.badge_highlights[#panel.badge_highlights + 1] = {
        line = #lines - 1,
        start_col = summary_col + #added + 1,
        end_col = summary_col + #added + 1 + #deleted,
        group = "DiffDelete",
      }
      panel.badge_highlights[#panel.badge_highlights + 1] = {
        line = #lines - 1,
        start_col = summary_col + #added + #deleted + 2,
        end_col = summary_col + #summary,
        group = "DiffChange",
      }
      panel.items[#lines] = {
        kind = "file",
        id = id,
        path = file.path,
        has_hunks = #file.hunks > 0,
        file = file,
      }
      if expanded then
        for _, hunk in ipairs(file.hunks) do
          lines[#lines + 1] = " " .. string.rep("  ", depth + 1) .. "  " .. hunk_label(hunk) .. "  " .. hunk_description(hunk)
          panel.items[#lines] = {
            kind = "hunk",
            path = file.path,
            hunk = hunk,
            base_text = file.base_text,
            current_text = file.current_text,
            file = file,
          }
        end
      end
    end

    local function append_node(node, depth)
      if node.kind == "file" then
        append_file(node.file, depth, vim.fs.basename(node.file.relative_path))
        return
      end
      local expanded = panel.query ~= "" or panel.expanded[node.id]
      lines[#lines + 1] = " " .. string.rep("  ", depth) .. (expanded and "v" or ">") .. " " .. node.label .. "/"
      panel.items[#lines] = { kind = "folder", id = node.id }
      if expanded then
        for _, child in ipairs(node.children) do
          append_node(child, depth + 1)
        end
      end
    end

    local files = filtered_touched_files(panel.files, panel.query)
    if panel.view_mode == "tree" then
      for _, node in ipairs(touched_file_tree(files)) do
        append_node(node, 0)
      end
    else
      for _, file in ipairs(files) do
        append_file(file, 0)
      end
    end
    if #panel.items == 0 then
      lines[#lines + 1] = panel.query == "" and " No touched files." or " No touched files match the filter."
    end
    vim.bo[panel.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(panel.bufnr, 0, -1, false, lines)
    vim.bo[panel.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(panel.bufnr, icon_namespace, 0, -1)
    for _, item in ipairs(panel.icon_highlights) do
      vim.api.nvim_buf_add_highlight(
        panel.bufnr,
        icon_namespace,
        item.group,
        item.line,
        item.start_col,
        item.end_col
      )
    end
    vim.api.nvim_buf_clear_namespace(panel.bufnr, badge_namespace, 0, -1)
    for _, item in ipairs(panel.badge_highlights) do
      vim.api.nvim_buf_add_highlight(
        panel.bufnr,
        badge_namespace,
        item.group,
        item.line,
        item.start_col,
        item.end_col
      )
    end
    panel.preview_key = nil
    if vim.api.nvim_win_is_valid(panel.win) then
      local target_line
      for line = 1, #lines do
        if selected_key and item_key(panel.items[line]) == selected_key then
          target_line = line
          break
        end
      end
      if not target_line then
        for line = 1, #lines do
          if panel.items[line] and panel.items[line].kind ~= "folder" then
            target_line = line
            break
          end
        end
      end
      if target_line then
        vim.api.nvim_win_set_cursor(panel.win, { target_line, 0 })
      end
    end
    if update_preview then
      update_preview()
    end
  end

  update_preview = function()
    if not vim.api.nvim_win_is_valid(panel.win) or not vim.api.nvim_buf_is_valid(panel.preview_bufnr) then
      return
    end
    local item = panel.items[vim.api.nvim_win_get_cursor(panel.win)[1]]
    local key = item and item.kind ~= "folder"
      and table.concat({ item.path, item.kind, item.hunk and item.hunk.old_start or 0, item.hunk and item.hunk.new_start or 0 }, ":")
      or "empty"
    if panel.preview_key == key then
      return
    end
    panel.preview_key = key
    if not item or item.kind == "folder" then
      vim.api.nvim_win_set_config(panel.preview_win, { title = " Unified Diff Preview " })
      render_unified_diff(panel.preview_bufnr, { "Select a file or hunk to preview." }, nil, nil, true)
      return
    end
    local title = item.file.relative_path
    if item.hunk then
      title = title .. " - " .. hunk_label(item.hunk)
    end
    vim.api.nvim_win_set_config(panel.preview_win, { title = " " .. title .. " " })
    local lines, line_map = preview_diff_lines(item.file, item.hunk)
    render_unified_diff(panel.preview_bufnr, lines, item.file, line_map, true)
    if vim.api.nvim_win_is_valid(panel.preview_win) then
      local preview_line = 1
      if item.hunk then
        for index, line in ipairs(lines) do
          if vim.startswith(line, "@@") then
            preview_line = index
            break
          end
        end
      end
      vim.api.nvim_win_set_cursor(panel.preview_win, { preview_line, 0 })
      if item.hunk then
        vim.api.nvim_win_call(panel.preview_win, function() vim.cmd("normal! zt") end)
      end
    end
  end

  local function refresh()
    panel.refresh_id = (panel.refresh_id or 0) + 1
    local refresh_id = panel.refresh_id
    vim.bo[panel.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(panel.bufnr, 0, -1, false, { " Loading Hotlines touched files..." })
    vim.bo[panel.bufnr].modifiable = false
    M.get_touched_file_hunks(function(files, error_message)
      if not vim.api.nvim_buf_is_valid(panel.bufnr) or refresh_id ~= panel.refresh_id then
        return
      end
      if not files then
        vim.notify("hotlines.nvim: " .. error_message, vim.log.levels.WARN)
        return
      end
      panel.files = files
      render()
    end, { bufnr = source_bufnr })
  end

  local function open_item()
    local item = panel.items[vim.api.nvim_win_get_cursor(0)[1]]
    if not item then
      return
    end
    if item.kind == "folder" then
      panel.expanded[item.id] = not panel.expanded[item.id] or nil
      render()
      return
    end
    if not vim.api.nvim_win_is_valid(source_win) then
      return
    end
    vim.api.nvim_win_call(source_win, function()
      vim.cmd.edit(vim.fn.fnameescape(item.path))
      if item.hunk then
        local line_count = vim.api.nvim_buf_line_count(0)
        local line = item.hunk.new_start
        vim.api.nvim_win_set_cursor(0, { math.min(math.max(line, 1), line_count), 0 })
      end
    end)
  end

  local function toggle_item()
    local item = panel.items[vim.api.nvim_win_get_cursor(0)[1]]
    if not item or (item.kind == "file" and not item.has_hunks) or item.kind == "hunk" then
      return
    end
    panel.expanded[item.id] = not panel.expanded[item.id] or nil
    render()
  end

  local function set_expansion(expanded)
    panel.expanded = {}
    if expanded then
      for _, file in ipairs(panel.files) do
        panel.expanded["file:" .. file.path] = true
        local path = ""
        local parts = vim.split(file.relative_path, "/", { plain = true })
        for index, component in ipairs(parts) do
          if index == #parts then
            break
          end
          path = path == "" and component or path .. "/" .. component
          panel.expanded["folder:" .. path] = true
        end
      end
    end
    render()
  end

  local function close_panel(restore_source)
    if panel.closing then
      return
    end
    panel.closing = true
    for _, winid in ipairs({ panel.preview_win, panel.filter_win, panel.win }) do
      if vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    for _, bufnr in ipairs({ panel.preview_bufnr, panel.filter_bufnr, panel.bufnr }) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    if restore_source and vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
    end
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = panel.bufnr,
    callback = update_preview,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = panel.filter_bufnr,
    callback = function()
      local query = vim.api.nvim_buf_get_lines(panel.filter_bufnr, 0, 1, false)[1] or ""
      if query ~= panel.query then
        panel.query = query
        render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = { tostring(panel.win), tostring(panel.filter_win), tostring(panel.preview_win) },
    once = true,
    callback = function() close_panel(false) end,
  })

  vim.keymap.set("n", "q", function() close_panel(true) end, { buffer = panel.bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "r", refresh, { buffer = panel.bufnr, nowait = true, silent = true })
  local function scroll_preview(key)
    if vim.api.nvim_win_is_valid(panel.preview_win) then
      vim.api.nvim_win_call(panel.preview_win, function()
        vim.cmd("normal! " .. vim.keycode(key))
      end)
    end
  end
  vim.keymap.set("n", "<C-d>", function() scroll_preview("<C-d>") end, { buffer = panel.bufnr, silent = true })
  vim.keymap.set("n", "<C-u>", function() scroll_preview("<C-u>") end, { buffer = panel.bufnr, silent = true })
  vim.keymap.set("n", "f", function()
    if vim.api.nvim_win_is_valid(panel.filter_win) then
      vim.api.nvim_set_current_win(panel.filter_win)
      vim.api.nvim_win_set_cursor(panel.filter_win, { 1, #(vim.api.nvim_get_current_line()) })
      vim.cmd.startinsert()
    end
  end, { buffer = panel.bufnr, nowait = true, silent = true })
  local function leave_filter()
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(panel.win) then
      vim.api.nvim_set_current_win(panel.win)
    end
  end
  for _, key in ipairs({ "<CR>", "<Esc>", "<C-c>" }) do
    vim.keymap.set("i", key, leave_filter, { buffer = panel.filter_bufnr, nowait = true, silent = true })
  end
  vim.keymap.set("n", "<CR>", leave_filter, { buffer = panel.filter_bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "q", function() close_panel(true) end, { buffer = panel.filter_bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", open_item, { buffer = panel.bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "o", toggle_item, { buffer = panel.bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "a", function() set_expansion(true) end, { buffer = panel.bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "c", function() set_expansion(false) end, { buffer = panel.bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "t", function()
    panel.view_mode = panel.view_mode == "tree" and "list" or "tree"
    render()
  end, { buffer = panel.bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "d", function()
    local item = panel.items[vim.api.nvim_win_get_cursor(0)[1]]
    if item and item.hunk then
      open_hunk_diff(item.base_text, item.current_text, item.hunk, vim.filetype.match({ filename = item.path }), vim.api.nvim_get_current_win())
    end
  end, { buffer = panel.bufnr, nowait = true, silent = true })
  refresh()
end

function M.navigate(direction, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  local ranges = state and state.ranges or {}
  if #ranges == 0 then
    vim.notify("hotlines.nvim: no changed hunks", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local destination
  if direction == "next" then
    for _, range in ipairs(ranges) do
      if range[1] > line then
        destination = range[1]
        break
      end
    end
    destination = destination or ranges[1][1]
  elseif direction == "prev" then
    for index = #ranges, 1, -1 do
      if ranges[index][1] < line then
        destination = ranges[index][1]
        break
      end
    end
    destination = destination or ranges[#ranges][1]
  else
    error("hotlines.nvim: direction must be 'next' or 'prev'")
  end

  vim.api.nvim_win_set_cursor(0, { destination, 0 })
end

local function base_lines(text)
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  if vim.endswith(text, "\n") then
    table.remove(lines)
  end
  return lines
end

local function hunk_context_lines(lines, start, count, empty_message)
  if #lines == 0 then
    return { empty_message }
  end
  local context = 3
  local first = math.max(start - context, 1)
  local last = math.min(start + math.max(count, 1) - 1 + context, #lines)
  local result = {}
  for line = first, last do
    result[#result + 1] = lines[line]
  end
  return result
end

local unified_diff_namespace = vim.api.nvim_create_namespace("hotlines_unified_diff")
local unified_diff_syntax_namespace = vim.api.nvim_create_namespace("hotlines_unified_diff_syntax")

local function unified_diff_lines(base_text, current_text, context)
  local text = vim.diff(base_text, current_text, {
    result_type = "unified",
    ctxlen = context,
    algorithm = "histogram",
  })
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  if vim.endswith(text, "\n") then
    table.remove(lines)
  end
  return #lines == 0 and { "(No differences)" } or lines
end

local function source_syntax_spans(file, side)
  file.syntax_spans = file.syntax_spans or {}
  if file.syntax_spans[side] then
    return file.syntax_spans[side]
  end
  local text = side == "base" and file.base_text or file.current_text
  local filetype = vim.filetype.match({ filename = file.path })
  local language = filetype and (vim.treesitter.language.get_lang(filetype) or filetype)
  local spans = {}
  file.syntax_spans[side] = spans
  if not language or #text > 500000 then
    return spans
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, language)
  if not ok then
    return spans
  end
  local source_lines = base_lines(text)
  pcall(function()
    parser:parse()
    parser:for_each_tree(function(tree, language_tree)
      local tree_language = language_tree:lang()
      local query = vim.treesitter.query.get(tree_language, "highlights")
      if not query then
        return
      end
      for id, node in query:iter_captures(tree:root(), text, 0, -1) do
        local start_row, start_col, end_row, end_col = node:range()
        local last_row = end_col == 0 and end_row > start_row and end_row - 1 or end_row
        for row = start_row, last_row do
          local line = source_lines[row + 1] or ""
          spans[row + 1] = spans[row + 1] or {}
          spans[row + 1][#spans[row + 1] + 1] = {
            start_col = row == start_row and start_col or 0,
            end_col = row == end_row and end_col or #line,
            group = "@" .. query.captures[id] .. "." .. tree_language,
          }
        end
      end
    end)
  end)
  return spans
end

local function render_source_syntax(bufnr, file, line_map, column_offset)
  if not file or not line_map then
    return
  end
  local cache = {}
  for diff_row, source in pairs(line_map) do
    cache[source.side] = cache[source.side] or source_syntax_spans(file, source.side)
    for _, span in ipairs(cache[source.side][source.line] or {}) do
      vim.api.nvim_buf_set_extmark(bufnr, unified_diff_syntax_namespace, diff_row - 1, span.start_col + 1 + column_offset, {
        end_col = span.end_col + 1 + column_offset,
        hl_group = span.group,
        hl_mode = "combine",
        priority = 200,
      })
    end
  end
end

render_unified_diff = function(bufnr, lines, file, line_map, padded)
  local column_offset = padded and 1 or 0
  local buffer_lines = lines
  if padded then
    buffer_lines = {}
    for index, line in ipairs(lines) do
      buffer_lines[index] = " " .. line
    end
  end
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines)
  vim.api.nvim_buf_clear_namespace(bufnr, unified_diff_namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, unified_diff_syntax_namespace, 0, -1)
  for index, line in ipairs(lines) do
    local group
    if vim.startswith(line, "+") and not vim.startswith(line, "+++") then
      group = "DiffAdd"
    elseif vim.startswith(line, "-") and not vim.startswith(line, "---") then
      group = "DiffDelete"
    elseif vim.startswith(line, "@@") then
      group = "DiffChange"
    end
    if group then
      vim.api.nvim_buf_add_highlight(bufnr, unified_diff_namespace, group, index - 1, column_offset, -1)
    end
  end
  render_source_syntax(bufnr, file, line_map, column_offset)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

local function changed_lines(text, start, count)
  local lines = base_lines(text)
  local result = {}
  for index = start, start + count - 1 do
    if lines[index] ~= nil then
      result[#result + 1] = lines[index]
    end
  end
  return table.concat(result, "\n")
end

local function unified_range(start, count)
  return count == 1 and tostring(start) or string.format("%d,%d", start, count)
end

local function diff_line_map(lines)
  local map = {}
  local old_line
  local new_line
  for index, line in ipairs(lines) do
    local old_start, new_start = line:match("^@@ %-(%d+)[,%d]* %+(%d+)[,%d]* @@")
    if old_start then
      old_line = tonumber(old_start)
      new_line = tonumber(new_start)
    elseif old_line and vim.startswith(line, "-") and not vim.startswith(line, "---") then
      map[index] = { side = "base", line = old_line }
      old_line = old_line + 1
    elseif new_line and vim.startswith(line, "+") and not vim.startswith(line, "+++") then
      map[index] = { side = "current", line = new_line }
      new_line = new_line + 1
    elseif old_line and new_line and vim.startswith(line, " ") then
      map[index] = { side = "current", line = new_line }
      old_line = old_line + 1
      new_line = new_line + 1
    end
  end
  return map
end

preview_diff_lines = function(file, hunk)
  local lines
  if hunk then
    lines = unified_diff_lines(
      changed_lines(file.base_text, hunk.old_start, hunk.old_count),
      changed_lines(file.current_text, hunk.new_start, hunk.new_count),
      0
    )
    for index, line in ipairs(lines) do
      if vim.startswith(line, "@@") then
        lines[index] = string.format(
          "@@ -%s +%s @@",
          unified_range(hunk.old_start, hunk.old_count),
          unified_range(hunk.new_start, hunk.new_count)
        )
        break
      end
    end
  else
    lines = unified_diff_lines(file.base_text, file.current_text, 3)
  end
  table.insert(lines, 1, "+++ current/" .. file.relative_path)
  table.insert(lines, 1, "--- merge-base/" .. file.relative_path)
  return lines, diff_line_map(lines)
end

hunk_diff_buffer = function(lines, filetype)
  local diff_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[diff_bufnr].buftype = "nofile"
  vim.bo[diff_bufnr].bufhidden = "wipe"
  vim.bo[diff_bufnr].swapfile = false
  vim.bo[diff_bufnr].filetype = filetype
  vim.api.nvim_buf_set_lines(diff_bufnr, 0, -1, false, lines)
  vim.bo[diff_bufnr].modifiable = false
  return diff_bufnr
end

local function open_unified_hunk_diff(base, current, filetype, source_win)
  local lines = unified_diff_lines(table.concat(base, "\n"), table.concat(current, "\n"), 3)
  local diff_bufnr = hunk_diff_buffer(lines, filetype)
  render_unified_diff(diff_bufnr, lines)
  local width = math.min(math.max(math.floor(vim.o.columns * 0.8), 1), math.max(vim.o.columns - 4, 1))
  local height = math.min(math.max(#lines, 1), math.max(math.floor(vim.o.lines * 0.65), 1), math.max(vim.o.lines - 4, 1))
  local diff_win = vim.api.nvim_open_win(diff_bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = "minimal",
    border = "rounded",
    title = " Unified Hunk Diff ",
    title_pos = "center",
  })
  vim.wo[diff_win].wrap = false

  local function close_diff()
    if vim.api.nvim_win_is_valid(diff_win) then
      vim.api.nvim_win_close(diff_win, true)
    end
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
    end
  end
  vim.keymap.set("n", "q", close_diff, { buffer = diff_bufnr, nowait = true, silent = true })
  local diff_mapping = config.get().keymaps.diff
  if diff_mapping ~= false and diff_mapping ~= "" then
    vim.keymap.set("n", diff_mapping, close_diff, { buffer = diff_bufnr, nowait = true, silent = true })
  end
end

open_hunk_diff = function(base_text, current_text, hunk, filetype, source_win, style)
  local base = hunk_context_lines(
    base_lines(base_text),
    hunk.old_start,
    hunk.old_count,
    "(File did not exist at the merge base)"
  )
  local current = hunk_context_lines(
    base_lines(current_text),
    hunk.new_start,
    hunk.new_count,
    "(No current lines for this hunk)"
  )
  style = style or config.get().diff_style
  if style == "unified" then
    open_unified_hunk_diff(base, current, filetype, source_win)
    return
  end
  if style ~= "split" then
    error("hotlines.nvim: diff style must be 'unified' or 'split'")
  end
  local base_bufnr = hunk_diff_buffer(base, filetype)
  local current_bufnr = hunk_diff_buffer(current, filetype)
  local width = math.max(math.floor((vim.o.columns - 7) / 2), 1)
  local max_height = math.max(vim.o.lines - 4, 1)
  local height = math.min(math.max(#base, #current), math.max(math.floor(vim.o.lines * 0.6), 1), max_height)
  local col = math.max(math.floor((vim.o.columns - (width * 2 + 3)) / 2), 0)
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
  local base_win = vim.api.nvim_open_win(base_bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Merge base ",
    title_pos = "center",
  })
  local current_win = vim.api.nvim_open_win(current_bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col + width + 3,
    style = "minimal",
    border = "rounded",
    title = " Current ",
    title_pos = "center",
  })
  vim.api.nvim_set_current_win(base_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(current_win)
  vim.cmd("diffthis")

  local function close_diff()
    for _, win in ipairs({ base_win, current_win }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
    end
  end
  for _, diff_bufnr in ipairs({ base_bufnr, current_bufnr }) do
    vim.keymap.set("n", "q", close_diff, { buffer = diff_bufnr, nowait = true, silent = true })
  end
  local diff_mapping = config.get().keymaps.diff
  if diff_mapping ~= false and diff_mapping ~= "" then
    for _, diff_bufnr in ipairs({ base_bufnr, current_bufnr }) do
      vim.keymap.set("n", diff_mapping, close_diff, { buffer = diff_bufnr, nowait = true, silent = true })
    end
  end
end

function M.diff_hunk(bufnr, style)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state or state.base_text == nil then
    vim.notify("hotlines.nvim: no comparison data for this buffer", vim.log.levels.INFO)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local hunk
  local adjacent_deletion
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, candidate in ipairs(state.hunks) do
    if cursor >= candidate.new_start and cursor < candidate.new_start + candidate.new_count then
      hunk = candidate
      break
    end
    if candidate.new_count == 0 and candidate.old_count > 0 then
      local following_line = math.min(candidate.new_start + 1, line_count)
      if cursor == candidate.new_start or cursor == following_line then
        adjacent_deletion = candidate
      end
    end
  end
  hunk = hunk or adjacent_deletion
  if not hunk then
    vim.notify("hotlines.nvim: cursor is not on a changed hunk or beside a deletion", vim.log.levels.INFO)
    return
  end

  open_hunk_diff(
    state.base_text,
    buffer_text(bufnr),
    hunk,
    vim.bo[bufnr].filetype,
    vim.api.nvim_get_current_win(),
    style
  )
end

local function debounce(bufnr)
  local state = state_for(bufnr)
  if not state.enabled or not config.get().live_update then
    return
  end

  if not state.timer then
    state.timer = (vim.uv or vim.loop).new_timer()
  end
  state.timer:stop()
  state.timer:start(config.get().debounce_ms, 0, vim.schedule_wrap(function()
    if buffers[bufnr] == state and state.enabled then
      M.refresh(bufnr)
    end
  end))
end

local function complete_base(arglead)
  local state = buffers[vim.api.nvim_get_current_buf()]
  if not state or not state.repo then
    return {}
  end

  local matches = {}
  for _, branch in ipairs(git.cached_branches(state.repo)) do
    if vim.startswith(branch, arglead) then
      matches[#matches + 1] = branch
    end
  end
  return matches
end

local function register_commands()
  vim.api.nvim_create_user_command("HotlinesEnable", function()
    M.enable()
  end, { desc = "Enable branch-change highlights", force = true })
  vim.api.nvim_create_user_command("HotlinesDisable", function()
    M.disable()
  end, { desc = "Disable branch-change highlights", force = true })
  vim.api.nvim_create_user_command("HotlinesToggle", function()
    M.toggle()
  end, { desc = "Toggle branch-change highlights", force = true })
  vim.api.nvim_create_user_command("HotlinesSetBase", function(command)
    M.set_base(command.args)
  end, {
    nargs = "?",
    complete = complete_base,
    desc = "Set or detect the comparison base branch",
    force = true,
  })
  vim.api.nvim_create_user_command("HotlinesTheme", function(command)
    M.set_theme(command.args)
  end, {
    nargs = 1,
    complete = function(arglead)
      return vim.tbl_filter(function(theme)
        return vim.startswith(theme, arglead)
      end, { "flamingo", "classic", "sunset", "aurora", "ember", "custom" })
    end,
    desc = "Set the Hotlines highlight theme",
    force = true,
  })
  vim.api.nvim_create_user_command("HotlinesRefresh", function()
    M.refresh(nil, { force = true })
  end, { desc = "Recompute branch-change highlights", force = true })
  vim.api.nvim_create_user_command("HotlinesInfo", function()
    M.info()
  end, { desc = "Show branch-change comparison details", force = true })
  vim.api.nvim_create_user_command("HotlinesNext", function()
    M.navigate("next")
  end, { desc = "Jump to the next changed hunk", force = true })
  vim.api.nvim_create_user_command("HotlinesPrev", function()
    M.navigate("prev")
  end, { desc = "Jump to the previous changed hunk", force = true })
  vim.api.nvim_create_user_command("HotlinesDiff", function(command)
    M.diff_hunk(nil, command.args ~= "" and command.args or nil)
  end, {
    nargs = "?",
    complete = function(arglead)
      return vim.tbl_filter(function(style)
        return vim.startswith(style, arglead)
      end, { "unified", "split" })
    end,
    desc = "Open a diff for the current hunk",
    force = true,
  })
  vim.api.nvim_create_user_command("HotlinesTouchedFiles", function()
    M.open_touched_files()
  end, { desc = "Open the branch touched-files panel", force = true })
end

local function register_keymaps()
  for _, mapping in ipairs(registered_keymaps) do
    local current = vim.fn.maparg(mapping.lhs, "n", false, true)
    if current.callback == mapping.callback then
      vim.keymap.del("n", mapping.lhs)
    end
  end
  registered_keymaps = {}

  local keymaps = config.get().keymaps
  local definitions = {
    { lhs = keymaps.toggle, callback = M.toggle, desc = "Toggle hotlines" },
    { lhs = keymaps.next, callback = function() M.navigate("next") end, desc = "Next hotlines hunk" },
    { lhs = keymaps.prev, callback = function() M.navigate("prev") end, desc = "Previous hotlines hunk" },
    { lhs = keymaps.diff, callback = M.diff_hunk, desc = "Open hotlines hunk diff" },
    { lhs = keymaps.files, callback = M.open_touched_files, desc = "Open hotlines touched files" },
  }
  for _, mapping in ipairs(definitions) do
    if mapping.lhs ~= false and mapping.lhs ~= "" then
      vim.keymap.set("n", mapping.lhs, mapping.callback, { desc = mapping.desc })
      registered_keymaps[#registered_keymaps + 1] = mapping
    end
  end
end

local function register_autocommands()
  local group = vim.api.nvim_create_augroup("Hotlines", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    callback = function(event)
      local state = state_for(event.buf)
      if state.enabled then
        M.refresh(event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      debounce(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(event)
      local state = buffers[event.buf]
      if state then
        state.generation = state.generation + 1
        close_timer(state)
        highlight.clear(event.buf)
        buffers[event.buf] = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      highlight.prepare(config.get())
    end,
  })
end

function M.setup(opts)
  reset_buffers()
  local options = config.setup(opts)
  git.reset()
  warned_repos = {}
  warned_errors = {}
  highlight.prepare(options)
  register_commands()
  register_keymaps()
  register_autocommands()

  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_for(bufnr)
  if state.enabled then
    M.refresh(bufnr)
  end
end

function M._bootstrap()
  highlight.prepare(config.get())
  register_commands()
  register_keymaps()
  register_autocommands()
end

return M
