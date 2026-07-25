local M = {}

local themes = {
  flamingo = true,
  classic = true,
  sunset = true,
  aurora = true,
  ember = true,
  custom = true,
}

local defaults = {
  base = nil,
  theme = "flamingo",
  highlight = "BranchChanged",
  added_highlight = "BranchAdded",
  changed_text_highlight = "BranchChangedText",
  deleted_highlight = "BranchDeleted",
  enabled_on_start = true,
  default_bg = "#3b1838",
  added_default_bg = "#512344",
  changed_text_default_bg = "#71335f",
  deleted_default_bg = "#1e0c1c",
  live_update = true,
  debounce_ms = 200,
  diff_style = "unified",
  keymaps = {
    toggle = "<leader>ht",
    next = "<leader>hn",
    prev = "<leader>hb",
    diff = "<leader>hd",
    files = "<leader>hf",
  },
}

local options = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  vim.validate({
    base = { opts.base, "string", true },
    theme = { opts.theme, "string", true },
    highlight = { opts.highlight, "string", true },
    added_highlight = { opts.added_highlight, "string", true },
    changed_text_highlight = { opts.changed_text_highlight, "string", true },
    deleted_highlight = { opts.deleted_highlight, "string", true },
    enabled_on_start = { opts.enabled_on_start, "boolean", true },
    default_bg = { opts.default_bg, "string", true },
    added_default_bg = { opts.added_default_bg, "string", true },
    changed_text_default_bg = { opts.changed_text_default_bg, "string", true },
    deleted_default_bg = { opts.deleted_default_bg, "string", true },
    live_update = { opts.live_update, "boolean", true },
    debounce_ms = { opts.debounce_ms, "number", true },
    diff_style = { opts.diff_style, "string", true },
    keymaps = { opts.keymaps, "table", true },
  })

  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  if options.debounce_ms < 0 then
    error("hotlines.nvim: debounce_ms must be non-negative")
  end
  if options.diff_style ~= "unified" and options.diff_style ~= "split" then
    error("hotlines.nvim: diff_style must be 'unified' or 'split'")
  end
  if not themes[options.theme] then
    error("hotlines.nvim: unknown theme '" .. options.theme .. "'")
  end
  for name, mapping in pairs(options.keymaps) do
    if mapping ~= false and type(mapping) ~= "string" then
      error("hotlines.nvim: keymaps." .. name .. " must be a string or false")
    end
  end

  return options
end

function M.get()
  return options
end

function M.set_base(base)
  options.base = base
end

function M.set_theme(theme)
  if not themes[theme] then
    error("hotlines.nvim: unknown theme '" .. theme .. "'")
  end
  options.theme = theme
end

return M
