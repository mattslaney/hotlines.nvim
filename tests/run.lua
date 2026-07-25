local failures = 0

local function test(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    print("ok - " .. name)
  else
    failures = failures + 1
    print("not ok - " .. name .. "\n" .. err)
  end
end

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error((message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function run(command, cwd)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error(table.concat(command, " ") .. " failed:\n" .. (result.stderr or ""))
  end
  return result.stdout
end

local function wait_for(predicate, message)
  if not vim.wait(3000, predicate, 10) then
    error(message or "timed out")
  end
end

local function detect_base(repo)
  local result
  local completed = false
  require("hotlines.git").detect_base(repo, function(base)
    result = base
    completed = true
  end)
  wait_for(function() return completed end, "base detection timed out")
  return result
end

local function highlighted_lines(bufnr)
  local namespace = require("hotlines.highlight").namespace
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  local lines = {}
  for _, mark in ipairs(marks) do
    if mark[4].line_hl_group then
      lines[#lines + 1] = mark[2] + 1
    end
  end
  table.sort(lines)
  return lines
end

local function line_highlight_groups(bufnr)
  local namespace = require("hotlines.highlight").namespace
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  local groups = {}
  for _, mark in ipairs(marks) do
    if mark[4].line_hl_group then
      groups[mark[2] + 1] = mark[4].line_hl_group
    end
  end
  return groups
end

local function partial_highlights(bufnr, group)
  group = group or "BranchChangedText"
  local namespace = require("hotlines.highlight").namespace
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  local ranges = {}
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == group then
      ranges[#ranges + 1] = { mark[2] + 1, mark[3], mark[4].end_col }
    end
  end
  return ranges
end

local function virtual_deletion_marks(bufnr, namespace, group)
  group = group or "HotlinesFlamingoDeleted"
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  local deletions = {}
  for _, mark in ipairs(marks) do
    local virt_lines = mark[4].virt_lines
    if virt_lines and virt_lines[1][1][2] == group then
      deletions[#deletions + 1] = mark[2] + 1
    end
  end
  return deletions
end

local function hunk_diff_windows()
  local windows = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(winid)
    local name = vim.fs.basename(vim.api.nvim_buf_get_name(buf))
    if vim.bo[buf].buftype == "nofile"
      and name ~= "Hotlines Touched Files"
      and name ~= "Hotlines Touched Files Filter"
      and name ~= "Hotlines Touched Files Preview"
    then
      windows[#windows + 1] = { winid = winid, bufnr = buf }
    end
  end
  return windows
end

local function contains_lines(windows, expected)
  for _, window in ipairs(windows) do
    if vim.deep_equal(vim.api.nvim_buf_get_lines(window.bufnr, 0, -1, false), expected) then
      return true
    end
  end
  return false
end

local function contains_text(windows, expected)
  for _, window in ipairs(windows) do
    if table.concat(vim.api.nvim_buf_get_lines(window.bufnr, 0, -1, false), "\n"):find(expected, 1, true) then
      return true
    end
  end
  return false
end

test("diff ranges omit pure deletions", function()
  local changed_ranges = require("hotlines.diff").changed_ranges
  assert_equal({}, changed_ranges("one\ntwo\n", "one\n"))
  assert_equal({ { 2, 1 } }, changed_ranges("one\ntwo\n", "one\nTWO\n"))
end)

test("diff hunks retain old-side ranges", function()
  local hunks = require("hotlines.diff").changed_hunks("one\ntwo\n", "one\nTWO\nthree\n")
  assert_equal({
    {
      old_start = 2,
      old_count = 1,
      new_start = 2,
      new_count = 2,
    },
  }, hunks)
end)

test("diff hunks retain pure deletions", function()
  local hunks = require("hotlines.diff").changed_hunks("one\ntwo\n", "one\n")
  assert_equal({
    {
      old_start = 2,
      old_count = 1,
      new_start = 1,
      new_count = 0,
    },
  }, hunks)
end)

test("diff highlights distinguish additions and modified text", function()
  local highlights = require("hotlines.diff").changed_highlights("value=one\n", "value=two\nadded\n")
  assert_equal({ { 1, 1 } }, highlights.changed)
  assert_equal({ { 2, 1 } }, highlights.added)
  assert_equal({ { 1, 6, 9 } }, highlights.changed_text)

  highlights = require("hotlines.diff").changed_highlights("", "added\n")
  assert_equal({ { 1, 1 } }, highlights.added)
  assert_equal({}, highlights.changed)
  assert_equal({}, highlights.changed_text)

  highlights = require("hotlines.diff").changed_highlights("value=one\n", "added\nvalue=two\n")
  assert_equal({ { 1, 1 } }, highlights.added)
  assert_equal({ { 2, 1 } }, highlights.changed)
  assert_equal({ { 2, 6, 9 } }, highlights.changed_text)
end)

test("existing highlight definitions are preserved", function()
  vim.api.nvim_set_hl(0, "BranchChanged", { bg = "#112233" })
  vim.api.nvim_set_hl(0, "BranchAdded", { bg = "#223344" })
  vim.api.nvim_set_hl(0, "BranchChangedText", { bg = "#334455" })
  vim.api.nvim_set_hl(0, "BranchDeleted", { bg = "#332211" })
  require("hotlines.highlight").ensure_group("BranchChanged", "#ffffff")
  require("hotlines.highlight").ensure_group("BranchAdded", "#ffffff")
  require("hotlines.highlight").ensure_group("BranchChangedText", "#ffffff")
  require("hotlines.highlight").ensure_group("BranchDeleted", "#ffffff")
  local definition = vim.api.nvim_get_hl(0, { name = "BranchChanged", link = false })
  local added_definition = vim.api.nvim_get_hl(0, { name = "BranchAdded", link = false })
  local changed_text_definition = vim.api.nvim_get_hl(0, { name = "BranchChangedText", link = false })
  local deleted_definition = vim.api.nvim_get_hl(0, { name = "BranchDeleted", link = false })
  assert_equal(0x112233, definition.bg)
  assert_equal(0x223344, added_definition.bg)
  assert_equal(0x334455, changed_text_definition.bg)
  assert_equal(0x332211, deleted_definition.bg)
end)

test("runtime bootstrap can be followed by configured setup", function()
  local hotlines = require("hotlines")
  hotlines._bootstrap()
  hotlines.setup({
    enabled_on_start = false,
    theme = "classic",
    diff_style = "split",
    keymaps = {
      toggle = false,
      next = "]H",
      prev = "[H",
    },
  })
  assert_equal(2, vim.fn.exists(":HotlinesEnable"))
  assert_equal(2, vim.fn.exists(":HotlinesInfo"))
  assert_equal(2, vim.fn.exists(":HotlinesTheme"))
  assert_equal(2, vim.fn.exists(":HotlinesNext"))
  assert_equal(2, vim.fn.exists(":HotlinesPrev"))
  assert_equal(0, vim.fn.exists(":HotlinesPreview"))
  assert_equal(2, vim.fn.exists(":HotlinesDiff"))
  assert_equal(2, vim.fn.exists(":HotlinesTouchedFiles"))
  assert_equal("split", require("hotlines.config").get().diff_style, "configured diff style was not retained")
  assert_equal("classic", require("hotlines.config").get().theme, "configured theme was not retained")
  assert(vim.api.nvim_get_hl(0, { name = "HotlinesClassicChanged", link = false }).bg, "classic theme was not defined")
  for _, theme in ipairs({ "sunset", "aurora", "ember" }) do
    hotlines.set_theme(theme)
    local title = theme:gsub("^%l", string.upper)
    assert(vim.api.nvim_get_hl(0, { name = "Hotlines" .. title .. "Changed", link = false }).bg, theme .. " theme was not defined")
  end
  vim.cmd.HotlinesTheme("custom")
  assert_equal("custom", require("hotlines.config").get().theme, "theme command did not select custom")
  assert_equal("", vim.fn.maparg("<leader>ht", "n"), "disabled toggle mapping remained registered")
  assert(vim.fn.maparg("]H", "n") ~= "", "configured next mapping was not registered")
  assert(vim.fn.maparg("[H", "n") ~= "", "configured previous mapping was not registered")
  assert(vim.fn.maparg("<leader>hd", "n") ~= "", "default diff mapping was not registered")
  assert(vim.fn.maparg("<leader>hf", "n") ~= "", "default touched-files mapping was not registered")
  assert(vim.tbl_contains(vim.fn.getcompletion("HotlinesDiff s", "cmdline"), "split"), "diff completion omitted split")
end)

test("branch origin detection uses creation reflogs instead of upstreams", function()
  local root = vim.fn.tempname()
  local repo = root .. "/repo"
  vim.fn.mkdir(repo, "p")

  run({ "git", "init", "-b", "main" }, repo)
  run({ "git", "config", "user.email", "hotlines@example.test" }, repo)
  run({ "git", "config", "user.name", "Hotlines Test" }, repo)
  vim.fn.writefile({ "base" }, repo .. "/sample.txt")
  run({ "git", "add", "sample.txt" }, repo)
  run({ "git", "commit", "-m", "base" }, repo)
  run({ "git", "checkout", "-b", "release" }, repo)
  run({ "git", "commit", "--allow-empty", "-m", "release" }, repo)
  run({ "git", "checkout", "main" }, repo)
  run({ "git", "checkout", "-b", "feature" }, repo)
  run({ "git", "update-ref", "refs/remotes/origin/feature", "HEAD" }, repo)
  run({ "git", "config", "branch.feature.remote", "origin" }, repo)
  run({ "git", "config", "branch.feature.merge", "refs/heads/feature" }, repo)

  local git = require("hotlines.git")
  git.reset()
  assert_equal({ name = "main", ref = "refs/heads/main" }, detect_base(repo), "feature origin was not detected")

  run({ "git", "update-ref", "refs/remotes/origin/main", "refs/heads/main" }, repo)
  run({ "git", "branch", "-D", "main" }, repo)
  git.clear_detected()
  assert_equal(
    { name = "feature", ref = "refs/heads/feature" },
    detect_base(repo),
    "deleted local origin did not fall back to the current branch"
  )

  run({ "git", "checkout", "release" }, repo)
  run({ "git", "checkout", "-b", "topic" }, repo)
  assert_equal({ name = "release", ref = "refs/heads/release" }, detect_base(repo), "origin cache leaked across branches")

  run({ "git", "remote", "add", "origin", "." }, repo)
  run({ "git", "update-ref", "refs/remotes/origin/release", "refs/heads/release" }, repo)
  run({ "git", "checkout", "release" }, repo)
  run({ "git", "checkout", "-b", "remote-topic", "origin/release" }, repo)
  assert_equal(
    { name = "origin/release", ref = "refs/remotes/origin/release" },
    detect_base(repo),
    "remote branch origin was not detected"
  )

  vim.fn.delete(root, "rf")
end)

test("branch origin detection uses the current branch when reflog evidence is absent", function()
  local root = vim.fn.tempname()
  local repo = root .. "/repo"
  vim.fn.mkdir(repo, "p")

  run({ "git", "init", "-b", "main" }, repo)
  run({ "git", "config", "user.email", "hotlines@example.test" }, repo)
  run({ "git", "config", "user.name", "Hotlines Test" }, repo)
  vim.fn.writefile({ "base" }, repo .. "/sample.txt")
  run({ "git", "add", "sample.txt" }, repo)
  run({ "git", "commit", "-m", "base" }, repo)
  run({ "git", "checkout", "-b", "feature", "main" }, repo)
  run({ "git", "reflog", "expire", "--expire=now", "--all" }, repo)

  local git = require("hotlines.git")
  git.reset()
  assert_equal(
    { name = "feature", ref = "refs/heads/feature" },
    detect_base(repo),
    "detection did not use the current branch without reflog evidence"
  )

  vim.fn.delete(root, "rf")
end)

test("feature history, live edits, commands, and base detection", function()
  local root = vim.fn.tempname()
  local repo = root .. "/repo"
  local outside = root .. "/outside.txt"
  vim.fn.mkdir(repo, "p")

  run({ "git", "init", "-b", "main" }, repo)
  run({ "git", "config", "user.email", "hotlines@example.test" }, repo)
  run({ "git", "config", "user.name", "Hotlines Test" }, repo)
  vim.fn.writefile({ "one", "two", "three" }, repo .. "/sample.txt")
  vim.fn.writefile({ "local value = 1" }, repo .. "/syntax.lua")
  vim.fn.writefile({ "remove me" }, repo .. "/deleted.txt")
  run({ "git", "add", "sample.txt", "syntax.lua", "deleted.txt" }, repo)
  run({ "git", "commit", "-m", "base" }, repo)
  run({ "git", "checkout", "-b", "feature" }, repo)
  vim.fn.writefile({ "one", "TWO", "three", "four" }, repo .. "/sample.txt")
  vim.fn.writefile({ "local value = 2" }, repo .. "/syntax.lua")
  vim.fn.writefile({ "another change" }, repo .. "/other.txt")
  vim.fn.delete(repo .. "/deleted.txt")
  run({ "git", "add", "sample.txt", "syntax.lua", "other.txt", "deleted.txt" }, repo)
  run({ "git", "commit", "-m", "feature changes" }, repo)
  run({ "git", "branch", "integration" }, repo)
  run({ "git", "checkout", "integration" }, repo)
  run({ "git", "commit", "--allow-empty", "-m", "integration changes" }, repo)
  run({ "git", "checkout", "feature" }, repo)
  run({ "git", "remote", "add", "team", "." }, repo)
  run({ "git", "update-ref", "refs/remotes/team/integration", "refs/heads/integration" }, repo)

  vim.cmd.edit(vim.fn.fnameescape(repo .. "/sample.txt"))
  local hotlines = require("hotlines")
  hotlines.setup({ debounce_ms = 20 })
  local bufnr = vim.api.nvim_get_current_buf()

  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 4 })
  end, "initial feature changes were not highlighted")
  assert_equal({ [2] = "HotlinesFlamingoChanged", [4] = "HotlinesFlamingoAdded" }, line_highlight_groups(bufnr), "line groups were not classified")
  assert_equal({ { 2, 0, 3 } }, partial_highlights(bufnr, "HotlinesFlamingoChangedText"), "modified text was not highlighted")
  vim.cmd.HotlinesTheme("aurora")
  wait_for(function()
    return vim.deep_equal(
      line_highlight_groups(bufnr),
      { [2] = "HotlinesAuroraChanged", [4] = "HotlinesAuroraAdded" }
    )
  end, "theme command did not update line groups")
  vim.cmd.HotlinesTheme("flamingo")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "three", "four" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  wait_for(function()
    return #virtual_deletion_marks(bufnr, require("hotlines.highlight").namespace) == 1
  end, "pure deletion did not receive a virtual marker")
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  hotlines.diff_hunk()
  local deletion_diff_windows = hunk_diff_windows()
  assert_equal(1, #deletion_diff_windows, "deletion hunk did not open a unified diff")
  assert(contains_text(deletion_diff_windows, "-two"), "unified deletion diff omitted merge-base code")
  assert(contains_text(deletion_diff_windows, "+four"), "unified deletion diff omitted current code")
  vim.api.nvim_feedkeys("q", "x", false)
  assert_equal(bufnr, vim.api.nvim_get_current_buf(), "closing deletion diff did not restore the source buffer")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "TWO", "three", "four" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 4 })
  end, "restoring the initial changes did not clear the deletion marker")

  vim.fn.writefile({ "not committed" }, repo .. "/untracked.txt")
  vim.fn.mkdir(repo .. "/nested", "p")
  vim.fn.writefile({ "nested change" }, repo .. "/nested/inside.txt")
  local touched_files
  local touched_error
  local touched_context
  hotlines.get_touched_files(function(files, err, context)
    touched_files = files
    touched_error = err
    touched_context = context
  end)
  wait_for(function()
    return touched_files ~= nil or touched_error ~= nil
  end, "touched files were not returned")
  assert_equal(nil, touched_error, "listing touched files failed")
  assert_equal({
    repo .. "/nested/inside.txt",
    repo .. "/other.txt",
    repo .. "/sample.txt",
    repo .. "/syntax.lua",
    repo .. "/untracked.txt",
  }, touched_files, "touched files did not include all navigable branch changes")
  assert_equal(repo, touched_context.repo, "touched file context omitted the repository")
  assert_equal("main", touched_context.base, "touched file context omitted the base")
  assert(touched_context.merge_base, "touched file context omitted the merge base")

  local touched_hunk_files
  local touched_hunk_error
  hotlines.get_touched_file_hunks(function(files, err)
    touched_hunk_files = files
    touched_hunk_error = err
  end)
  wait_for(function()
    return touched_hunk_files ~= nil or touched_hunk_error ~= nil
  end, "touched-file hunks were not returned")
  assert_equal(nil, touched_hunk_error, "listing touched-file hunks failed")
  local sample_hunks
  for _, file in ipairs(touched_hunk_files) do
    if file.path == repo .. "/sample.txt" then
      sample_hunks = file.hunks
      break
    end
  end
  assert_equal(2, #sample_hunks, "touched-file hunks omitted changed sample hunks")

  package.preload["mini.icons"] = function()
    return {
      get = function(_, name)
        return name == "sample.txt" and "L" or "F", "HotlinesTestIcon"
      end,
    }
  end
  vim.api.nvim_set_hl(0, "HotlinesTestIcon", { fg = "#ff00ff" })
  vim.bo[bufnr].modified = false
  local source_win = vim.api.nvim_get_current_win()
  hotlines.open_touched_files()
  local panel_bufnr = vim.api.nvim_get_current_buf()
  local panel_win = vim.api.nvim_get_current_win()
  assert_equal("editor", vim.api.nvim_win_get_config(0).relative, "touched-files panel was not a floating window")
  local filter_bufnr = vim.fn.bufnr("Hotlines Touched Files Filter")
  local filter_win = vim.fn.bufwinid(filter_bufnr)
  assert(filter_bufnr ~= -1 and filter_win ~= -1, "touched-files panel did not open an embedded filter")
  local preview_bufnr = vim.fn.bufnr("Hotlines Touched Files Preview")
  local preview_win = vim.fn.bufwinid(preview_bufnr)
  assert(preview_bufnr ~= -1 and preview_win ~= -1, "touched-files panel did not open a diff preview")
  local panel_config = vim.api.nvim_win_get_config(panel_win)
  local filter_config = vim.api.nvim_win_get_config(filter_win)
  local preview_config = vim.api.nvim_win_get_config(preview_win)
  assert_equal(false, preview_config.focusable, "touched-files preview was focusable")
  assert(preview_config.col > panel_config.col, "touched-files preview was not positioned to the right")
  assert_equal(panel_config.row, preview_config.row, "touched-files results and preview were not aligned")
  assert(filter_config.row > panel_config.row, "touched-files filter was not positioned below the results")
  assert_equal(true, vim.bo[preview_bufnr].readonly, "touched-files preview was not read-only")
  assert_equal(false, vim.bo[preview_bufnr].modifiable, "touched-files preview was modifiable")
  wait_for(function()
    return table.concat(vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false), "\n"):find("sample.txt", 1, true) ~= nil
  end, "touched-files panel did not render changed files")
  assert(
    vim.startswith(vim.api.nvim_buf_get_lines(panel_bufnr, 0, 1, false)[1], " "),
    "touched-files results omitted pane padding"
  )
  assert(
    table.concat(vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false), "\n"):find("L  sample.txt", 1, true),
    "touched-files panel omitted a provider file icon"
  )
  local icon_namespace = vim.api.nvim_get_namespaces().hotlines_touched_file_icons
  assert(icon_namespace, "touched-files panel did not create an icon highlight namespace")
  local icon_highlighted = false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(panel_bufnr, icon_namespace, 0, -1, { details = true })) do
    if mark[4].hl_group == "HotlinesTestIcon" then
      icon_highlighted = true
      break
    end
  end
  assert(icon_highlighted, "touched-files panel did not apply the provider icon color")
  vim.api.nvim_feedkeys("f", "x", false)
  assert_equal(filter_win, vim.api.nvim_get_current_win(), "filter mapping did not focus the embedded input")
  vim.api.nvim_buf_set_lines(filter_bufnr, 0, -1, false, { "sample" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = filter_bufnr })
  local filtered_lines = table.concat(vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false), "\n")
  assert(filtered_lines:find("sample.txt", 1, true), "embedded filter omitted a matching file")
  assert(not filtered_lines:find("other.txt", 1, true), "embedded filter retained a non-matching file")
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  assert_equal(panel_win, vim.api.nvim_get_current_win(), "accepting the embedded filter did not restore results focus")
  vim.api.nvim_buf_set_lines(filter_bufnr, 0, -1, false, { "" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = filter_bufnr })
  assert(vim.api.nvim_buf_get_lines(panel_bufnr, 0, 1, false)[1]:find("[list]", 1, true), "touched-files panel did not start in list mode")
  vim.api.nvim_feedkeys("t", "x", false)
  assert(vim.api.nvim_buf_get_lines(panel_bufnr, 0, 1, false)[1]:find("[tree]", 1, true), "touched-files panel did not switch to tree mode")
  local panel_lines = vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false)
  local folder_line
  for index, line in ipairs(panel_lines) do
    if line:find("> nested/", 1, true) then
      folder_line = index
      break
    end
  end
  assert(folder_line, "touched-files panel did not group nested files")
  vim.api.nvim_win_set_cursor(0, { folder_line, 0 })
  vim.api.nvim_feedkeys("o", "x", false)
  assert(table.concat(vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false), "\n"):find("inside.txt", 1, true), "touched-files panel did not expand folders")
  vim.api.nvim_feedkeys("t", "x", false)
  assert(vim.api.nvim_buf_get_lines(panel_bufnr, 0, 1, false)[1]:find("[list]", 1, true), "touched-files panel did not switch to list mode")

  local function select_panel_file(filename)
    for index, line in ipairs(vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false)) do
      if line:find(filename, 1, true) then
        vim.api.nvim_win_set_cursor(panel_win, { index, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = panel_bufnr })
        return index
      end
    end
    error("touched-files panel omitted " .. filename)
  end

  local function open_panel_file(filename)
    select_panel_file(filename)
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end

  select_panel_file("sample.txt")
  assert(
    vim.api.nvim_get_current_line():find("+1 -0 ~1", 1, true),
    "touched-files panel omitted line change totals"
  )
  local preview_text = table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
  assert(
    vim.startswith(vim.api.nvim_buf_get_lines(preview_bufnr, 0, 1, false)[1], " "),
    "touched-files preview omitted pane padding"
  )
  assert(preview_text:find("--- merge-base/sample.txt", 1, true), "file preview omitted the merge-base heading")
  assert(preview_text:find("-two", 1, true), "file preview omitted a deletion")
  assert(preview_text:find("+TWO", 1, true), "file preview omitted an addition")
  assert(preview_text:find("+four", 1, true), "file preview omitted a later hunk")
  assert_equal(panel_win, vim.api.nvim_get_current_win(), "updating the diff preview took focus from the panel")

  vim.bo[preview_bufnr].readonly = false
  vim.bo[preview_bufnr].modifiable = true
  local overflow_lines = {}
  for index = 1, 100 do
    overflow_lines[index] = "preview line " .. index
  end
  vim.api.nvim_buf_set_lines(preview_bufnr, 0, -1, false, overflow_lines)
  vim.bo[preview_bufnr].modifiable = false
  vim.bo[preview_bufnr].readonly = true
  vim.api.nvim_win_set_cursor(preview_win, { 1, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<C-d>"), "x", false)
  assert(vim.api.nvim_win_get_cursor(preview_win)[1] > 1, "preview scroll mapping did not move the preview")
  assert_equal(panel_win, vim.api.nvim_get_current_win(), "scrolling the preview took focus from the panel")
  select_panel_file("other.txt")
  select_panel_file("sample.txt")

  select_panel_file("syntax.lua")
  local syntax_namespace = vim.api.nvim_get_namespaces().hotlines_unified_diff_syntax
  local parser_ok = pcall(vim.treesitter.get_string_parser, "local value = 2", "lua")
  if parser_ok then
    assert(
      #vim.api.nvim_buf_get_extmarks(preview_bufnr, syntax_namespace, 0, -1, {}) > 0,
      "touched-files preview omitted source syntax highlights"
    )
  end

  open_panel_file("other.txt")
  assert_equal(panel_win, vim.api.nvim_get_current_win(), "opening a touched file took focus from the panel")
  assert_equal(repo .. "/other.txt", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)), "touched file did not open in the source window")
  open_panel_file("sample.txt")
  assert_equal(panel_win, vim.api.nvim_get_current_win(), "opening another touched file took focus from the panel")
  assert_equal(bufnr, vim.api.nvim_win_get_buf(source_win), "another touched file did not open in the source window")

  select_panel_file("sample.txt")
  vim.api.nvim_feedkeys("a", "x", false)
  local sample_line = vim.api.nvim_win_get_cursor(panel_win)[1]
  assert(
    vim.api.nvim_get_current_line():find("sample.txt", 1, true),
    "expanding touched files did not preserve the selected file"
  )
  vim.api.nvim_win_set_cursor(panel_win, { sample_line + 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = panel_bufnr })
  preview_text = table.concat(vim.api.nvim_buf_get_lines(preview_bufnr, 0, -1, false), "\n")
  assert(preview_text:find("-two", 1, true) and preview_text:find("+TWO", 1, true), "hunk preview omitted selected changes")
  assert(not preview_text:find("+four", 1, true), "hunk preview included another hunk")
  local preview_cursor = vim.api.nvim_win_get_cursor(preview_win)[1]
  local preview_cursor_line = vim.api.nvim_buf_get_lines(preview_bufnr, preview_cursor - 1, preview_cursor, false)[1]
  assert(
    vim.trim(preview_cursor_line):match("^@@"),
    "hunk preview was not positioned at its hunk header"
  )
  assert_equal(panel_win, vim.api.nvim_get_current_win(), "positioning the hunk preview took focus from the panel")

  vim.api.nvim_feedkeys("t", "x", false)
  vim.api.nvim_feedkeys("a", "x", false)
  panel_lines = vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false)
  local hunk_line
  for index, line in ipairs(panel_lines) do
    if line:find("Lines ", 1, true) or line:find("Deleted lines ", 1, true) then
      hunk_line = index
      break
    end
  end
  vim.api.nvim_win_set_cursor(0, { hunk_line, 0 })
  vim.api.nvim_feedkeys("d", "x", false)
  assert_equal(1, #hunk_diff_windows(), "touched-files panel did not open a unified hunk diff")
  vim.api.nvim_feedkeys("q", "x", false)
  assert_equal(panel_bufnr, vim.api.nvim_get_current_buf(), "closing panel hunk diff did not restore the panel")
  vim.api.nvim_feedkeys("q", "x", false)
  assert_equal(bufnr, vim.api.nvim_get_current_buf(), "closing touched-files panel did not restore the source buffer")
  assert(not vim.api.nvim_buf_is_valid(preview_bufnr), "closing touched-files panel left its preview open")
  assert(not vim.api.nvim_buf_is_valid(filter_bufnr), "closing touched-files panel left its filter open")
  package.loaded["mini.icons"] = nil
  package.preload["mini.icons"] = nil

  assert(vim.fn.maparg("<leader>ht", "n") ~= "", "default toggle mapping was not registered")
  assert(vim.fn.maparg("<leader>hn", "n") ~= "", "default next mapping was not registered")
  assert(vim.fn.maparg("<leader>hb", "n") ~= "", "default previous mapping was not registered")
  assert(vim.fn.maparg("<leader>hd", "n") ~= "", "default diff mapping was not registered")

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  hotlines.diff_hunk()
  local diff_windows = hunk_diff_windows()
  assert_equal(1, #diff_windows, "hunk did not open a unified diff")
  assert(contains_text(diff_windows, "-two"), "unified hunk diff omitted merge-base lines")
  assert(contains_text(diff_windows, "+TWO"), "unified hunk diff omitted current lines")
  vim.api.nvim_feedkeys("q", "x", false)
  assert_equal(bufnr, vim.api.nvim_get_current_buf(), "closing the hunk diff did not restore the source buffer")
  vim.cmd("HotlinesDiff split")
  diff_windows = hunk_diff_windows()
  assert_equal(2, #diff_windows, "split hunk diff did not open both sides")
  assert(contains_lines(diff_windows, { "one", "two", "three" }), "split hunk diff omitted merge-base lines")
  assert(contains_lines(diff_windows, { "one", "TWO", "three", "four" }), "split hunk diff omitted current lines")
  vim.api.nvim_feedkeys("q", "x", false)
  assert_equal(bufnr, vim.api.nvim_get_current_buf(), "closing split hunk diff did not restore the source buffer")
  hotlines.diff_hunk()
  local diff_keys = vim.api.nvim_replace_termcodes((vim.g.mapleader or "\\") .. "hd", true, false, true)
  vim.api.nvim_feedkeys(diff_keys, "x", false)
  assert_equal(bufnr, vim.api.nvim_get_current_buf(), "diff mapping did not close the hunk diff")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  hotlines.diff_hunk()
  diff_windows = hunk_diff_windows()
  assert_equal(1, #diff_windows, "addition did not open a unified diff")
  assert(contains_text(diff_windows, "+four"), "unified addition diff omitted current lines")
  vim.api.nvim_feedkeys("q", "x", false)

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd.HotlinesNext()
  assert_equal(2, vim.api.nvim_win_get_cursor(0)[1], "next did not jump to the first hunk")
  vim.cmd.HotlinesNext()
  assert_equal(4, vim.api.nvim_win_get_cursor(0)[1], "next did not jump to the second hunk")
  vim.cmd.HotlinesNext()
  assert_equal(2, vim.api.nvim_win_get_cursor(0)[1], "next did not wrap to the first hunk")
  vim.cmd.HotlinesPrev()
  assert_equal(4, vim.api.nvim_win_get_cursor(0)[1], "previous did not wrap to the last hunk")

  local notification
  local original_notify = vim.notify
  vim.notify = function(message, level, opts)
    notification = { message = message, level = level, opts = opts }
  end
  vim.cmd.HotlinesInfo()
  vim.notify = original_notify
  assert(notification.message:find("Base: main", 1, true), "info omitted the resolved base")
  assert(notification.message:find("Changed hunks: 2", 1, true), "info reported the wrong hunk count")
  assert(notification.message:find("Changed lines: 2", 1, true), "info reported the wrong line count")

  local completion = vim.fn.getcompletion("HotlinesSetBase team/", "cmdline")
  assert(vim.tbl_contains(completion, "team/integration"), "base completion omitted a remote branch")
  vim.cmd.HotlinesSetBase("team/integration")
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), {})
  end, "an explicit branch from a non-origin remote was not resolved")
  original_notify = vim.notify
  vim.notify = function() end
  local remote_details = hotlines.info()
  vim.notify = original_notify
  assert_equal("team/integration", remote_details.base, "the non-origin remote base was not retained")
  assert(remote_details.merge_base, "the non-origin remote merge base was not resolved")

  run({ "git", "config", "branch.feature.remote", "team" }, repo)
  run({ "git", "config", "branch.feature.merge", "refs/heads/integration" }, repo)
  vim.cmd.HotlinesSetBase()
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 4 })
  end, "the configured upstream was incorrectly used as the branch origin")

  completion = vim.fn.getcompletion("HotlinesSetBase m", "cmdline")
  assert(vim.tbl_contains(completion, "main"), "base completion did not include main")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "TWO", "THREE", "four" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 3, 4 })
  end, "unsaved changes were not highlighted")

  vim.cmd.write()
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 3, 4 })
  end, "saving the buffer did not preserve refreshed highlights")

  vim.cmd.HotlinesDisable()
  assert_equal({}, highlighted_lines(bufnr), "disable did not clear highlights")
  assert(not hotlines.is_enabled(bufnr), "buffer remained enabled")

  vim.cmd.HotlinesEnable()
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 3, 4 })
  end, "enable did not restore highlights")

  vim.cmd.HotlinesSetBase("feature")
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 3 })
  end, "explicit base did not refresh the live buffer")

  vim.cmd.HotlinesSetBase()
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 3, 4 })
  end, "base auto-detection did not select main")

  vim.cmd.HotlinesToggle()
  assert_equal({}, highlighted_lines(bufnr), "toggle did not clear highlights")
  vim.cmd.HotlinesToggle()
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 3, 4 })
  end, "toggle did not restore highlights")

  run({ "git", "restore", "sample.txt" }, repo)
  vim.cmd.edit({ bang = true })
  run({ "git", "checkout", "main" }, repo)
  vim.fn.writefile({ "ONE", "two", "three" }, repo .. "/sample.txt")
  run({ "git", "add", "sample.txt" }, repo)
  run({ "git", "commit", "-m", "advance main" }, repo)
  run({ "git", "checkout", "-b", "feature-rebased" }, repo)
  vim.fn.writefile({ "ONE", "TWO", "three", "four" }, repo .. "/sample.txt")
  run({ "git", "add", "sample.txt" }, repo)
  run({ "git", "commit", "-m", "rebased feature changes" }, repo)
  vim.cmd.edit({ bang = true })
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 4 })
  end, "moving HEAD reused a stale merge base")

  run({ "git", "update-ref", "refs/remotes/origin/main", "refs/heads/main" }, repo)
  run({ "git", "branch", "-D", "main" }, repo)
  vim.cmd.HotlinesSetBase("main")
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), { 2, 4 })
  end, "explicit base did not fall back to the remote branch")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  wait_for(function()
    return vim.deep_equal(highlighted_lines(bufnr), {})
  end, "emptying the file produced a phantom changed line")

  vim.fn.writefile({ "new", "file" }, repo .. "/new.txt")
  vim.cmd.edit({ bang = true, args = { repo .. "/new.txt" } })
  local new_bufnr = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.deep_equal(highlighted_lines(new_bufnr), { 1, 2 })
  end, "a new file was not compared with empty base content")

  vim.fn.writefile({}, repo .. "/empty.txt")
  vim.cmd.edit({ args = { repo .. "/empty.txt" } })
  local empty_bufnr = vim.api.nvim_get_current_buf()
  vim.wait(200, function()
    return false
  end, 20)
  assert_equal({}, highlighted_lines(empty_bufnr), "an empty file received a phantom highlight")

  vim.fn.writefile({ "not a repository" }, outside)
  vim.cmd.edit(vim.fn.fnameescape(outside))
  local outside_bufnr = vim.api.nvim_get_current_buf()
  vim.wait(200, function()
    return false
  end, 20)
  assert_equal({}, highlighted_lines(outside_bufnr), "outside file received highlights")

  vim.cmd.bwipeout({ bang = true })
  vim.fn.delete(root, "rf")
end)

if failures > 0 then
  print(string.format("%d test(s) failed", failures))
  vim.cmd.cquit(1)
else
  print("all tests passed")
  vim.cmd.quitall({ bang = true })
end
