-- mod-version:3
-- LiteNotes: per-project notes + markdown viewer
-- - Project notes: one .md per project under USERDIR/litenotes/
-- - Markdown viewer: read-only/Edit views for arbitrary .md files
-- - Project-note views persist via workspace; markdown views are ephemeral

local core     = require "core"
local command  = require "core.command"
local common   = require "core.common"
local style    = require "core.style"
local system   = require "system"

local View     = require "core.view"
local DocView  = require "core.docview"
local config   = require "plugins.litenotes.config"

local NoteReadView
local ProjectNoteView
local MarkdownNoteView
local NoteEditView

----------------------------------------------------------------------
-- PATHS / SETUP
----------------------------------------------------------------------

local NOTES_DIR = USERDIR .. PATHSEP .. "litenotes"

-- ensure_notes_dir() - Make sure USERDIR/litenotes exists.
local function ensure_notes_dir()
  local info = system.get_file_info(NOTES_DIR)
  if info and info.type == "dir" then
    return true
  end

  local ok, err = system.mkdir(NOTES_DIR)
  if not ok then
    core.error("LiteNotes: failed to create notes dir '%s': %s", NOTES_DIR, err or "?")
    return false
  end

  core.log("LiteNotes: created notes dir at %s", NOTES_DIR)
  return true
end

-- get_project_notes_path() - Return absolute path for this project's notes file.
-- Uses absolute project dir, sanitized into a filename under NOTES_DIR.
local function get_project_notes_path()
  local root = core.project_dir
  if not root or root == "" then
    return nil
  end

  local abs_root = system.absolute_path(root)
  local root_id = abs_root:gsub("[^%w%-_.]", "_")
  return NOTES_DIR .. PATHSEP .. root_id .. ".md"
end

-- open_or_create_notes_doc() - Ensure project notes file exists and open it as a Doc.
local function open_or_create_notes_doc()
  if not ensure_notes_dir() then
    return nil
  end

  local notes_path = get_project_notes_path()
  if not notes_path then
    core.error("LiteNotes: cannot determine project directory.")
    return nil
  end

  local info = system.get_file_info(notes_path)
  if not info then
    local fp, err = io.open(notes_path, "w")
    if not fp then
      core.error("LiteNotes: failed to create notes file '%s': %s", notes_path, err or "?")
      return nil
    end
    fp:close()
    core.log("LiteNotes: created new notes file at %s", notes_path)
  end

  return core.open_doc(notes_path)
end

----------------------------------------------------------------------
-- FONTS
-- Read-mode fonts (NoteEditView uses normal DocView fonts).
----------------------------------------------------------------------

local NoteFontRegular = renderer.font.load(config.fonts.regular, config.fonts.size)
local NoteFontBold    = renderer.font.load(config.fonts.bold,    config.fonts.size)
local NoteFontItalic  = renderer.font.load(config.fonts.italic,  config.fonts.size)

----------------------------------------------------------------------
-- NAME HELPERS
-- Small helpers for tab titles.
----------------------------------------------------------------------

-- get_project_root_name() - Last component of core.project_dir, for project note titles.
local function get_project_root_name()
  local root = core.project_dir
  if root and root ~= "" then
    local name = root:match("([^/\\]+)[/\\]?$") or root
    return name
  end
  return nil
end

-- get_doc_basename(doc) - Basename of doc.filename, for markdown titles.
local function get_doc_basename(doc)
  local filename = doc and doc.filename
  if not filename then
    return nil
  end
  local base = filename:match("([^/\\]+)$") or filename
  return base
end

-- build_note_title(kind, prefix, doc) - Common logic for Note*/Edit* tab titles.
-- kind:   "project" | "markdown"
-- prefix: "Note:"   | "Edit:"
local function build_note_title(kind, prefix, doc)
  if kind == "markdown" then
    local base = get_doc_basename(doc)
    if base then
      return prefix .. base
    end
  else
    local name = get_project_root_name()
    if name then
      return prefix .. name
    end
  end
  return prefix
end

----------------------------------------------------------------------
-- VIEW SWAP HELPERS
-- Swaps between NoteReadView <-> NoteEditView without changing tab order.
----------------------------------------------------------------------

-- replace_view(old_view, new_view) - In-place swap of views in the same node/slot.
local function replace_view(old_view, new_view)
  local root_node = core.root_view and core.root_view.root_node
  if not root_node then
    core.error("LiteNotes: root view not ready for view swap")
    return
  end

  local node = root_node:get_node_for_view(old_view)
  if not node then
    return -- nothing sane to do; just bail
  end

  local views = node.views
  local idx
  for i, v in ipairs(views) do
    if v == old_view then
      idx = i
      break
    end
  end
  if not idx then
    return
  end

  new_view.size.x, new_view.size.y = old_view.size.x, old_view.size.y
  new_view.node = node

  views[idx] = new_view

  if node.active_view == old_view then
    node.active_view = new_view
    core.set_active_view(new_view)
  end
end

-- enter_read_mode(editor) - From NoteEditView → appropriate NoteReadView (project/markdown).
local function enter_read_mode(editor)
  local doc = editor.doc
  if not doc then
    return
  end

  if doc:is_dirty() then
    doc:save()
  end

  local kind = editor._litenotes_kind or "project"
  local reader
  if kind == "markdown" then
    reader = MarkdownNoteView(doc)
  else
    reader = ProjectNoteView(doc)
  end

  replace_view(editor, reader)
end

-- enter_edit_mode(reader) - From NoteReadView → NoteEditView, remembering kind.
local function enter_edit_mode(reader)
  local doc = reader.doc
  if not doc then
    return
  end

  local kind = reader._litenotes_kind or "project"
  local editor = NoteEditView(doc, kind)
  replace_view(reader, editor)
end

----------------------------------------------------------------------
-- EDIT VIEW
-- Editable note view, snaps back to read-mode on focus loss.
----------------------------------------------------------------------

NoteEditView = DocView:extend()

-- NoteEditView:new(doc, kind) - Create edit view for a given doc and kind ("project"/"markdown").
function NoteEditView:new(doc, kind)
  NoteEditView.super.new(self, doc)
  self._litenotes_had_focus = false
  self._litenotes_kind = kind or "project"
  self._is_litenotes = true
end

-- NoteEditView:update() - Track focus; on blur, save and return to read-mode.
function NoteEditView:update()
  NoteEditView.super.update(self)

  local active = core.active_view
  if active == self then
    self._litenotes_had_focus = true
  elseif self._litenotes_had_focus then
    self._litenotes_had_focus = false
    enter_read_mode(self)
    return
  end
end

-- NoteEditView:get_name() - Tab title for edit mode.
-- Project:  "Edit:<projectdir>"
-- Markdown: "Edit:<filename>"
function NoteEditView:get_name()
  local kind = self._litenotes_kind or "project"
  return build_note_title(kind, "Edit:", self.doc)
end

----------------------------------------------------------------------
-- NOTE READ VIEW BASE
-- Shared read-only note view; specialized by kind.
----------------------------------------------------------------------

NoteReadView = View:extend()

-- NoteReadView:new(doc, kind) - Base reader for notes ("project" or "markdown").
function NoteReadView:new(doc, kind)
  NoteReadView.super.new(self)
  self.scrollable = true
  self.context    = "session"
  self.layout     = nil       -- future markdown layout cache hook
  self._litenotes_kind = kind or "project"
  self.doc = doc
  self._is_litenotes = true
end

-- NoteReadView:get_name() - Tab title for read mode.
-- Project:  "Note:<projectdir>"
-- Markdown: "Note:<filename>"
function NoteReadView:get_name()
  local kind = self._litenotes_kind or "project"
  return build_note_title(kind, "Note:", self.doc)
end

-- NoteReadView:on_mouse_pressed() - Double-click to enter edit mode.
function NoteReadView:on_mouse_pressed(button, x, y, clicks)
  if NoteReadView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end

  if button == "left" and clicks >= 2 then
    enter_edit_mode(self)
    return true
  end

  return false
end

-- NoteReadView:draw_plain_text() - Simple line-by-line text rendering (placeholder for markdown layout).
function NoteReadView:draw_plain_text(doc, x, y, w, h)
  local font   = NoteFontRegular
  local line_h = font:get_height()
  local cy     = y

  for _, line in ipairs(doc.lines) do
    if cy + line_h > y + h then
      break
    end
    common.draw_text(font, style.text, line, "left", x + 8, cy, w - 16, line_h)
    cy = cy + line_h
  end
end

-- NoteReadView:draw() - Background + note content.
function NoteReadView:draw()
  self:draw_background(style.background)

  local x, y = self:get_content_offset()
  local w, h = self.size.x, self.size.y
  local doc  = self.doc

  if not doc then
    return
  end

  self:draw_plain_text(doc, x, y, w, h)
end

----------------------------------------------------------------------
-- PROJECT NOTE VIEW (PERSISTED)
-- ProjectNoteView: persisted "project" flavor of NoteReadView.
----------------------------------------------------------------------

ProjectNoteView = NoteReadView:extend()

-- ProjectNoteView:new(doc) - Reader for per-project notes; creates doc if needed.
function ProjectNoteView:new(doc)
  if not doc then
    doc = open_or_create_notes_doc()
  end
  ProjectNoteView.super.new(self, doc, "project")
end

----------------------------------------------------------------------
-- MARKDOWN NOTE VIEW (EPHEMERAL)
-- MarkdownNoteView: ephemeral "markdown" flavor of NoteReadView.
----------------------------------------------------------------------

MarkdownNoteView = NoteReadView:extend()

-- MarkdownNoteView:new(doc) - Reader for arbitrary .md docs (does not persist via workspace).
function MarkdownNoteView:new(doc)
  MarkdownNoteView.super.new(self, doc, "markdown")
end

----------------------------------------------------------------------
-- LAYOUT HELPERS
--  - First LiteNotes view creates a dedicated panel (split).
--  - All later views tab into that panel node.
----------------------------------------------------------------------

-- is_litenotes_view(v) - Check if view is any LiteNotes view (reader or editor).
local function is_litenotes_view(v)
  return v and v._is_litenotes
end

-- walk_litenotes_views(visitor) - Iterate all LiteNotes views; visitor(view, node) can return true to stop.
local function walk_litenotes_views(visitor)
  local root_node = core.root_view and core.root_view.root_node
  if not root_node then
    return
  end

  local function visit(node)
    if not node then
      return false
    end
    if node.type == "leaf" then
      for _, v in ipairs(node.views) do
        if is_litenotes_view(v) and visitor(v, node) then
          return true
        end
      end
      return false
    end
    return visit(node.a) or visit(node.b)
  end

  visit(root_node)
end

-- find_existing_notes_view(doc) - Find any LiteNotes view bound to this doc.
local function find_existing_notes_view(doc)
  if not doc then
    return nil
  end

  local result = nil
  walk_litenotes_views(function(v)
    if v.doc == doc then
      result = v
      return true -- stop walk
    end
  end)

  return result
end

-- find_notes_panel_node() - Find the node that currently acts as the LiteNotes panel.
local function find_notes_panel_node()
  local result = nil
  walk_litenotes_views(function(_, node)
    result = node
    return true -- first node with a LiteNotes view wins
  end)
  return result
end

-- get_split_direction() - Map plugin config.dock_mode to node split direction.
local split_direction_map = {
  left   = "left",
  right  = "right",
  top    = "up",
  bottom = "down",
}

local function get_split_direction()
  return split_direction_map[config.dock_mode] or "right"
end

-- open_in_notes_panel(view) - Place view into the LiteNotes panel (create it if needed).
local function open_in_notes_panel(view)
  local root_view = core.root_view
  local root_node = root_view and root_view.root_node
  if not root_node then
    core.error("LiteNotes: root view not ready to open view")
    return
  end

  local panel_node = find_notes_panel_node()
  if panel_node then
    panel_node:add_view(view)
    core.set_active_view(view)
    return
  end

  local active_node = root_view:get_active_node()
  if not active_node then
    core.error("LiteNotes: no active node to open view")
    return
  end

  local dir = get_split_direction()
  active_node:split(dir, view)
  core.set_active_view(view)
end

----------------------------------------------------------------------
-- NOTE OPEN HELPERS
-- Shared helpers used by commands for markdown vs project behaviour.
----------------------------------------------------------------------

-- open_project_notes_view() - Open/focus the per-project notes view in the panel.
local function open_project_notes_view()
  local doc = open_or_create_notes_doc()
  if not doc then
    return
  end

  if config.singleton_notes then
    local existing = find_existing_notes_view(doc)
    if existing then
      core.set_active_view(existing)
      core.log("LiteNotes: notes view already open")
      return
    end
  end

  local view = ProjectNoteView(doc)
  open_in_notes_panel(view)
end

-- open_markdown_doc(doc) - Open a markdown Doc as a Note in the panel.
local function open_markdown_doc(doc)
  if not doc then
    core.error("LiteNotes: no document to open as markdown")
    return
  end

  local filename = doc.filename
  if not filename then
    core.error("LiteNotes: document is not a saved .md file")
    return
  end

  if not filename:lower():match("%.md$") then
    core.error("LiteNotes: only .md files can be opened in markdown view")
    return
  end

  local view = MarkdownNoteView(doc)
  open_in_notes_panel(view)
end

----------------------------------------------------------------------
-- COMMANDS
----------------------------------------------------------------------

command.add(nil, {

  -- litenotes:open-notes - Always open/focus the per-project notes view in the LiteNotes panel.
  ["litenotes:devnotes"] = function()
    open_project_notes_view()
  end,

  -- litenotes:note-here - Context-aware Note:
  -- If active view has a saved .md, open that as a Note in the panel.
  -- Otherwise, open/focus project notes.
  ["litenotes:note"] = function()
    local active = core.active_view
    local doc    = active and active.doc

    if doc and doc.filename and doc.filename:lower():match("%.md$") then
      open_markdown_doc(doc)
    else
      open_project_notes_view()
    end
  end,

  -- litenotes:open-markdown-path - Prompt for a .md path and open it as a Note in the panel.
  -- (Primarily for future context-menu / scripted use.)
  ["litenotes:note-path"] = function()
    core.command_view:enter("Open markdown path", {
      submit = function(text)
        if not text or text == "" then
          return
        end

        if not text:lower():match("%.md$") then
          core.error("LiteNotes: only .md files can be opened in markdown view")
          return
        end

        local doc = core.open_doc(text)
        open_markdown_doc(doc)
      end,
      text = core.project_dir or "",
      select_text = true,
    })
  end,
})

----------------------------------------------------------------------
-- WORKSPACE RESTORE
----------------------------------------------------------------------
-- Only the project-note view is registered for workspace persistence.
-- MarkdownNoteView instances are never serialized and thus ephemeral.
package.loaded["plugins.litenotes.view"] = ProjectNoteView

