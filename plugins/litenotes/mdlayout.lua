local core    = require "core"
local common  = require "core.common"
local style   = require "core.style"
local parser  = require "plugins.litenotes.mdparse"
local config  = require "plugins.litenotes.config"

local DRAW_MODE = { TEXT = 1, RECT = 2 }
local BLOCK     = parser.TOKENS.BLOCK
local SPAN      = parser.TOKENS.SPAN

-- -------------------------------------------------------------------------
-- LAYOUT CONSTANTS
-- -------------------------------------------------------------------------
local L = {
  -- Horizontal layout -------------------------------------------------------
  BODY_X       = 32,
  HEADER_X     = 16,
  LIST_INDENT  = 32,
  MARGIN_RIGHT = 8,
  PAD_CODE_X   = 2,

  -- Code block layout -------------------------------------------------------
  CODE_MARGIN    = 16,
  CODE_PADDING_X = 6,
  CODE_PADDING_Y = 4,

  -- Vertical spacing between blocks ----------------------------------------
  VIEW_PADDING_TOP  = 8,
  HEADER_GAP_TOP    = 8,
  HEADER_GAP_BOTTOM = 16,
  PARA_GAP_TOP      = 8,
  PARA_GAP_BOTTOM   = 8,
  LIST_GAP_TOP      = 6,
  LIST_GAP_BOTTOM   = 6,
  LIST_SPACING      = 4,
  CODE_GAP_TOP      = 8,
  CODE_GAP_BOTTOM   = 8,
  RULE_GAP_TOP      = 8,
  RULE_GAP_BOTTOM   = 8,
}

-- -------------------------------------------------------------------------
-- THEME PALETTE
-- -------------------------------------------------------------------------
local NoteColors = {
  text    = function() return style.text end,
  header  = function() return style.syntax["keyword"] or style.accent end,
  code    = function() return style.syntax["string"]  or style.text end,
  bullet  = function() return style.syntax["number"] or style.accent end, 
  rule    = function() return style.dim end,
  code_bg = function() return style.background end,
  dim     = function() return style.dim end,
}

local NoteFonts = {}

-- Initializes all fonts used by the notes renderer.
local function load_assets(config)
  local base_size = config.fonts.size

  NoteFonts.REGULAR = renderer.font.load(config.fonts.regular, base_size)
  NoteFonts.BOLD    = renderer.font.load(config.fonts.bold,    base_size)
  NoteFonts.ITALIC  = renderer.font.load(config.fonts.italic,  base_size)
  NoteFonts.CODE    = renderer.font.load(config.fonts.code,    base_size)

  local h_offsets = { 10, 6, 4, 2, 0 }
  NoteFonts.HEADER = {}

  for level, offset in ipairs(h_offsets) do
    local size = base_size + offset
    NoteFonts.HEADER[level] = {}
    NoteFonts.HEADER[level][SPAN.NONE]   = renderer.font.load(config.fonts.regular, size)
    NoteFonts.HEADER[level][SPAN.BOLD]   = renderer.font.load(config.fonts.bold,    size)
    NoteFonts.HEADER[level][SPAN.ITALIC] = renderer.font.load(config.fonts.italic,  size)
    NoteFonts.HEADER[level][SPAN.CODE]   = NoteFonts.HEADER[level][SPAN.NONE]
  end
end

-- Lays out a single logical line of text into draw commands.
local function line_layout(ctx, text, base_font_set, is_code_block, custom_color)
  local draw_list = ctx.output
  local tokens

  if is_code_block then
    tokens = { { text = text, style = SPAN.NONE } }
  else
    tokens = parser.parse_spans(text)
  end

  for _, token in ipairs(tokens) do
    -- A. Resolve font
    local active_font
    if is_code_block then
      active_font = NoteFonts.CODE
    elseif base_font_set == NoteFonts.HEADER then
      active_font = base_font_set[ctx.level][token.style] or base_font_set[ctx.level][SPAN.NONE]
    else
      if token.style == SPAN.BOLD then active_font = NoteFonts.BOLD
      elseif token.style == SPAN.ITALIC then active_font = NoteFonts.ITALIC
      elseif token.style == SPAN.CODE then active_font = NoteFonts.CODE
      elseif token.style == SPAN.STRIKE then active_font = NoteFonts.REGULAR -- <--- STRIKE FONT RESOLUTION
      else active_font = NoteFonts.REGULAR end
    end

    -- B. Resolve color
    local color = custom_color or NoteColors.text()
    if token.style == SPAN.CODE and not is_code_block then
      color = NoteColors.code()
    end

    -- C. Code block: raw layout
    if is_code_block then
      local w = active_font:get_width(token.text)
      draw_list[#draw_list + 1] = {
        type  = DRAW_MODE.TEXT,
        x     = ctx.x,
        y     = ctx.y,
        text  = token.text,
        font  = active_font,
        color = color,
      }
      -- Horizontal cursor advancement removed to prevent horizontal bunching
      if w + ctx.x > ctx.max_seen_w then ctx.max_seen_w = w + ctx.x end

    -- D. Standard wrapping
    else
      local start_idx = 1
      while start_idx <= #token.text do
        local s, e = token.text:find("\n", start_idx)
        local line_segment = s and token.text:sub(start_idx, s - 1) or token.text:sub(start_idx)

        local lead_space = line_segment:match("^(%s+)")
        if lead_space then
          ctx.x = ctx.x + active_font:get_width(lead_space)
        end

        if lead_space == line_segment and #line_segment > 0 then
          -- Only whitespace
        else
          for word, spacer in line_segment:gmatch("([^%s]+)(%s*)") do
            local full_word = word .. spacer
            local w = active_font:get_width(full_word)

            if ctx.x + w > ctx.max_w then
              ctx.x = ctx.indent
              ctx.y = ctx.y + active_font:get_height()
            end

            -- STRIKETHROUGH LINE DRAWING
            if token.style == SPAN.STRIKE then
              local line_h = active_font:get_height()
              local line_y = ctx.y + math.floor(line_h / 2)
              
              draw_list[#draw_list + 1] = {
                type  = DRAW_MODE.RECT,
                x     = ctx.x - 3,
                y     = line_y,
                w     = w + 6, -- width of the word
                h     = 2, -- 1 pixel height line
                color = color, -- Use text color for the line
              }
            end
            
            -- CODE BLOCK DRAWING (Existing logic)
            if token.style == SPAN.CODE then
              ctx.x = ctx.x + L.PAD_CODE_X
              draw_list[#draw_list + 1] = {
                type  = DRAW_MODE.RECT,
                x     = ctx.x - L.PAD_CODE_X,
                y     = ctx.y,
                w     = w + (L.PAD_CODE_X * 2),
                h     = active_font:get_height(),
                color = NoteColors.code_bg(),
              }
              draw_list[#draw_list + 1] = {
                type  = DRAW_MODE.TEXT,
                x     = ctx.x,
                y     = ctx.y,
                text  = full_word,
                font  = active_font,
                color = color,
              }
              ctx.x = ctx.x + w + L.PAD_CODE_X
            -- STANDARD TEXT DRAWING (Existing logic + STRIKETHROUGH text)
            else
              draw_list[#draw_list + 1] = {
                type  = DRAW_MODE.TEXT,
                x     = ctx.x,
                y     = ctx.y,
                text  = full_word,
                font  = active_font,
                color = color,
              }
              ctx.x = ctx.x + w
            end

            if ctx.x > ctx.max_seen_w then ctx.max_seen_w = ctx.x end
          end
        end

        if s then
          ctx.x = ctx.indent
          ctx.y = ctx.y + active_font:get_height()
          start_idx = e + 1
        else
          break
        end
      end
    end
  end
  return (is_code_block and NoteFonts.CODE:get_height()) or NoteFonts.REGULAR:get_height()
end

-- -------------------------------------------------------------------------
-- DRAW HANDLERS
-- -------------------------------------------------------------------------

local function draw_header(ctx, block)
  ctx.y      = ctx.y + L.HEADER_GAP_TOP
  ctx.x      = L.HEADER_X
  ctx.indent = L.HEADER_X
  ctx.level  = math.min(block.arg, 5)

  local line_h = line_layout(ctx, block.text, NoteFonts.HEADER, false, NoteColors.header())
  ctx.y = ctx.y + line_h + L.HEADER_GAP_BOTTOM
end

local function draw_paragraph(ctx, block)
  ctx.y      = ctx.y + L.PARA_GAP_TOP
  ctx.x      = L.BODY_X
  ctx.indent = L.BODY_X

  local line_h = line_layout(ctx, block.text, nil, false, nil)
  ctx.y = ctx.y + line_h + L.PARA_GAP_BOTTOM
end

local function draw_list(ctx, block, prev_block, next_block)
  -- 1. Nesting & Spacing
  local nest_offset = (block.level or 0) * L.LIST_INDENT
  local bullet_x = L.BODY_X + nest_offset
  local text_x   = bullet_x + L.LIST_INDENT

  if not prev_block or prev_block.type ~= BLOCK.LIST then
    ctx.y = ctx.y + L.LIST_GAP_TOP
  else
    ctx.y = ctx.y + L.LIST_SPACING
  end

  ctx.x      = text_x
  ctx.indent = text_x
  local bullet_y = ctx.y

  -- 2. Checkbox vs Bullet Logic (VISUALS ONLY in stable state)
  if block.checked ~= nil then
    -- DEFINE ASSETS
    local tick_char = "✓" 
    local tick_font = NoteFonts.BOLD
    
    -- MEASURE
    local tw = math.floor(tick_font:get_width(tick_char))
    local th = tick_font:get_height()
    
    -- PARITY CHECK (The "-1px Solution")
    local box_sz = math.floor(config.fonts.size)
    if (box_sz % 2) ~= (tw % 2) then
      box_sz = box_sz - 1
    end

    -- GEOMETRY
    local line_h = NoteFonts.REGULAR:get_height()
    local border = 2

    local box_y = math.floor(bullet_y + (line_h - box_sz) / 2)
    local box_x = math.floor(bullet_x - (box_sz / 4))

    -- A. Draw Box Outline (Non-Interactive)
    table.insert(ctx.output, {
      type     = DRAW_MODE.RECT,
      x        = box_x,
      y        = box_y,
      w        = box_sz,
      h        = box_sz,
      color    = style.dim, 
    })

    if block.checked then
       -- [x] Checked: Pixel-Perfect Center Tick
       local tx = box_x + (box_sz - tw) / 2
       local ty = box_y +  (box_sz - th) / 2
       
       table.insert(ctx.output, {
        type  = DRAW_MODE.TEXT,
        x     = tx,
        y     = ty,
        text  = tick_char,
        font  = tick_font,
        color = style.background2,
      })
    else
      -- [ ] Unchecked: Draw Inner Square
      table.insert(ctx.output, {
        type  = DRAW_MODE.RECT,
        x     = box_x + border,
        y     = box_y + border,
        w     = box_sz - (border * 2),
        h     = box_sz - (border * 2),
        color = style.background2,
      })
    end
    
  else
    -- Standard Bullet/Number (Literal/Number color)
    local label = "•"
    if block.is_ordered and block.number then
      label = tostring(block.number) .. "."
      bullet_x = bullet_x - (NoteFonts.REGULAR:get_width(".") / 2)
    
    end

    table.insert(ctx.output, {
      type  = DRAW_MODE.TEXT,
      x     = bullet_x,
      y     = bullet_y,
      text  = label,
      font  = NoteFonts.REGULAR,
      color = NoteColors.bullet(),
    })
  end

  -- 3. Render Text Line
  local line_h = line_layout(ctx, block.text, nil, false, nil)
  
  if not next_block or next_block.type ~= BLOCK.LIST then
    ctx.y = ctx.y + line_h + L.LIST_GAP_BOTTOM
  else
    ctx.y = ctx.y + line_h
  end
end

local function draw_code(ctx, block)
  ctx.x      = L.BODY_X
  ctx.indent = L.BODY_X

  local font      = NoteFonts.CODE
  local line_h    = font:get_height()
  local pad_x     = L.CODE_PADDING_X
  local pad_y     = L.CODE_PADDING_Y
  local left_bg   = L.CODE_MARGIN
  local right_bg  = ctx.total_w - L.CODE_MARGIN

  ctx.y = ctx.y + L.CODE_GAP_TOP

  if block.lines and #block.lines > 0 then
    local rect_x = left_bg
    local rect_y = ctx.y
    local rect_w = right_bg - left_bg
    local rect_h = (#block.lines * line_h) + (2 * pad_y)

    table.insert(ctx.output, {
      type  = DRAW_MODE.RECT,
      x     = rect_x,
      y     = rect_y,
      w     = rect_w,
      h     = rect_h,
      color = NoteColors.code_bg(),
    })

    if (rect_x + rect_w) > ctx.max_seen_w then 
      ctx.max_seen_w = rect_x + rect_w 
    end

    -- text origin
    ctx.x = rect_x + pad_x
    ctx.y = rect_y + pad_y

    for _, line in ipairs(block.lines) do
      line_layout(ctx, line, nil, true, NoteColors.code())
      ctx.x = rect_x + pad_x -- reset x for next line
      ctx.y = ctx.y + line_h -- advance y by line height only
    end

    -- below the block
    ctx.x = L.BODY_X
    ctx.y = rect_y + rect_h
  end

  -- gap after block
  ctx.y = ctx.y + L.CODE_GAP_BOTTOM
end

local function draw_rule(ctx, block)
  ctx.y = ctx.y + L.RULE_GAP_TOP

  table.insert(ctx.output, {
    type  = DRAW_MODE.RECT,
    x     = L.HEADER_X,
    y     = ctx.y,
    w     = ctx.total_w - L.MARGIN_RIGHT - L.HEADER_X,
    h     = 2,
    color = NoteColors.rule(),
  })

  ctx.y = ctx.y + L.RULE_GAP_BOTTOM
end

local draw_ops = {
  [BLOCK.HEADER]    = draw_header,
  [BLOCK.PARAGRAPH] = draw_paragraph,
  [BLOCK.LIST]      = draw_list,
  [BLOCK.CODE]      = draw_code,
  [BLOCK.RULE]      = draw_rule,
}

local function compute(blocks, max_width)
  local draw_list = {}

  local ctx = {
    output     = draw_list,
    x          = 0,
    y          = L.VIEW_PADDING_TOP,
    max_w      = max_width - L.MARGIN_RIGHT,
    total_w    = max_width,
    max_seen_w = 0,
    indent     = 0,
    level      = 0,
  }

  for i = 1, #blocks do
    local block = blocks[i]
    local op = draw_ops[block.type]
    
    if op then
      op(ctx, block, blocks[i-1], blocks[i+1])
    end
  end

  return {
    list   = draw_list,
    height = ctx.y + 100,
    width  = ctx.max_seen_w,
  }
end

return {
  DRAW_MODE   = DRAW_MODE,
  load_assets = load_assets,
  compute     = compute,
}
