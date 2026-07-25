local M = {}

local palettes = {
  flamingo = {
    added = "#512344",
    changed = "#3b1838",
    changed_text = "#71335f",
    deleted = "#1e0c1c",
  },
  classic = {
    added = "#1f3d2e",
    changed = "#1e3a5f",
    changed_text = "#285a8e",
    deleted = "#4a1f24",
  },
  sunset = {
    added = "#5a2c3c",
    changed = "#45274f",
    changed_text = "#754367",
    deleted = "#2b1620",
  },
  aurora = {
    added = "#1e453f",
    changed = "#253b5c",
    changed_text = "#2c6f82",
    deleted = "#4a2431",
  },
  ember = {
    added = "#4c3a22",
    changed = "#493020",
    changed_text = "#7a572b",
    deleted = "#2c1717",
  },
}

M.namespace = vim.api.nvim_create_namespace("branch_changes")

function M.ensure_group(name, background)
  local ok, definition = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or vim.tbl_isempty(definition) then
    vim.api.nvim_set_hl(0, name, { bg = background })
  end
end

function M.groups(options)
  if options.theme == "custom" then
    return {
      added = options.added_highlight,
      changed = options.highlight,
      changed_text = options.changed_text_highlight,
      deleted = options.deleted_highlight,
    }
  end
  local title = options.theme:gsub("^%l", string.upper)
  local prefix = "Hotlines" .. title
  return {
    added = prefix .. "Added",
    changed = prefix .. "Changed",
    changed_text = prefix .. "ChangedText",
    deleted = prefix .. "Deleted",
  }
end

function M.prepare(options)
  if options.theme == "custom" then
    M.ensure_group(options.added_highlight, options.added_default_bg)
    M.ensure_group(options.highlight, options.default_bg)
    M.ensure_group(options.changed_text_highlight, options.changed_text_default_bg)
    M.ensure_group(options.deleted_highlight, options.deleted_default_bg)
    return
  end
  local palette = palettes[options.theme]
  local groups = M.groups(options)
  vim.api.nvim_set_hl(0, groups.added, { bg = palette.added })
  vim.api.nvim_set_hl(0, groups.changed, { bg = palette.changed })
  vim.api.nvim_set_hl(0, groups.changed_text, { bg = palette.changed_text })
  vim.api.nvim_set_hl(0, groups.deleted, { bg = palette.deleted })
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.namespace, 0, -1)
  end
end

function M.render_virtual_deletion(bufnr, namespace, start_line, group)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row
  local above
  if start_line <= 1 then
    row = 0
    above = true
  elseif start_line > line_count then
    row = line_count - 1
    above = false
  else
    row = start_line - 1
    above = true
  end
  vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
    virt_lines = { { { string.rep(" ", vim.o.columns), group } } },
    virt_lines_above = above,
  })
end

function M.render(bufnr, highlights, added_group, changed_group, changed_text_group, deleted_group)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  M.clear(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local function render_lines(ranges, group)
    for _, range in ipairs(ranges) do
      local first = math.max(range[1], 1)
      local last = math.min(first + range[2] - 1, line_count)
      for line = first, last do
        vim.api.nvim_buf_set_extmark(bufnr, M.namespace, line - 1, 0, {
          line_hl_group = group,
        })
      end
    end
  end

  render_lines(highlights.added, added_group)
  render_lines(highlights.changed, changed_group)
  for _, range in ipairs(highlights.changed_text) do
    local row = range[1] - 1
    if row >= 0 and row < line_count then
      local line_length = #vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      local start_col = math.min(math.max(range[2], 0), line_length)
      local end_col = math.min(math.max(range[3], start_col), line_length)
      if start_col < end_col then
        vim.api.nvim_buf_set_extmark(bufnr, M.namespace, row, start_col, {
          end_col = end_col,
          hl_group = changed_text_group,
          priority = 200,
        })
      end
    end
  end
  for _, deletion in ipairs(highlights.deletions) do
    M.render_virtual_deletion(bufnr, M.namespace, deletion.new_start + 1, deleted_group)
  end
end

return M
