local common = require "core.common"

local plugin_dir = common.dirname(debug.getinfo(1, "S").source:sub(2))

return {
  fonts = {
    regular = plugin_dir .. "/fonts/JetBrainsMono-Regular.ttf",
    bold    = plugin_dir .. "/fonts/JetBrainsMono-Bold.ttf",
    italic  = plugin_dir .. "/fonts/JetBrainsMono-Italic.ttf",
    size    = 18,
  },
}
