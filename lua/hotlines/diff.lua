local M = {}
local max_alignment_cells = 4096

local function text_lines(text)
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  if vim.endswith(text, "\n") then
    table.remove(lines)
  end
  return lines
end

local function changed_columns(old_line, new_line)
  local old_count = vim.fn.strchars(old_line)
  local new_count = vim.fn.strchars(new_line)
  local prefix = 0
  local shared = math.min(old_count, new_count)
  while prefix < shared and vim.fn.strcharpart(old_line, prefix, 1) == vim.fn.strcharpart(new_line, prefix, 1) do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < shared - prefix
    and vim.fn.strcharpart(old_line, old_count - suffix - 1, 1) == vim.fn.strcharpart(new_line, new_count - suffix - 1, 1)
  do
    suffix = suffix + 1
  end

  local start_col = vim.str_byteindex(new_line, prefix)
  local end_col = vim.str_byteindex(new_line, new_count - suffix)
  return start_col, end_col
end

local function line_similarity(old_line, new_line)
  local old_count = vim.fn.strchars(old_line)
  local new_count = vim.fn.strchars(new_line)
  local prefix = 0
  local shared = math.min(old_count, new_count)
  while prefix < shared and vim.fn.strcharpart(old_line, prefix, 1) == vim.fn.strcharpart(new_line, prefix, 1) do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < shared - prefix
    and vim.fn.strcharpart(old_line, old_count - suffix - 1, 1) == vim.fn.strcharpart(new_line, new_count - suffix - 1, 1)
  do
    suffix = suffix + 1
  end
  return prefix + suffix
end

local function paired_lines(old_lines, new_lines)
  if #old_lines * #new_lines > max_alignment_cells then
    local pairs = {}
    for index = 1, math.min(#old_lines, #new_lines) do
      pairs[#pairs + 1] = { index, index }
    end
    return pairs
  end

  local scores = { [0] = {} }
  local directions = {}
  for index = 0, #old_lines do
    scores[index] = scores[index] or {}
    scores[index][0] = 0
  end
  for index = 0, #new_lines do
    scores[0][index] = 0
  end
  for old_index = 1, #old_lines do
    directions[old_index] = {}
    for new_index = 1, #new_lines do
      local matched = scores[old_index - 1][new_index - 1] + line_similarity(old_lines[old_index], new_lines[new_index]) + 1
      local skipped_old = scores[old_index - 1][new_index]
      local skipped_new = scores[old_index][new_index - 1]
      if matched >= skipped_old and matched >= skipped_new then
        scores[old_index][new_index] = matched
        directions[old_index][new_index] = "match"
      elseif skipped_old >= skipped_new then
        scores[old_index][new_index] = skipped_old
        directions[old_index][new_index] = "old"
      else
        scores[old_index][new_index] = skipped_new
        directions[old_index][new_index] = "new"
      end
    end
  end

  local pairs = {}
  local old_index = #old_lines
  local new_index = #new_lines
  while old_index > 0 and new_index > 0 do
    local direction = directions[old_index][new_index]
    if direction == "match" then
      table.insert(pairs, 1, { old_index, new_index })
      old_index = old_index - 1
      new_index = new_index - 1
    elseif direction == "old" then
      old_index = old_index - 1
    else
      new_index = new_index - 1
    end
  end
  return pairs
end

function M.changed_hunks(base_text, buffer_text)
  local ok, hunks = pcall(vim.diff, base_text, buffer_text, {
    result_type = "indices",
    algorithm = "histogram",
  })

  if not ok then
    return nil, hunks
  end

  local changed_hunks = {}
  for _, hunk in ipairs(hunks) do
    changed_hunks[#changed_hunks + 1] = {
      old_start = hunk[1],
      old_count = hunk[2],
      new_start = hunk[3],
      new_count = hunk[4],
    }
  end

  return changed_hunks
end

function M.changed_ranges(base_text, buffer_text)
  local hunks, error_message = M.changed_hunks(base_text, buffer_text)
  if not hunks then
    return nil, error_message
  end

  local ranges = {}
  for _, hunk in ipairs(hunks) do
    if hunk.new_count > 0 then
      ranges[#ranges + 1] = { hunk.new_start, hunk.new_count }
    end
  end

  return ranges
end

function M.changed_highlights(base_text, buffer_text, hunks)
  if not hunks then
    local error_message
    hunks, error_message = M.changed_hunks(base_text, buffer_text)
    if not hunks then
      return nil, error_message
    end
  end

  local base_lines = text_lines(base_text)
  local buffer_lines = text_lines(buffer_text)
  local highlights = {
    added = {},
    changed = {},
    changed_text = {},
    deletions = {},
  }

  for _, hunk in ipairs(hunks) do
    if hunk.old_count == 0 and hunk.new_count > 0 then
      highlights.added[#highlights.added + 1] = { hunk.new_start, hunk.new_count }
    elseif hunk.new_count > 0 then
      local old_hunk_lines = {}
      local new_hunk_lines = {}
      for offset = 0, hunk.old_count - 1 do
        old_hunk_lines[#old_hunk_lines + 1] = base_lines[hunk.old_start + offset] or ""
      end
      for offset = 0, hunk.new_count - 1 do
        new_hunk_lines[#new_hunk_lines + 1] = buffer_lines[hunk.new_start + offset] or ""
      end
      local matched_new_lines = {}
      for _, pair in ipairs(paired_lines(old_hunk_lines, new_hunk_lines)) do
        local old_line = old_hunk_lines[pair[1]]
        local new_line = new_hunk_lines[pair[2]]
        local new_line_number = hunk.new_start + pair[2] - 1
        matched_new_lines[pair[2]] = true
        highlights.changed[#highlights.changed + 1] = { new_line_number, 1 }
        local start_col, end_col = changed_columns(old_line, new_line)
        if start_col < end_col then
          highlights.changed_text[#highlights.changed_text + 1] = {
            new_line_number,
            start_col,
            end_col,
          }
        end
      end
      for index = 1, #new_hunk_lines do
        if not matched_new_lines[index] then
          highlights.added[#highlights.added + 1] = { hunk.new_start + index - 1, 1 }
        end
      end
    elseif hunk.old_count > 0 then
      highlights.deletions[#highlights.deletions + 1] = hunk
    end
  end

  return highlights
end

return M
