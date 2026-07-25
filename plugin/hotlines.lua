if vim.g.loaded_hotlines_nvim then
  return
end

vim.g.loaded_hotlines_nvim = true
require("hotlines")._bootstrap()
