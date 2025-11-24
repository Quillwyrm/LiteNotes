-- mod-version:3
-- LiteNotes: Systems-style MD Renderer
-- Pipeline: mdparse (Block AST) -> mdlayout (Display List) -> NoteReadView:draw (Pixels)

local core     = require "core"
local command  = require "core.command"
local common   = require "core.common"
local style    = require "core.style"
local system   = require "system"

local View     = require "core.view"
local DocView  = require "core.docview"
local config   = require "plugins.litenotes.config"

local parser   = require "plugins.litenotes.mdparse"
local layout   = require "plugins.litenotes.mdlayout"

-- 1. LOAD ASSETS
layout.load_assets(config)

local NoteReadView
local ProjectNoteView
local MarkdownNoteView
local NoteEditView

----------------------------------------------------------------------
-- PATHS / SETUP
----------------------------------------------------------------------

local NOTES_DIR = USERDIR .. PATHSEP .. "litenotes"

-- Ensures the LiteNotes root directory exists on disk.
-- Returns true if the directory is present or created successfully.
local function ensure_notes_dir()
  local info = system.get_file_info(NOTES_DIR)
  if info and info.type == "dir" then return true end
  local ok, err = system.mkdir(NOTES_DIR)
  if not ok then
    core.error("LiteNotes: failed to create notes dir: %s", err)
    return false
  end
  return true
end

-- Computes the file path for the current project's notes file.
-- Uses the absolute project root, sanitized into a stable filename.
local function get_project_notes_path()
  local root = core.project_dir
  if not root or root == "" then return nil end
  local abs_root = system.absolute_path(root)
  local root_id = abs_root:gsub("[^%w%-_.]", "_")
  return NOTES_DIR .. PATHSEP .. root_id .. ".md"
end

-- Opens the current project's notes document, creating an empty file
-- on first use. Returns a Doc instance or nil on failure.
local function open_or_create_notes_doc()
  if not ensure_notes_dir() then return nil end
  local notes_path = get_project_notes_path()
  if not notes_path then return nil end
  
  local info = system.get_file_info(notes_path)
  if not info then
    local fp = io.open(notes_path, "w")
    if fp then fp:close() end
  end
  return core.open_doc(notes_path)
end

----------------------------------------------------------------------
-- NAME HELPERS
----------------------------------------------------------------------

-- Builds a view title for notes, using either the project root name
-- or the backing markdown file name, prefixed with the given label.
local function build_note_title(kind, prefix, doc)
  if kind == "markdown" then
    local filename = doc and doc.filename
    local base = filename and filename:match("([^/\\]+)$") or filename
    return base and (prefix .. base) or prefix
  else
    local root = core.project_dir
    local name = (root and root ~= "") and root:match("([^/\\]+)[/\\]?$") or root
    return name and (prefix .. name) or prefix
  end
end

----------------------------------------------------------------------
-- VIEW SWAP LOGIC
----------------------------------------------------------------------

-- Replaces one view instance with another in the same node, preserving
-- size and active state. Used to flip between read/edit modes in-place.
local function replace_view(old_view, new_view)
  local root_node = core.root_view and core.root_view.root_node
  if not root_node then return end

  local node = root_node:get_node_for_view(old_view)
  if not node then return end

  local views = node.views
  local idx
  for i, v in ipairs(views) do
    if v == old_view then idx = i; break end
  end
  if not idx then return end

  new_view.size.x, new_view.size.y = old_view.size.x, old_view.size.y
  new_view.node = node
  views[idx] = new_view

  if node.active_view == old_view then
    node.active_view = new_view
    core.set_active_view(new_view)
  end
end

-- Switches from an edit view back into a read-only notes view.
-- Saves the document first, then constructs the appropriate reader.
local function enter_read_mode(editor)
  local doc = editor.doc
  if not doc then return end
  if doc:is_dirty() then doc:save() end

  local kind = editor._litenotes_kind or "project"
  local reader = (kind == "markdown") and MarkdownNoteView(doc) or ProjectNoteView(doc)
  replace_view(editor, reader)
end

-- Switches from a read-only notes view into an editable DocView wrapper.
-- Reuses the same document and preserves the LiteNotes kind flag.
local function enter_edit_mode(reader)
  local doc = reader.doc
  if not doc then return end
  local editor = NoteEditView(doc, reader._litenotes_kind)
  replace_view(reader, editor)
end

----------------------------------------------------------------------
-- EDIT VIEW (Standard DocView)
----------------------------------------------------------------------

NoteEditView = DocView:extend()

-- [SYSTEMS FIX] Removed is(DocView) override. 
-- It caused Autocomplete crashes. We use custom Status Bar items instead.

-- Constructs an edit-mode view around a notes Doc.
-- Tracks focus transitions so it can auto-return to read mode.
function NoteEditView:new(doc, kind)
  NoteEditView.super.new(self, doc)
  self._litenotes_had_focus = false
  self._litenotes_kind = kind or "project"
  self._is_litenotes = true
end

-- Updates the edit view and watches focus. Once the user leaves this
-- view after having focused it, it automatically switches back to read.
function NoteEditView:update()
  NoteEditView.super.update(self)
  local active = core.active_view
  if active == self then
    self._litenotes_had_focus = true
  elseif self._litenotes_had_focus then
    self._litenotes_had_focus = false
    enter_read_mode(self)
  end
end

-- Returns the label shown in the tab/status for the edit view,
-- prefixed with "Edit:" and based on project or file name.
function NoteEditView:get_name()
  return build_note_title(self._litenotes_kind or "project", "Edit:", self.doc)
end

----------------------------------------------------------------------
-- READ VIEW (The Renderer)
----------------------------------------------------------------------

NoteReadView = View:extend()

-- [SYSTEMS FIX] Removed is(DocView) override.

-- Constructs a read-only notes view bound to a Doc.
-- Initializes layout cache and scroll state for the renderer.
function NoteReadView:new(doc, kind)
  NoteReadView.super.new(self)
  
  -- [VACCINE] Fix corrupted session data on load
  if not self.scroll.size then self.scroll.size = { x = 0, y = 0 } end

  self.scrollable = true
  self.context    = "session"
  self._litenotes_kind = kind or "project"
  self.doc = doc
  self._is_litenotes = true
  
  self._layout_ver = 0
  self._layout_w   = 0
  self.display_list = { list = {}, width = 0, height = 0 }
end

-- Returns the label shown in the tab/status for the read view,
-- prefixed with "Note:" and based on project or file name.
function NoteReadView:get_name()
  return build_note_title(self._litenotes_kind, "Note:", self.doc)
end

-- Handles mouse presses for the read view. A left double-click
-- switches the current notes view into edit mode in-place.
function NoteReadView:on_mouse_pressed(button, x, y, clicks)
  if NoteReadView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if button == "left" and clicks >= 2 then
    enter_edit_mode(self)
    return true
  end
  return false
end

-- Ensures the markdown layout is up to date with the current document
-- contents and view width, updating the cached display list and scroll
-- size only when text or width changes.
function NoteReadView:update_layout()
  -- [VACCINE] Repair scrollbar if session restore broke it
  if not self.scroll then self.scroll = { to = {x=0,y=0} } end
  if not self.scroll.size then self.scroll.size = { x = 0, y = 0 } end

  local doc_ver = self.doc:get_change_id()
  local width   = self.size.x
  
  -- Optimization: Only re-compute if content or window width changed
  if self._layout_ver == doc_ver and self._layout_w == width then
    return
  end
  
  -- 1. PARSE (Raw Text -> Blocks)
  local raw_text = self.doc:get_text(1, 1, #self.doc.lines, #self.doc.lines[#self.doc.lines])
  local blocks = parser.parse_blocks(raw_text)
  
  -- 2. COMPUTE (Blocks -> Display List)
  self.display_list = layout.compute(blocks, width)
  
  -- 3. UPDATE SCROLLBARS (Now safe because we checked self.scroll.size above)
  self.scroll.size.y = self.display_list.height
  self.scroll.size.x = self.display_list.width
  
  -- 4. UPDATE CACHE TRACKERS
  self._layout_ver = doc_ver
  self._layout_w   = width
end

-- Draws the notes view: clears the background, applies clipping,
-- walks the display list to render text/rect commands, then draws
-- the scrollbars.
function NoteReadView:draw()
  -- [COLOR] Use Panel Background
  self:draw_background(style.background2)
  
  self:update_layout()
  
  local ox, oy = self:get_content_offset()
  local cmds = self.display_list.list
  local TYPE = layout.DRAW_MODE
  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  
  core.push_clip_rect(x, y, w, h)

  for i = 1, #cmds do
    local cmd = cmds[i]
    -- Simple Culling
    if (oy + cmd.y + 100 > 0) and (oy + cmd.y < h) then
        if cmd.type == TYPE.TEXT then
          renderer.draw_text(cmd.font, cmd.text, ox + cmd.x, oy + cmd.y, cmd.color)
        elseif cmd.type == TYPE.RECT then
          renderer.draw_rect(ox + cmd.x, oy + cmd.y, cmd.w, cmd.h, cmd.color)
        end
    end
  end
  
  core.pop_clip_rect()
  self:draw_scrollbar()
end

----------------------------------------------------------------------
-- PERSISTENCE WRAPPERS
----------------------------------------------------------------------

ProjectNoteView = NoteReadView:extend()

-- Creates a read-only view for the current project's notes document,
-- opening or creating the underlying Doc if needed.
function ProjectNoteView:new(doc)
  if not doc then doc = open_or_create_notes_doc() end
  ProjectNoteView.super.new(self, doc, "project")
end

MarkdownNoteView = NoteReadView:extend()

-- Creates a read-only view for an arbitrary markdown Doc, treating
-- it as a LiteNotes-rendered markdown page.
function MarkdownNoteView:new(doc)
  MarkdownNoteView.super.new(self, doc, "markdown")
end

----------------------------------------------------------------------
-- COMMANDS
----------------------------------------------------------------------

-- Returns true if the given view is one of the LiteNotes views.
local function is_litenotes_view(v) return v and v._is_litenotes end

-- Walks all views in the root view tree, calling the visitor for each
-- LiteNotes view. Traversal stops early if the visitor returns true.
local function walk_litenotes_views(visitor)
  local root_node = core.root_view and core.root_view.root_node
  if not root_node then return end
  local function visit(node)
    if not node then return false end
    if node.type == "leaf" then
      for _, v in ipairs(node.views) do
        if is_litenotes_view(v) and visitor(v, node) then return true end
      end
      return false
    end
    return visit(node.a) or visit(node.b)
  end
  visit(root_node)
end

-- Finds the node currently hosting a LiteNotes panel (if any)
-- and returns that node. Nil if no LiteNotes view is present.
local function find_notes_panel_node()
  local result = nil
  walk_litenotes_views(function(_, node) result = node; return true end)
  return result
end

-- Opens the given view in the dedicated notes panel. If a notes panel
-- already exists, the view is added there; otherwise a new split is
-- created in the configured dock direction.
local function open_in_notes_panel(view)
  local root_node = core.root_view.root_node
  local panel_node = find_notes_panel_node()
  
  if panel_node then
    panel_node:add_view(view)
    core.set_active_view(view)
    return
  end
  
  local active = core.root_view:get_active_node()
  local dir = config.dock_mode or "right"
  active:split(dir, view)
  core.set_active_view(view)
end

-- Opens the project-scoped notes view in the notes panel, reusing an
-- existing view when singleton mode is enabled.
local function open_project_notes_view()
  local doc = open_or_create_notes_doc()
  if not doc then return end
  
  if config.singleton_notes then
    local existing
    walk_litenotes_views(function(v) 
      if v.doc == doc then existing = v; return true end 
    end)
    if existing then core.set_active_view(existing); return end
  end

  open_in_notes_panel(ProjectNoteView(doc))
end

-- Opens an arbitrary markdown Doc inside the LiteNotes renderer,
-- placing it into the notes panel.
local function open_markdown_doc(doc)
  open_in_notes_panel(MarkdownNoteView(doc))
end

command.add(nil, {
  ["litenotes:devnotes"] = function() open_project_notes_view() end,
  
  ["litenotes:note"] = function()
    local active = core.active_view
    local doc = active and active.doc
    if doc and doc.filename and doc.filename:lower():match("%.md$") then
      open_markdown_doc(doc)
    else
      open_project_notes_view()
    end
  end,
  
  ["litenotes:note-path"] = function()
    core.command_view:enter("Open markdown path", {
      submit = function(text)
        local doc = core.open_doc(text)
        open_markdown_doc(doc)
      end,
      text = core.project_dir or "",
      select_text = true
    })
  end
})

----------------------------------------------------------------------
-- STATUS BAR INTEGRATION
----------------------------------------------------------------------
local StatusView = require "core.statusview"

if core.status_view then
  -- Left side: mode + path
  core.status_view:add_item({
    name = "litenotes:status",
    alignment = StatusView.Item.LEFT,
    position = 1,
    
    predicate = function()
      return core.active_view and core.active_view._is_litenotes
    end,

    get_item = function()
      local view = core.active_view
      local sep = "   |   "
      local sep_color = style.syntax["comment"] or style.dim
      local path = (view and view.doc and view.doc.filename) or "Untitled"

      if view:is(NoteEditView) then
        return {
          style.accent, "EDIT",
          sep_color, style.font, sep,
          style.text, path,
        }
      else
        return {
          style.text, "READ",
          sep_color, style.font, sep,
          style.text, path,
        }
      end
    end
  })

  -- Right side: plugin label
  core.status_view:add_item({
    name = "litenotes:label",
    alignment = StatusView.Item.RIGHT,
    position = 1,

    predicate = function()
      return core.active_view and core.active_view._is_litenotes
    end,

    get_item = function()
      return {
        style.dim, style.font, "LiteNotes v0.1",
      }
    end
  })
end


----------------------------------------------------------------------
-- WORKSPACE RESTORE
----------------------------------------------------------------------
package.loaded["plugins.litenotes.view"] = ProjectNoteView

