local core    = require "core"
local common  = require "core.common"
local style   = require "core.style"
local parser  = require "plugins.litemark.mdparse"
local config  = require "plugins.litemark.config"

-- SYNTAX HIGHLIGHTING DEPENDENCIES
local tokenizer = require "core.tokenizer"
local syntax    = require "core.syntax"

local DRAW_MODE = { TEXT = 1, RECT = 2, CANVAS = 3 }
local BLOCK     = parser.TOKENS.BLOCK
local SPAN      = parser.TOKENS.SPAN

-- -------------------------------------------------------------------------
-- LAYOUT CONSTANTS
-- -------------------------------------------------------------------------
-- All values here are in "ems" relative to the base font size.
-- We convert them to pixels once in load_assets.
local SCALES = {
  
  VIEW_PADDING_TOP    = 0.5,     -- top padding before the first block in the document
  VIEW_MARGIN_LEFT    = 2.0,     -- left margin (in ems) for normal body text and paragraphs
  VIEW_MARGIN_RIGHT   = 1.0,     -- right-hand margin between content and the viewport edge/scrollbar
  
  HEADER_GAP_TOP      = 0.5,     -- vertical gap above a header block
  HEADER_GAP_BOTTOM   = 1.0,     -- vertical gap below a header block (before next block)
  HEADER_MARGIN_LEFT  = 1.0,     -- left margin for headers and horizontal rules
  RULE_GAP_TOP        = 0.5,     -- vertical gap above a horizontal rule (---)
  RULE_GAP_BOTTOM     = 0.5,     -- vertical gap below a horizontal rule
  
  PARA_GAP_TOP        = 0.5,     -- vertical gap above a paragraph
  PARA_GAP_BOTTOM     = 0.5,     -- vertical gap below a paragraph
  
  LIST_GAP_TOP        = 0.375,   -- vertical gap before the first item of a list run
  LIST_GAP_BOTTOM     = 0.375,   -- vertical gap after the last item of a list run
  LIST_INDENT         = 2.0,     -- per-level list nesting indent AND gap between bullet/number and text
  LIST_SPACING        = 0.25,    -- vertical spacing between list items inside the same list

  CODE_PADDING_X      = 0.375,   -- horizontal padding inside fenced code block bg before code text
  CODE_PADDING_Y      = 0.25,    -- vertical padding inside fenced code block bg above/below text
  CODE_MARGIN         = 1.0,     -- left/right margin of fenced code block background vs viewport
  CODE_GAP_TOP        = 0.5,     -- vertical gap above a fenced code block bg
  CODE_GAP_BOTTOM     = 0.5,     -- vertical gap below a fenced code block bg
  INLINE_CODE_PAD     = 0.125,   -- horizontal padding around INLINE code spans (inside their bg box)
}



-- Concrete pixel values; filled once in load_assets.
local L = {}

-- -------------------------------------------------------------------------
-- THEME PALETTE
-- -------------------------------------------------------------------------
-- Small helpers to resolve colors lazily from style,
-- so theme changes are picked up automatically.
local NoteColors = {
  text        = function() return style.text end,
  header      = function() return style.syntax["keyword"] or style.accent end,
  code        = function() return style.syntax["string"]  or style.text end,
  bullet      = function() return style.syntax["number"] or style.accent end, 
  rule        = function() return style.dim end,
  header_rule = function() return style.syntax["comment"] or style.dim end,
  code_bg     = function() return style.background end,
  dim         = function() return style.dim end,
}

-- Fonts used by the layout engine.
-- Populated in load_assets.
local NoteFonts = {}

-- load_assets(config)
-- Initializes layout metrics (L[...]) and loads all fonts
-- based on the configured base font size and file paths.
local function load_assets(config)
  local base_size = config.fonts.size

  -- 1. Bake em-based layout constants into pixels.
  for k, scale in pairs(SCALES) do
    L[k] = math.floor(base_size * scale)
  end

  -- 2. Load core font faces.
  NoteFonts.REGULAR = renderer.font.load(config.fonts.regular, base_size)
  NoteFonts.BOLD    = renderer.font.load(config.fonts.bold,    base_size)
  NoteFonts.ITALIC  = renderer.font.load(config.fonts.italic,  base_size)
  NoteFonts.CODE    = renderer.font.load(config.fonts.code,    base_size)

  -- 3. Per-level header font families.
  -- Higher level == larger size.
  local h_offsets = { 10, 6, 4, 2, 0 }
  NoteFonts.HEADER = {}

  for level, offset in ipairs(h_offsets) do
    local size = base_size + offset
    NoteFonts.HEADER[level] = {}
    NoteFonts.HEADER[level][SPAN.NONE]   = renderer.font.load(config.fonts.regular, size)
    NoteFonts.HEADER[level][SPAN.BOLD]   = renderer.font.load(config.fonts.bold,    size)
    NoteFonts.HEADER[level][SPAN.ITALIC] = renderer.font.load(config.fonts.italic,  size)
    -- Code spans in headers use the same metric as plain header text.
    NoteFonts.HEADER[level][SPAN.CODE]   = NoteFonts.HEADER[level][SPAN.NONE]
  end
end

-- -------------------------------------------------------------------------
-- SYNTAX HELPERS
-- -------------------------------------------------------------------------

-- resolve_syntax(lang)
-- Maps a fence "lang" label to a dummy filename that Lite XL's
-- syntax system understands, then returns the syntax object.
local function resolve_syntax(lang)
  if not lang then return nil end

  -- Map common fence names to dummy filenames recognized by syntax.get.
  local map = {
    js   = "f.js",   javascript = "f.js",
    py   = "f.py",   python     = "f.py",
    rb   = "f.rb",   ruby       = "f.rb",
    sh   = "f.sh",   bash       = "f.sh",
    md   = "f.md",   markdown   = "f.md",
    c    = "f.c",
    cpp  = "f.cpp",
    h    = "f.h",
    lua  = "f.lua",
    xml  = "f.xml",
    html = "f.html",
    css  = "f.css",
    json = "f.json",
    odin = "f.odin",
    go   = "f.go",
    rs   = "f.rs",   rust       = "f.rs",
  }

  local fname = map[lang] or ("fake." .. lang)
  return syntax.get(fname)
end

-- ensure_block_tokens(block)
-- If the code block has a language, run Lite XL's tokenizer over each line
-- and attach a flat {type, text, type, text, ...} list per line as block.tokens[i].
local function ensure_block_tokens(block)
  -- If no recorded lang, or we've already tokenized, just bail.
  if not block.lang or block.tokens then return end

  local syn = resolve_syntax(block.lang)
  if not syn then return end

  block.tokens = {}
  local state = nil -- Tokenizer state (carry across lines for multi-line constructs).

  for i, line in ipairs(block.lines) do
    -- tokenizer.tokenize returns a flat list { type, text, type, text, ... }.
    local tokens, new_state = tokenizer.tokenize(syn, line, state)
    block.tokens[i] = tokens
    state = new_state
  end
end

-- -------------------------------------------------------------------------
-- LAYOUT ENGINE
-- -------------------------------------------------------------------------

-- line_layout(ctx, text, base_font_set, is_code_block, custom_color)
-- Core text layout routine for paragraphs, headers, inline spans and
-- fallback code rendering.
--
-- - ctx: layout context (x, y, indent, max_w, etc.)
-- - text: raw string to render
-- - base_font_set:
--     * nil            -> body fonts (REGULAR/BOLD/ITALIC/CODE)
--     * NoteFonts.HEADER -> pick header fonts based on ctx.level and span style
-- - is_code_block:
--     * true  -> treat 'text' as raw, no inline span parsing / wrapping logic
--     * false -> parse spans and wrap words
-- - custom_color:
--     * nil  -> autoselect based on span
--     * rgba -> force color for all spans on this line
--
-- Returns the line height in pixels used for this block.
local function line_layout(ctx, text, base_font_set, is_code_block, custom_color)
  local draw_list = ctx.output
  local tokens

  if is_code_block then
    -- Whole line as a single "token" with no span styles.
    tokens = { { text = text, style = SPAN.NONE } }
  else
    -- Ask the markdown parser for inline spans (bold, italics, code, etc).
    tokens = parser.parse_spans(text, ctx.span_rules)
  end

  for _, token in ipairs(tokens) do
    ------------------------------------------------------------------------
    -- A. Resolve font for this token
    ------------------------------------------------------------------------
    local active_font
    if is_code_block then
      active_font = NoteFonts.CODE
    elseif base_font_set == NoteFonts.HEADER then
      -- Header base set: pick by level + span style
      active_font =
        base_font_set[ctx.level][token.style]
        or base_font_set[ctx.level][SPAN.NONE]
    else
      -- Body text fonts
      if token.style == SPAN.BOLD      then active_font = NoteFonts.BOLD
      elseif token.style == SPAN.ITALIC then active_font = NoteFonts.ITALIC
      elseif token.style == SPAN.CODE   then active_font = NoteFonts.CODE
      elseif token.style == SPAN.STRIKE then active_font = NoteFonts.REGULAR
      else active_font = NoteFonts.REGULAR end
    end

    ------------------------------------------------------------------------
    -- B. Resolve color
    ------------------------------------------------------------------------
    local color = custom_color or NoteColors.text()
    if token.style == SPAN.CODE and not is_code_block then
      -- Inline code: different color (and background) than body text.
      color = NoteColors.code()
    end

    ------------------------------------------------------------------------
    -- C. Code block: raw (no wrapping, no inline layout)
    ------------------------------------------------------------------------
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
      if w + ctx.x > ctx.max_seen_w then
        ctx.max_seen_w = w + ctx.x
      end

    ------------------------------------------------------------------------
    -- D. Standard wrapping / inline layout
    ------------------------------------------------------------------------
    else
      local start_idx = 1
      while start_idx <= #token.text do
        local s, e = token.text:find("\n", start_idx)
        local line_segment = s and token.text:sub(start_idx, s - 1)
                            or token.text:sub(start_idx)

        -- Leading spaces move x but don't trigger words
        local lead_space = line_segment:match("^(%s+)")
        if lead_space then
          ctx.x = ctx.x + active_font:get_width(lead_space)
        end

        if lead_space == line_segment and #line_segment > 0 then
          -- Only whitespace on this segment; nothing else to draw
        else
          -- Walk "word + trailing spaces" pairs
          for word, spacer in line_segment:gmatch("([^%s]+)(%s*)") do
            local full_word = word .. spacer
            local w = active_font:get_width(full_word)

            -- Wrap if this word would overflow the line
            if ctx.x + w > ctx.max_w then
              ctx.x = ctx.indent
              ctx.y = ctx.y + active_font:get_height()
            end

            -- STRIKETHROUGH decoration
            if token.style == SPAN.STRIKE then
              local line_h = active_font:get_height()
              local line_y = ctx.y + math.floor(line_h / 2)
              draw_list[#draw_list + 1] = {
                type  = DRAW_MODE.RECT,
                x     = ctx.x - 3,
                y     = line_y,
                w     = w + 6,
                h     = 2,
                color = color,
              }
            end
            
            -- INLINE CODE with background box
            if token.style == SPAN.CODE then
              ctx.x = ctx.x + L.INLINE_CODE_PAD
              draw_list[#draw_list + 1] = {
                type  = DRAW_MODE.RECT,
                x     = ctx.x - L.INLINE_CODE_PAD,
                y     = ctx.y,
                w     = w + (L.INLINE_CODE_PAD * 2),
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
              ctx.x = ctx.x + w + L.INLINE_CODE_PAD

            -- STANDARD TEXT
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
          -- Hard newline: reset x, advance y by one line of this font
          ctx.x = ctx.indent
          ctx.y = ctx.y + active_font:get_height()
          start_idx = e + 1
        else
          break
        end
      end
    end
  end

  --------------------------------------------------------------------------
  -- Return the line height that should be added after this block
  --------------------------------------------------------------------------
  if is_code_block then
    return NoteFonts.CODE:get_height()
  end

  -- Header: use the per-level header font's height, not body height.
  if base_font_set == NoteFonts.HEADER then
    local lvl = ctx.level or 1
    local header_font =
      base_font_set[lvl] and base_font_set[lvl][SPAN.NONE]
      or NoteFonts.REGULAR
    return header_font:get_height()
  end

  -- Default: body line height.
  return NoteFonts.REGULAR:get_height()
end

-- -------------------------------------------------------------------------
-- DRAW HANDLERS (per block type)
-- -------------------------------------------------------------------------

-- draw_header(ctx, block)
-- Renders a Markdown ATX header block (H1..H5) and, optionally, a thin
-- underline for levels 1–2 using the header_rule color.
local function draw_header(ctx, block)
  -- Top gap before the header text
  ctx.y      = ctx.y + L.HEADER_GAP_TOP
  ctx.x      = L.HEADER_MARGIN_LEFT
  ctx.indent = L.HEADER_MARGIN_LEFT

  local level = math.min(block.arg or 1, 5)
  ctx.level   = level

  -- Lay out the header text. line_h now reflects the header font height
  -- for this level (via line_layout's header branch).
  local line_h      = line_layout(ctx, block.text, NoteFonts.HEADER, false, NoteColors.header())
  local text_bottom = ctx.y + line_h

  -- Optional underline under H1/H2, spaced relative to header size.
  if config.header_rules ~= false and level <= 2 then
    -- Fraction of header line height (e.g. 20%); ensures H1/H2 differ.
    local rule_gap = math.max(1, math.floor(line_h * 0.1))

    table.insert(ctx.output, {
      type  = DRAW_MODE.RECT,
      x     = L.HEADER_MARGIN_LEFT,
      y     = text_bottom + rule_gap,
      w     = ctx.total_w - L.VIEW_MARGIN_RIGHT - L.HEADER_MARGIN_LEFT,
      h     = 1,
      color = NoteColors.header_rule(),
    })

    ctx.y = text_bottom + rule_gap + L.HEADER_GAP_BOTTOM
  else
    ctx.y = text_bottom + L.HEADER_GAP_BOTTOM
  end
end

-- draw_paragraph(ctx, block)
-- Renders a plain paragraph block with top/bottom padding.
local function draw_paragraph(ctx, block)
  ctx.y      = ctx.y + L.PARA_GAP_TOP
  ctx.x      = L.VIEW_MARGIN_LEFT
  ctx.indent = L.VIEW_MARGIN_LEFT

  local line_h = line_layout(ctx, block.text, nil, false, nil)
  ctx.y = ctx.y + line_h + L.PARA_GAP_BOTTOM
end

-- draw_list(ctx, block, prev_block, next_block)
-- Renders list items (ordered, bullet, or checkbox-style task list).
-- Uses nesting level to compute indentation.
local function draw_list(ctx, block, prev_block, next_block)
  -- Horizontal positions: nested indent, bullet, then text.
  local nest_offset = (block.level or 0) * L.LIST_INDENT
  local bullet_x    = L.VIEW_MARGIN_LEFT + nest_offset
  local text_x      = bullet_x + L.LIST_INDENT

  -- Vertical spacing between items or list groups
  if not prev_block or prev_block.type ~= BLOCK.LIST then
    ctx.y = ctx.y + L.LIST_GAP_TOP
  else
    ctx.y = ctx.y + L.LIST_SPACING
  end

  ctx.x      = text_x
  ctx.indent = text_x
  local bullet_y = ctx.y

  if block.checked ~= nil then
    ----------------------------------------------------------------------
    -- Task list: render a checkbox (checked/unchecked) instead of bullet.
    ----------------------------------------------------------------------
    local tick_char = "✓"
    local tick_font = NoteFonts.BOLD
    
    local tw = math.floor(tick_font:get_width(tick_char))
    local th = tick_font:get_height()
    
    local box_sz = math.floor(config.fonts.size)
    -- Make sure box width/height parity matches glyph width so the tick
    -- can be visually centered.
    if (box_sz % 2) ~= (tw % 2) then
      box_sz = box_sz - 1
    end

    local line_h = NoteFonts.REGULAR:get_height()
    local border = 2

    local box_y = math.floor(bullet_y + (line_h - box_sz) / 2)
    local box_x = math.floor(bullet_x - (box_sz / 4))

    -- Outer box
    table.insert(ctx.output, {
      type  = DRAW_MODE.RECT,
      x     = box_x,
      y     = box_y,
      w     = box_sz,
      h     = box_sz,
      color = style.dim,
    })

    if block.checked then
      -- Filled box with tick
      local tx = box_x + (box_sz - tw) / 2
      local ty = box_y + (box_sz - th) / 2
      table.insert(ctx.output, {
        type  = DRAW_MODE.TEXT,
        x     = tx,
        y     = ty,
        text  = tick_char,
        font  = tick_font,
        color = style.background2,
      })
    else
      -- Inner background to fake a 1px border
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
    ----------------------------------------------------------------------
    -- Regular bullet / ordered list marker
    ----------------------------------------------------------------------
    local label = "•"
    if block.is_ordered and block.number then
      label = tostring(block.number) .. "."
      -- Nudge ordered labels slightly left so the dot aligns visually.
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

  -- Layout the list item text.
  local line_h = line_layout(ctx, block.text, nil, false, nil)
  
  if not next_block or next_block.type ~= BLOCK.LIST then
    ctx.y = ctx.y + line_h + L.LIST_GAP_BOTTOM
  else
    ctx.y = ctx.y + line_h
  end
end

-- draw_code(ctx, block)
-- Renders a fenced code block:
-- - Optional syntax-highlighted tokens from ensure_block_tokens
-- - Padded background rect spanning the full width (minus margins)
local function draw_code(ctx, block)
  ctx.x      = L.VIEW_MARGIN_LEFT
  ctx.indent = L.VIEW_MARGIN_LEFT

  -- 1. Populate block.tokens if we have a language
  ensure_block_tokens(block)

  local font     = NoteFonts.CODE
  local line_h   = font:get_height()
  local pad_x    = L.CODE_PADDING_X
  local pad_y    = L.CODE_PADDING_Y
  local left_bg  = L.CODE_MARGIN
  local right_bg = ctx.total_w - L.CODE_MARGIN

  ctx.y = ctx.y + L.CODE_GAP_TOP

  if block.lines and #block.lines > 0 then
    -- Background rect behind the entire code block
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

    -- Text origin inside padded rect
    local base_x = rect_x + pad_x
    ctx.y = rect_y + pad_y

    for i, line in ipairs(block.lines) do
      ctx.x = base_x

      if block.tokens and block.tokens[i] then
        --------------------------------------------------------------------
        -- Syntax-highlighted path: draw each token with style.syntax[type]
        --------------------------------------------------------------------
        local row_tokens = block.tokens[i]

        -- Token list is flat: { type, text, type, text, ... }
        for j = 1, #row_tokens, 2 do
          local type = row_tokens[j]
          local text = row_tokens[j + 1]

          local color = style.syntax[type] or NoteColors.code()

          table.insert(ctx.output, {
            type  = DRAW_MODE.TEXT,
            x     = ctx.x,
            y     = ctx.y,
            text  = text,
            font  = font,
            color = color,
          })

          ctx.x = ctx.x + font:get_width(text)
        end

        if ctx.x > ctx.max_seen_w then
          ctx.max_seen_w = ctx.x
        end
      else
        --------------------------------------------------------------------
        -- Fallback path: monochrome layout via line_layout in code mode
        --------------------------------------------------------------------
        line_layout(ctx, line, nil, true, NoteColors.code())
      end

      -- Next code line
      ctx.y = ctx.y + line_h
    end

    -- Position cursor below the block
    ctx.x = L.VIEW_MARGIN_LEFT
    ctx.y = rect_y + rect_h
  end

  ctx.y = ctx.y + L.CODE_GAP_BOTTOM
end

-- draw_rule(ctx, block)
-- Renders a horizontal rule (---) as a full-width 2px line.
local function draw_rule(ctx, block)
  ctx.y = ctx.y + L.RULE_GAP_TOP

  table.insert(ctx.output, {
    type  = DRAW_MODE.RECT,
    x     = L.HEADER_MARGIN_LEFT,
    y     = ctx.y,
    w     = ctx.total_w - L.VIEW_MARGIN_RIGHT - L.HEADER_MARGIN_LEFT,
    h     = 2,
    color = NoteColors.rule(),
  })

  ctx.y = ctx.y + L.RULE_GAP_BOTTOM
end

-- Dispatch table from block.type -> draw handler.
local draw_ops = {
  [BLOCK.HEADER]    = draw_header,
  [BLOCK.PARAGRAPH] = draw_paragraph,
  [BLOCK.LIST]      = draw_list,
  [BLOCK.CODE]      = draw_code,
  [BLOCK.RULE]      = draw_rule,
}

-- compute(blocks, max_width, options)
-- Main layout entry point.
-- Walks the parsed block list and emits a flat list of drawing commands
-- (text and rects), plus the overall document height and max content width.
local function compute(blocks, max_width, options)
  local draw_list = {}

  local ctx = common.merge({
    output     = draw_list,
    x          = 0,
    y          = L.VIEW_PADDING_TOP,
    max_w      = max_width - L.VIEW_MARGIN_RIGHT,
    total_w    = max_width,
    max_seen_w = 0,
    indent     = 0,
    level      = 0,
  }, options or {})

  for i = 1, #blocks do
    local block = blocks[i]
    local op    = draw_ops[block.type]
    
    if op then
      op(ctx, block, blocks[i - 1], blocks[i + 1])
    end
  end

  return {
    list   = draw_list,
    height = ctx.y + 100,   -- pad bottom so last lines aren't cramped
    width  = ctx.max_seen_w,
  }
end

return {
  DRAW_MODE   = DRAW_MODE,
  L           = L,
  draw_ops    = draw_ops,
  load_assets = load_assets,
  compute     = compute,
}

