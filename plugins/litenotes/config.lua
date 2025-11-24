local common = require "core.common"

local plugin_dir = common.dirname(debug.getinfo(1, "S").source:sub(2))

return {
  singleton_notes = true,
  notes_panel_size = 256,
  dock_mode = "right",
  fonts = {
    regular = plugin_dir .. "/fonts/JetBrainsMono-Medium.ttf",
    bold    = plugin_dir .. "/fonts/JetBrainsMono-Bold.ttf",
    italic  = plugin_dir .. "/fonts/JetBrainsMono-MediumItalic.ttf",
    -- [NEW] Required for Code Blocks / Inline Code
    code    = plugin_dir .. "/fonts/JetBrainsMono-Regular.ttf", 
    size    = 15,
  },
}
