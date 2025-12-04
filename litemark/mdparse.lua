-- -------------------------------------------------------------------------
-- DATA SCHEMA (SINGLE SOURCE OF TRUTH)
-- -------------------------------------------------------------------------

local TOKENS = {
  BLOCK = {
    HEADER    = 1,
    PARAGRAPH = 2,
    CODE      = 3,
    LIST      = 4,
    RULE      = 5
  },
  
  SPAN = {
    NONE   = 0,
    BOLD   = 1,
    ITALIC = 2,
    CODE   = 4,
    STRIKE = 5,
  }
}

-- -------------------------------------------------------------------------
-- INTERNAL HELPERS
-- -------------------------------------------------------------------------

local str_match = string.match
local str_sub   = string.sub
local str_find  = string.find
local t_insert  = table.insert

-- -------------------------------------------------------------------------
-- PHASE 1: BLOCK HANDLERS
-- -------------------------------------------------------------------------

local function handle_code_open(state, line, lang, c2, c3, line_idx)
  state.in_fence = "```"
  
  -- Normalize language: "Lua" -> "lua", empty -> nil
  local clean_lang = lang and lang:lower() or nil
  if clean_lang == "" then clean_lang = nil end

  t_insert(state.blocks, { 
    type  = TOKENS.BLOCK.CODE, 
    lines = {}, 
    arg   = nil,
    lang  = clean_lang 
  })
  return true
end

local function handle_header(state, line, hashes, content, c3, line_idx)
  t_insert(state.blocks, { type = TOKENS.BLOCK.HEADER, text = content, arg = #hashes })
  return true
end

local function handle_list_ordered(state, line, spaces, number, content, line_idx)
  t_insert(state.blocks, { 
    type       = TOKENS.BLOCK.LIST, 
    text       = content,
    is_ordered = true,
    number     = tonumber(number),
    level      = math.floor(#spaces / 2),
    line       = line_idx 
  })
  return true
end

local function handle_list_unordered(state, line, spaces, bullet, content, line_idx)
  local checked = nil
  local prefix = content:sub(1, 4)
  
  if prefix == "[ ] " then
    checked = false
    content = content:sub(5)
  elseif prefix == "[x] " or prefix == "[X] " then
    checked = true
    content = content:sub(5)
  end

  t_insert(state.blocks, { 
    type       = TOKENS.BLOCK.LIST, 
    text       = content,
    is_ordered = false,
    number     = nil,
    level      = math.floor(#spaces / 2),
    checked    = checked, 
    line       = line_idx 
  })
  return true
end

local function handle_rule(state, line, c1, c2, c3, line_idx)
  t_insert(state.blocks, { type = TOKENS.BLOCK.RULE })
  return true
end

local function handle_blank(state, line, _, _, _, line_idx)
  -- Blank line: end of any "paragraph run".
  -- Paragraph handler will see last_was_blank == true and start a new block.
  state.last_was_blank = true
  -- If you want to auto-close code blocks on blank lines, do it here:
  -- state.in_fence= false
end


local function handle_paragraph(state, line, _, _, _, line_idx)
  local blocks = state.blocks
  local last   = blocks[#blocks]

  if last and last.type == TOKENS.BLOCK.PARAGRAPH and not state.last_was_blank then
    -- Same paragraph run: append with a space
    last.text = last.text .. " " .. line
  else
    -- Either first paragraph, or there was a blank line: start a new paragraph
    table.insert(blocks, {
      type = TOKENS.BLOCK.PARAGRAPH,
      text = line,
      line = line_idx,
    })
  end
  
  -- We've just seen a non-blank text line
  state.last_was_blank = false
end


-- -------------------------------------------------------------------------
-- PHASE 1 RULES (Block Priority)
-- -------------------------------------------------------------------------

local default_block_rules = {
  { "^```%s*(%S*)",                     handle_code_open     },
  { "^(#+)%s+(.*)",                     handle_header         },
  { "^(%s*)(%d+)%.%s+(.*)",             handle_list_ordered   },
  { "^(%s*)([%-%*%+])%s+(.*)",          handle_list_unordered },
  { "^%-%-%-+$",                        handle_rule           },
  { "^%s*$",                            handle_blank          },
}

-- -------------------------------------------------------------------------
-- PHASE 2 RULES (Span Priority)
-- -------------------------------------------------------------------------

local default_span_rules = {
  { type = TOKENS.SPAN.CODE,   pattern = "(`+)(.-)%1",      content_idx = 2 },
  -- NEW: Bold+Italic (Must be before Bold/Italic)
  { type = TOKENS.SPAN.BOLD,   pattern = "%*%*%*(.-)%*%*%*", content_idx = 1 }, 
  { type = TOKENS.SPAN.BOLD,   pattern = "%*%*(.-)%*%*",    content_idx = 1 },
  { type = TOKENS.SPAN.ITALIC, pattern = "%*([^%s].-)%*",   content_idx = 1 },
  -- NEW: Underscore Italic
  { type = TOKENS.SPAN.ITALIC, pattern = "_([^%s].-)_",     content_idx = 1 },
  { type = TOKENS.SPAN.STRIKE, pattern = "~~(.*)~~",        content_idx = 1 }
}

-- -------------------------------------------------------------------------
-- PARSER ENGINE
-- -------------------------------------------------------------------------

-- parse_blocks(raw_text)
-- Parse Markdown source into a flat list of block records.
local function parse_blocks(raw_text, block_rules)
  local blocks = {}
  local state = {
    blocks         = blocks,
    in_fence       = false, -- true while inside ``` fenced blocks
    last_was_blank = false, -- true if the previous *non-code* line was blank
  }

  -- Normalize tabs: treat them as 4 spaces for indentation / list levels.
  raw_text = raw_text:gsub("\t", "    ")
  local line_idx = 0

  -- Iterate over all lines, including a final empty line if present.
  for line in raw_text:gmatch("([^\r\n]*)\r?\n?") do
    line_idx = line_idx + 1

    -------------------------------------------------------------------------
    -- A. Inside fenced code: accumulate lines until closing fence
    -------------------------------------------------------------------------
    if state.in_fence then
      local fence_blk = blocks[#blocks]
      if str_match(line, "^" .. state.in_fence) then
        -- Closing fence: exit code mode, do not emit a block here
        state.in_fence = false
        if fence_blk and fence_blk.close then
          fence_blk:close()
        end
      else
        -- Still inside code: append raw line to the last CODE block's lines
        if fence_blk then
          t_insert(fence_blk.lines, line)
        end
      end

    -------------------------------------------------------------------------
    -- B. Normal mode: run block rules, else treat as paragraph text
    -------------------------------------------------------------------------
    else
      local matched = false

      -- Try each block rule in order. The first one that matches wins.
      for _, rule in ipairs(block_rules or default_block_rules) do
        -- One match call per rule; works for both captured and non-captured patterns.
        local c1, c2, c3 = str_match(line, rule[1])
        if c1 then
          -- Handler signature: (state, line, c1, c2, c3, line_idx)
          rule[2](state, line, c1, c2, c3, line_idx)
          matched = true
          break
        end
      end

      if not matched then
        -- No block rule matched: treat as paragraph content.
        -- Use the same handler so "line" metadata is consistent.
        handle_paragraph(state, line, nil, nil, nil, line_idx)
      end
      -- Note: we do NOT touch last_was_blank here.
      -- Each handler is responsible for updating state.last_was_blank explicitly.
    end
  end

  return blocks
end


-- Helper to find the next occurrence of a specific rule
local function scan_next(text, rule, pos)
  local s, e, c1, c2 = str_find(text, rule.pattern, pos)
  if not s then return nil end
  local content
  if rule.content_idx == 1 then content = c1
  elseif rule.content_idx == 2 then content = c2
  end
  return { s = s, e = e, text = content, type = rule.type, rule = rule }
end

local function parse_spans(text, span_rules)
  local tokens = {}
  local pos = 1
  local len = #text

  local next_matches = {}
  for _, rule in ipairs(span_rules or default_span_rules) do
    local match = scan_next(text, rule, pos)
    if match then t_insert(next_matches, match) end
  end

  while pos <= len do
    local i = 1
    while i <= #next_matches do
      local match = next_matches[i]
      if match.s < pos then
        local next_one = scan_next(text, match.rule, pos)
        if next_one then
          next_matches[i] = next_one; i = i + 1
        else
          table.remove(next_matches, i)
        end
      else
        i = i + 1
      end
    end

    local best_idx = nil
    local best_match = nil

    for idx, match in ipairs(next_matches) do
      if not best_match or match.s < best_match.s then
        best_match = match; best_idx = idx
      elseif match.s == best_match.s and idx < best_idx then
         best_match = match; best_idx = idx
      end
    end

    if not best_match then
      t_insert(tokens, { style = TOKENS.SPAN.NONE, text = str_sub(text, pos) })
      break
    else
      if best_match.s > pos then
        t_insert(tokens, { style = TOKENS.SPAN.NONE, text = str_sub(text, pos, best_match.s - 1) })
      end
      t_insert(tokens, { style = best_match.type, text = best_match.text })
      pos = best_match.e + 1

      local new_match = scan_next(text, best_match.rule, pos)
      if new_match then next_matches[best_idx] = new_match
      else table.remove(next_matches, best_idx) end
    end
  end

  return tokens
end

return {
  TOKENS       = TOKENS,
  default_span_rules = default_span_rules,
  default_block_rules  = default_block_rules,
  parse_blocks = parse_blocks,
  parse_spans  = parse_spans,
  handle_list_unordered = handle_list_unordered, 
}
