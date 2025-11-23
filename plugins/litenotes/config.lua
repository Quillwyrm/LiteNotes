local common = require "core.common"

local plugin_dir = common.dirname(debug.getinfo(1, "S").source:sub(2))

return {
  singleton_notes = true,   -- true = ONE notes panel per project, across whole window, not including `open markdown` panels
                            -- false = allow per-node / multi instances
  notes_panel_size = 256,
  dock_mode = "right" ,
  fonts = {
    regular = plugin_dir .. "/fonts/JetBrainsMono-Regular.ttf",
    bold    = plugin_dir .. "/fonts/JetBrainsMono-Bold.ttf",
    italic  = plugin_dir .. "/fonts/JetBrainsMono-Italic.ttf",
    size    = 16,
  },
}
