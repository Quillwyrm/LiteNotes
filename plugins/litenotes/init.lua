-- mod-version:3
-- LiteNotes: per-project notes only
-- - Stores notes under USERDIR/litenotes/
-- - One notes file per project root (core.project_dir)
-- - NoteReader: read mode (custom View, non-editable)
-- - NoteEditor: edit mode (DocView), entered via double-click

local core    = require "core"
local command = require "core.command"
local common  = require "core.common"
local style   = require "core.style"
local system  = require "system"

local View    = require "core.view"
local DocView = require "core.docview"  -- used as NoteEditor

-- Semantic alias; keeps the naming aligned with how we talk about it.
local NoteEditor = DocView
local NoteReader -- forward declaration so helpers can see it

----------------------------------------------------------------------
-- PATHS / SETUP
----------------------------------------------------------------------

-- USERDIR and PATHSEP are globals provided by Lite XL.
local NOTES_DIR = USERDIR .. PATHSEP .. "litenotes"

-- Make sure USERDIR/litenotes exists.
local function ensure_notes_dir()
  local info, err = system.get_file_info(NOTES_DIR)
  if not info or info.type ~= "dir" then
    local ok, mkerr = system.mkdir(NOTES_DIR)
    if not ok then
      core.error("LiteNotes: failed to create notes dir '%s': %s", NOTES_DIR, mkerr or "?")
      return false
    end
    core.log("LiteNotes: created notes dir at %s", NOTES_DIR)
  end
  return true
end

-- Compute the notes file path for the current project.
-- If there is no project dir, we return nil and refuse to open notes.
local function get_project_notes_path()
  local root = core.project_dir
  if not root or root == "" then
    return nil
  end

  local abs_root = system.absolute_path(root)

  -- Turn the absolute path into a safe filename:
  -- replace anything not [A-Za-z0-9_.-] with "_".
  local root_id = abs_root:gsub("[^%w%-_.]", "_")

  return NOTES_DIR .. PATHSEP .. root_id .. ".md"
end

----------------------------------------------------------------------
-- NOTE VIEW SWAP HELPERS (Reader <-> Editor in the same node)
----------------------------------------------------------------------

-- Replace the current LiteNotes view (reader/editor) with another
-- view instance in the same node.
local function replace_view(old_view, new_view)
  -- Resolve layout from the view itself so we cooperate with other
  -- plugins that move/split/dock views.
  local root_view = core.root_view
  local root_node = root_view and root_view.root_node
  if not root_node then
    core.error("LiteNotes: root view not ready for view swap")
    return
  end

  -- Preferred: find the node that actually contains old_view.
  local node = root_node:get_node_for_view(old_view)

  -- If old_view is no longer attached (closed or moved in a way we
  -- don't track), fall back to the active node as a best effort.
  if not node then
    node = root_view:get_active_node()
  end

  if not node then
    core.error("LiteNotes: no node available for view swap")
    return
  end

  node:add_view(new_view)
  -- Use close_view so the node can clean up if needed.
  node:close_view(root_node, old_view)
  core.set_active_view(new_view)
end

-- Swap NoteReader -> NoteEditor (DocView) in-place in the same node.
local function enter_edit_mode(reader)
  local doc = reader.doc
  if not doc then return end
  local editor = NoteEditor(doc)
  replace_view(reader, editor)
end

-- Swap NoteEditor (DocView) -> NoteReader in-place, but only if it's
-- actually the current project's notes file.
-- Also auto-saves the doc if it has unsaved changes.
local function enter_read_mode(editor)
  local doc = editor.doc
  if not doc then return end

  local notes_path = get_project_notes_path()
  if not notes_path or doc.filename ~= notes_path then
    -- Not a LiteNotes doc; ignore.
    return
  end

  -- Auto-save when leaving edit mode: if the doc is dirty, write it to disk.
  if doc:is_dirty() then
    doc:save()
  end

  local reader = NoteReader(doc)
  replace_view(editor, reader)
end

----------------------------------------------------------------------
-- NOTE READER (READ-ONLY MODE)
----------------------------------------------------------------------

-- NoteReader shows the contents of a Doc (per-project notes file) as static text.
NoteReader = View:extend()

function NoteReader:new(doc)
  NoteReader.super.new(self)
  self.scrollable = true           -- allow scrolling for long notes (simple, no bar)
  self.context    = "session"      -- closed by normal close-all
  self.doc        = doc            -- core.doc for the notes file
end

function NoteReader:get_name()
  return "LiteNotes"
end

function NoteReader:on_mouse_pressed(button, x, y, clicks)
  -- Let base View handle scrollbars, focus, etc.
  if NoteReader.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end

  -- Double-click anywhere in the NoteReader -> enter edit mode (NoteEditor).
  if button == "left" and clicks >= 2 then
    enter_edit_mode(self)
    return true
  end

  return false
end

function NoteReader:draw()
  self:draw_background(style.background)

  local x, y = self:get_content_offset()
  local w, h = self.size.x, self.size.y

  local doc = self.doc
  if not doc then
    common.draw_text(style.font, style.text, "No document loaded.", "center", x, y, w, h)
    return
  end

  local line_h = style.font:get_height()
  local cy     = y

  for _, line in ipairs(doc.lines) do
    if cy + line_h > y + h then
      break
    end
    common.draw_text(style.font, style.text, line, "left", x + 8, cy, w - 16, line_h)
    cy = cy + line_h
  end
end

----------------------------------------------------------------------
-- COMMANDS
----------------------------------------------------------------------

-- LiteNotes: read notes
-- - If active view is on this project's notes doc -> switch to NoteReader (auto-saving if dirty).
-- - Otherwise -> ensure notes file exists and open NoteReader in the active node.
command.add(nil, {
  ["litenotes:read-notes"] = function()
    -- Make sure the notes dir exists.
    if not ensure_notes_dir() then
      return
    end

    -- Resolve the project notes path.
    local notes_path = get_project_notes_path()
    if not notes_path then
      core.error("LiteNotes: cannot determine project directory.")
      return
    end

    -- If we're already on the project's notes doc (editor or reader),
    -- normalize to read mode (which will auto-save if needed).
    local active = core.active_view
    if active and active.doc and active.doc.filename == notes_path then
      -- Already in NoteReader for this doc? Nothing to do.
      if active.is and active:is(NoteReader) then
        return
      end
      enter_read_mode(active)
      return
    end

    -- Otherwise, ensure the file exists on disk.
    local info = system.get_file_info(notes_path)
    if not info then
      local fp, err = io.open(notes_path, "w")
      if not fp then
        core.error("LiteNotes: failed to create notes file '%s': %s", notes_path, err or "?")
        return
      end
      fp:close()
      core.log("LiteNotes: created new notes file at %s", notes_path)
    end

    -- Open the doc and show it in NoteReader.
    local doc  = core.open_doc(notes_path)
    local view = NoteReader(doc)

    local node = core.root_view:get_active_node()
    if not node then
      core.error("LiteNotes: no active node to open notes")
      return
    end

    node:add_view(view)
    core.set_active_view(view)

    core.log("LiteNotes: opened project notes at %s", notes_path)
  end
})

