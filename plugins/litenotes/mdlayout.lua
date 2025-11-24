local core    = require "core"
local common  = require "core.common"
local style   = require "core.style"
local parser  = require "plugins.litenotes.mdparse"

local DRAW_MODE = { TEXT = 1, RECT = 2 }
local BLOCK     = parser.TOKENS.BLOCK
local SPAN      = parser.TOKENS.SPAN

-- -------------------------------------------------------------------------
-- LAYOUT CONSTANTS
-- -------------------------------------------------------------------------
local L = {
  -- Horizontal layout -------------------------------------------------------

  BODY_X       = 32,  -- Left indent for normal paragraph and list *text*.
                      -- Every paragraph and list item starts at this x.

  HEADER_X     = 16,  -- Left indent for headers (#, ##, ### ...)
                      -- Headers sit slightly further left than body text.

  LIST_INDENT  = 32,  -- Additional indent from the bullet symbol → list text.
                      -- Bullet is placed at BODY_X, text starts at (bullet + LIST_INDENT).

  MARGIN_RIGHT = 8,   -- Right margin for *text wrapping* and horizontal rules.
                      -- Text will wrap before reaching this far from the right edge.

  PAD_CODE_X   = 2,   -- Inline-code padding ( `inline` ), horizontal only.
                      -- Background rect extends 2px left/right of inline code text.

  -- Code block layout -------------------------------------------------------

  CODE_MARGIN      = 16, -- Distance from panel edge → code block background.
                         -- Used on BOTH left and right sides of the block.

  CODE_PADDING_X   = 6,  -- Horizontal padding *inside* fenced code blocks.
                         -- Distance from code-block BG → text on the left.
                         
  CODE_PADDING_Y   = 4,  -- Vertical padding *inside* fenced code blocks.
                         -- Distance from code-block BG → text on top & bottom.

  -- Vertical spacing between blocks ----------------------------------------

  VIEW_PADDING_TOP  = 8,  -- Extra top padding before the very first block.

  HEADER_GAP_TOP    = 8,   -- Gap placed *above* a header block.
  HEADER_GAP_BOTTOM = 16,  -- Gap placed *below* a header block.

  PARA_GAP_TOP      = 8,   -- Gap *before* a paragraph block.
  PARA_GAP_BOTTOM   = 8,   -- Gap *after* a paragraph block.

  -- Lists: block gaps vs intra-item spacing
  LIST_GAP_TOP      = 6,   -- Gap before a *run* of list items (above the first item).
  LIST_GAP_BOTTOM   = 6,   -- Gap after a *run* of list items (below the last item).
  LIST_SPACING      = 4,   -- Gap between individual list items inside the run.

  CODE_GAP_TOP      = 8,   -- Gap before an entire fenced code block.
  CODE_GAP_BOTTOM   = 8,   -- Gap after an entire fenced code block.

  RULE_GAP_TOP      = 8,   -- Gap before a horizontal rule (---).
  RULE_GAP_BOTTOM   = 8,   -- Gap after a horizontal rule.
}


-- -------------------------------------------------------------------------
-- THEME PALETTE
-- -------------------------------------------------------------------------
local NoteColors = {
  text    = function() return style.text end,
  header  = function() return style.syntax["keyword"] or style.accent end,
  code    = function() return style.syntax["string"]  or style.text end,
  bullet  = function() return style.syntax["operator"]  or style.accent end,
  rule    = function() return style.dim end,
  code_bg = function() return style.line_highlight end,
  dim     = function() return style.dim end,
}

-- Font handles are filled in by load_assets once per session.
local NoteFonts = {}

-- Initializes all fonts used by the notes renderer.
local function load_assets(config)
  local base_size = config.fonts.size

  NoteFonts.REGULAR = renderer.font.load(config.fonts.regular, base_size)
  NoteFonts.BOLD    = renderer.font.load(config.fonts.bold,    base_size)
  NoteFonts.ITALIC  = renderer.font.load(config.fonts.italic,  base_size)
  NoteFonts.CODE    = renderer.font.load(config.fonts.code,    base_size)

  -- Larger sizes per header level; H1 is largest, H5 is closest to body.
  local h_offsets = { 10, 6, 4, 2, 0 }
  NoteFonts.HEADER = {}

  for level, offset in ipairs(h_offsets) do
    local size = base_size + offset
    NoteFonts.HEADER[level] = {}
    NoteFonts.HEADER[level][SPAN.NONE]   = renderer.font.load(config.fonts.regular, size)
    NoteFonts.HEADER[level][SPAN.BOLD]   = renderer.font.load(config.fonts.bold,    size)
    NoteFonts.HEADER[level][SPAN.ITALIC] = renderer.font.load(config.fonts.italic,  size)
    -- Inline code inside headers uses the regular header font; no monospace there.
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
    -- A. Resolve font for this token
    local active_font
    if is_code_block then
      active_font = NoteFonts.CODE
    elseif base_font_set == NoteFonts.HEADER then
      active_font = base_font_set[ctx.level][token.style] or base_font_set[ctx.level][SPAN.NONE]
    else
      if token.style == SPAN.BOLD then
        active_font = NoteFonts.BOLD
      elseif token.style == SPAN.ITALIC then
        active_font = NoteFonts.ITALIC
      elseif token.style == SPAN.CODE then
        active_font = NoteFonts.CODE
      else
        active_font = NoteFonts.REGULAR
      end
    end

    -- B. Resolve color for this token
    local color = custom_color or NoteColors.text()
    if token.style == SPAN.CODE and not is_code_block then
      color = style.accent
    end

    -- C. Code block: raw layout, no wrapping
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
      ctx.x = ctx.x + w
      if ctx.x > ctx.max_seen_w then
        ctx.max_seen_w = ctx.x
      end

    -- D. Standard wrapping for non-block text
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
          -- Only whitespace, already advanced ctx.x.
        else
          for word, spacer in line_segment:gmatch("([^%s]+)(%s*)") do
            local full_word = word .. spacer
            local w = active_font:get_width(full_word)

            if ctx.x + w > ctx.max_w then
              ctx.x = ctx.indent
              ctx.y = ctx.y + active_font:get_height()
            end

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

            if ctx.x > ctx.max_seen_w then
              ctx.max_seen_w = ctx.x
            end
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

-- Converts parsed markdown blocks into a flat display list.
local function compute(blocks, max_width)
  local draw_list = {}

  local ctx = {
    output     = draw_list,
    x          = 0,
    y          = L.VIEW_PADDING_TOP,
    max_w      = max_width - L.MARGIN_RIGHT,
    max_seen_w = 0,
    indent     = 0,
    level      = 0,
  }

  for i = 1, #blocks do
    local block      = blocks[i]
    local prev_block = blocks[i - 1]
    local next_block = blocks[i + 1]

    -- 1. HEADERS ------------------------------------------------------------
    if block.type == BLOCK.HEADER then
      ctx.y      = ctx.y + L.HEADER_GAP_TOP
      ctx.x      = L.HEADER_X
      ctx.indent = L.HEADER_X
      ctx.level  = math.min(block.arg, 5)

      local line_h = line_layout(ctx, block.text, NoteFonts.HEADER, false, NoteColors.header())
      ctx.y = ctx.y + line_h + L.HEADER_GAP_BOTTOM

    -- 2. PARAGRAPHS ---------------------------------------------------------
    elseif block.type == BLOCK.PARAGRAPH then
      ctx.y      = ctx.y + L.PARA_GAP_TOP
      ctx.x      = L.BODY_X
      ctx.indent = L.BODY_X

      local line_h = line_layout(ctx, block.text, nil, false, nil)
      ctx.y = ctx.y + line_h + L.PARA_GAP_BOTTOM

    -- 3. UNORDERED LIST ITEMS ----------------------------------------------
    elseif block.type == BLOCK.LIST then
      local bullet_x = L.BODY_X
      local text_x   = bullet_x + L.LIST_INDENT

      -- Block-level gap before the first item in a run,
      -- or intra-list spacing between items.
      if not prev_block or prev_block.type ~= BLOCK.LIST then
        ctx.y = ctx.y + L.LIST_GAP_TOP
      else
        ctx.y = ctx.y + L.LIST_SPACING
      end

      ctx.x      = text_x
      ctx.indent = text_x

      local bullet_y = ctx.y
      draw_list[#draw_list + 1] = {
        type  = DRAW_MODE.TEXT,
        x     = bullet_x,
        y     = bullet_y,
        text  = "•",
        font  = NoteFonts.REGULAR,
        color = NoteColors.bullet(),
      }

      local line_h = line_layout(ctx, block.text, nil, false, nil)

      -- If this is the last item in the run, add LIST_GAP_BOTTOM
      if not next_block or next_block.type ~= BLOCK.LIST then
        ctx.y = ctx.y + line_h + L.LIST_GAP_BOTTOM
      else
        ctx.y = ctx.y + line_h
      end

    -- 4. CODE BLOCKS --------------------------------------------------------
    elseif block.type == BLOCK.CODE then
      ctx.x      = L.BODY_X
      ctx.indent = L.BODY_X

      local font      = NoteFonts.CODE
      local line_h    = font:get_height()
      local pad_x     = L.CODE_PADDING_X
      local pad_y     = L.CODE_PADDING_Y
      local left_bg   = L.CODE_MARGIN
      local right_bg  = max_width - L.CODE_MARGIN

      -- gap before block
      ctx.y = ctx.y + L.CODE_GAP_TOP

      if block.lines and #block.lines > 0 then
        -- single background rect for entire block
        local rect_x = left_bg
        local rect_y = ctx.y
        local rect_w = right_bg - left_bg
        local rect_h = (#block.lines * line_h) + (2 * pad_y)

        draw_list[#draw_list + 1] = {
          type  = DRAW_MODE.RECT,
          x     = rect_x,
          y     = rect_y,
          w     = rect_w,
          h     = rect_h,
          color = NoteColors.code_bg(),
        }

        -- update max width
        local right = rect_x + rect_w
        if right > ctx.max_seen_w then ctx.max_seen_w = right end

        -- text origin
        ctx.x = rect_x + pad_x
        ctx.y = rect_y + pad_y

        -- lines inside block
        for _, line in ipairs(block.lines) do
          line_layout(ctx, line, nil, true, NoteColors.code())
          ctx.x = rect_x + pad_x     -- reset x for next line
          ctx.y = ctx.y + line_h     -- advance y by line height only
        end

        -- below the block
        ctx.x = L.BODY_X
        ctx.y = rect_y + rect_h
      end

      -- gap after block
      ctx.y = ctx.y + L.CODE_GAP_BOTTOM

    -- 5. HORIZONTAL RULES ---------------------------------------------------
    elseif block.type == BLOCK.RULE then
      ctx.y = ctx.y + L.RULE_GAP_TOP

      draw_list[#draw_list + 1] = {
        type  = DRAW_MODE.RECT,
        x     = L.HEADER_X,
        y     = ctx.y,
        w     = max_width - L.MARGIN_RIGHT - L.HEADER_X,
        h     = 2,
        color = NoteColors.rule(),
      }

      ctx.y = ctx.y + L.RULE_GAP_BOTTOM
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

