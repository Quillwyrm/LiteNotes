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
    CODE   = 4 
  }
}

-- -------------------------------------------------------------------------
-- INTERNAL HELPERS
-- -------------------------------------------------------------------------

local str_match = string.match
local str_sub   = string.sub
local str_find  = string.find

-- Nuclear-Safe Masking Pattern (Plaintext is safer than control chars)
local MASK_PRE  = "___C"
local MASK_SUF  = "___"
local MASK_PATT = "___C%d+___"

-- -------------------------------------------------------------------------
-- PHASE 1: BLOCK PARSER
--   Walks the raw markdown text line by line and builds a flat list of
--   block nodes (headers, paragraphs, lists, code fences, rules).
--   Handles code fences first, then groups adjacent lines into the
--   correct block type so later stages don’t care about raw line breaks.
-- -------------------------------------------------------------------------
local function parse_blocks(raw_text)
  local blocks = {}
  local block_count = 0
  
  -- Sanitize: Expand tabs to spaces globally to fix indentation issues
  raw_text = raw_text:gsub("\t", "    ")
  
  local in_code_fence = false
  local last_line_was_blank = false

  for line in raw_text:gmatch("([^\r\n]*)\r?\n?") do
    
    -- 1. CODE FENCE TOGGLE
    if str_match(line, "^```") then
      if in_code_fence then
        in_code_fence = false
      else
        in_code_fence = true
        block_count = block_count + 1
        -- [CONTRACT] Code blocks strictly use 'lines' array. Discard language arg.
        blocks[block_count] = { type = TOKENS.BLOCK.CODE, lines = {}, arg = nil }
      end

    -- 2. INSIDE CODE FENCE (Raw Record)
    elseif in_code_fence then
      local current_block = blocks[block_count]
      -- Safety: Ensure we are actually in a code block (parser state sync)
      if current_block and current_block.type == TOKENS.BLOCK.CODE then
        table.insert(current_block.lines, line)
      end

    -- 3. HEADER
    elseif str_match(line, "^#+%s") then
      local hashes, content = str_match(line, "^(#+)%s+(.*)")
      block_count = block_count + 1
      blocks[block_count] = { type = TOKENS.BLOCK.HEADER, text = content, arg = #hashes }
      last_line_was_blank = false

    -- 4. LIST ITEM
    elseif str_match(line, "^%-%s") then
      local content = str_match(line, "^%-%s+(.*)")
      block_count = block_count + 1
      blocks[block_count] = { type = TOKENS.BLOCK.LIST, text = content }
      last_line_was_blank = false

    -- 5. RULE
    elseif str_match(line, "^%-%-%-+$") then
      block_count = block_count + 1
      blocks[block_count] = { type = TOKENS.BLOCK.RULE }
      last_line_was_blank = false

    -- 6. BLANK LINE
    elseif str_match(line, "^%s*$") then
      last_line_was_blank = true

    -- 7. PARAGRAPH
    else
      local last_block = blocks[block_count]
      -- Merge Logic: Append to previous paragraph if contiguous
      if last_block and last_block.type == TOKENS.BLOCK.PARAGRAPH and not last_line_was_blank then
        last_block.text = last_block.text .. "\n" .. line
      else
        block_count = block_count + 1
        blocks[block_count] = { type = TOKENS.BLOCK.PARAGRAPH, text = line }
      end
      last_line_was_blank = false
    end
  end

  return blocks
end

-- -------------------------------------------------------------------------
-- PHASE 2: SPAN TOKENIZER
--   Runs on a single block’s text and returns an ordered list of spans,
--   each tagged with a style (plain, bold, italic, inline code).
--   Inline code is masked before scanning so its contents are never
--   parsed as markdown, then restored when spans are emitted.
-- -------------------------------------------------------------------------
local function parse_spans(text)
  local tokens = {}
  local token_count = 0
  
  -- A. MASKING PASS
  local mask_storage = {}
  local mask_id = 0
  local safe_text = text:gsub("(`+)(.-)%1", function(_, content)
    mask_id = mask_id + 1
    local key = MASK_PRE .. mask_id .. MASK_SUF
    mask_storage[key] = content
    return key
  end)

  -- B. SCAN PASS
  local pos = 1
  local len = #safe_text

  while pos <= len do
    local s_code = str_find(safe_text, MASK_PATT, pos)
    local s_bold = str_find(safe_text, "%*%*", pos)
    local s_ital = str_find(safe_text, "%*", pos)

    local first_idx = nil
    local mode = nil 

    if s_code then first_idx = s_code; mode = 1 end
    
    if s_bold and (not first_idx or s_bold < first_idx) then 
      first_idx = s_bold; mode = 2 
    end
    
    if s_ital and (not first_idx or s_ital < first_idx) then
       if not (s_bold and s_bold == s_ital) then
         first_idx = s_ital; mode = 3
       end
    end

    if not first_idx then
      token_count = token_count + 1
      tokens[token_count] = { text = str_sub(safe_text, pos), style = TOKENS.SPAN.NONE }
      break
    end

    if first_idx > pos then
      token_count = token_count + 1
      tokens[token_count] = { text = str_sub(safe_text, pos, first_idx - 1), style = TOKENS.SPAN.NONE }
    end

    if mode == 1 then -- CODE
      local _, e_code = str_find(safe_text, MASK_PATT, first_idx)
      local key = str_sub(safe_text, first_idx, e_code)
      token_count = token_count + 1
      tokens[token_count] = { text = mask_storage[key], style = TOKENS.SPAN.CODE }
      pos = e_code + 1

    elseif mode == 2 then -- BOLD
      local _, e_bold = str_find(safe_text, "%*%*.-%*%*", first_idx)
      if e_bold then
        token_count = token_count + 1
        tokens[token_count] = { text = str_sub(safe_text, first_idx + 2, e_bold - 2), style = TOKENS.SPAN.BOLD }
        pos = e_bold + 1
      else
        token_count = token_count + 1
        tokens[token_count] = { text = "**", style = TOKENS.SPAN.NONE }
        pos = first_idx + 2
      end

    elseif mode == 3 then -- ITALIC
      local _, e_ital = str_find(safe_text, "%*.-%*", first_idx)
      if e_ital then
        token_count = token_count + 1
        tokens[token_count] = { text = str_sub(safe_text, first_idx + 1, e_ital - 1), style = TOKENS.SPAN.ITALIC }
        pos = e_ital + 1
      else
        token_count = token_count + 1
        tokens[token_count] = { text = "*", style = TOKENS.SPAN.NONE }
        pos = first_idx + 1
      end
    end
  end

  return tokens
end

return {
  TOKENS       = TOKENS,
  parse_blocks = parse_blocks,
  parse_spans  = parse_spans
}
