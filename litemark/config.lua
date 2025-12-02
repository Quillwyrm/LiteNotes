local common = require "core.common"

local plugin_dir = common.dirname(debug.getinfo(1, "S").source:sub(2))

return {
  singleton_notes = true,
  dock_mode = "right", 
  header_rules = true, -- Draw a thin rule under H1 / H2 headings
  
  fonts = {
    regular = plugin_dir .. "/fonts/iAWriterQuattroS-Regular.ttf",
    bold    = plugin_dir .. "/fonts/iAWriterQuattroS-Bold.ttf",
    italic  = plugin_dir .. "/fonts/iAWriterQuattroS-Italic.ttf",
    code    = plugin_dir .. "/fonts/iAWriterMonoS-Regular.ttf", 
    size    = 14,
  },
}


-- Fonts from iA-Fonts by Iaolo (https://github.com/iaolo/iA-Fonts)
