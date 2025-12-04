-- mod-version:3
-- LiteMark: MD Renderer and project notes.
-- Flow: Init -> File Check -> View Swap -> Render Pipeline

local core    = require "core"
local command = require "core.command"
local common  = require "core.common"
local style   = require "core.style"
local system  = require "system"
local View    = require "core.view"
local DocView = require "core.docview"
local StatusView = require "core.statusview" 


local config  = require "plugins.litemark.config"
local parser  = require "plugins.litemark.mdparse"
local layout  = require "plugins.litemark.mdlayout"

-- 1. LOAD ASSETS
layout.load_assets(config)

-- Forward declarations
local NoteReadView, NoteEditView
local enter_read_mode, enter_edit_mode
local get_treeview_md_file

----------------------------------------------------------------------
-- 2. FILE SYSTEM & PATHS
----------------------------------------------------------------------

local NOTES_DIR = USERDIR .. PATHSEP .. "project_notes"

local function ensure_notes_dir()
  local info = system.get_file_info(NOTES_DIR)
  if info and info.type == "dir" then return true end
  
  local ok, err = system.mkdir(NOTES_DIR)
  if not ok then
    core.error("LiteMark: failed to create dir: %s", err)
    return false
  end
  return true
end

local function get_project_notes_path()
  local root = core.project_dir
  if not root or root == "" then return nil end
  
  local abs = system.absolute_path(root)
  local id  = abs:gsub("[^%w%-_.]", "_")
  return NOTES_DIR .. PATHSEP .. id .. ".md"
end

local function open_or_create_doc()
  if not ensure_notes_dir() then return nil end
  
  local path = get_project_notes_path()
  if not path then return nil end
  
  if not system.get_file_info(path) then
    local fp = io.open(path, "w"); if fp then fp:close() end
  end
  
  return core.open_doc(path)
end

local function get_view_title(kind, prefix, doc)
  if kind == "markdown" then    
    local name = doc and doc.filename and common.basename(doc.filename) or "Untitled"
    return prefix .. name
  else
    local name = core.project_dir and common.basename(core.project_dir) or "Root"
    return prefix .. name
  end
end

----------------------------------------------------------------------
-- 3. VIEW CONTROLLER
----------------------------------------------------------------------

local function replace_view(old, new)
  local node = core.root_view.root_node:get_node_for_view(old)
  if not node then return end

  -- Manual swap required because node:replace_view() does not exist in Core.
  local views = node.views
  for i, v in ipairs(views) do
    if v == old then
      new.node = node
      new.size.x = old.size.x
      new.size.y = old.size.y
      views[i] = new
      break
    end
  end
  
  if node.active_view == old then
    node:set_active_view(new)
  end
end

function enter_read_mode(editor)
  if editor.doc:is_dirty() then editor.doc:save() end
  -- Scroll logic removed
  replace_view(editor, NoteReadView(editor.doc, editor._litemark_kind))
end

function enter_edit_mode(reader)
  -- Scroll logic removed
  replace_view(reader, NoteEditView(reader.doc, reader._litemark_kind))
end

----------------------------------------------------------------------
-- 4. VIEW CLASSES
----------------------------------------------------------------------

-- [EDIT VIEW] Wrapper around standard DocView
NoteEditView = DocView:extend()

function NoteEditView:new(doc, kind)
  NoteEditView.super.new(self, doc)
  self._litemark_kind = kind or "project"
  self._is_litemark = true
  self._had_focus = false
end

function NoteEditView:get_name()
  return get_view_title(self._litemark_kind, "Edit:", self.doc)
end

function NoteEditView:update()
  NoteEditView.super.update(self)
  if core.active_view == self then
    self._had_focus = true
  elseif self._had_focus then
    self._had_focus = false
    enter_read_mode(self)
  end
end


-- [READ VIEW] Custom Renderer
NoteReadView = View:extend()

function NoteReadView:new(doc, kind)
  NoteReadView.super.new(self)
  self.doc = doc
  self._litemark_kind = kind or "project"
  self._is_litemark = true
  self.scrollable = true
  
  self.display_list = { list = {}, width = 0, height = 0 }
  self._layout_ver = 0
  self._layout_w   = 0
  self._layout_bg  = nil -- For Theme Invalidation
end

function NoteReadView:get_name()
  return get_view_title(self._litemark_kind, "Note:", self.doc)
end

-- Hook for LiteXL Core to determine vertical scroll limit
function NoteReadView:get_scrollable_size()
  return self.display_list.height
end

-- Hook for LiteXL Core to determine horizontal scroll limit
function NoteReadView:get_h_scrollable_size()
  return self.display_list.width
end

function NoteReadView:on_mouse_pressed(btn, x, y, clicks)
  -- 1. Standard Event Bubble (Scrollbar, Double Click)
  if NoteReadView.super.on_mouse_pressed(self, btn, x, y, clicks) then return true end
  
  -- Double click to edit (after super handles scrollbar click)
  if btn == "left" and clicks == 2 then
    enter_edit_mode(self)
    return true
  end
  return false
end

function NoteReadView:update_layout()
  local ver = self.doc:get_change_id()
  
    -- Explicitly reserve space for the scrollbar gutter
  local gutter = style.scrollbar_size or 0
  local w = self.size.x - gutter
  
  -- Theme Invalidation Check
  local theme_changed = (self._layout_bg ~= style.background2)
  if self._layout_ver == ver and self._layout_w == w and not theme_changed then return end

  if theme_changed then
    layout.load_assets(config)
    self._layout_bg = style.background2
  end
  
  local text = self.doc:get_text(1, 1, #self.doc.lines, #self.doc.lines[#self.doc.lines])
  local blocks = parser.parse_blocks(text, self.block_rules)
  
  -- Pass the reduced width to the layout engine
  self.display_list = layout.compute(blocks, w, { span_rules = self.span_rules })
  
  self._layout_ver = ver
  self._layout_w   = w
end

function NoteReadView:draw()
  self:draw_background(style.background2)
  self:update_layout()
  
  -- Empty State Hint
  if #self.display_list.list == 0 then
    local text = "Double-click to edit"
    local font = style.font
    local tw = font:get_width(text)
    local th = font:get_height()
    
    local x = math.floor(self.position.x + (self.size.x - tw) / 2)
    local y = math.floor(self.position.y + (self.size.y - th) / 2)
    
    renderer.draw_text(font, text, x, y, style.dim)
  end

  -- Render Content
  local ox, oy = self:get_content_offset()
  local cmds = self.display_list.list
  local TYPE = layout.DRAW_MODE
  
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  
  -- Culling logic with safety buffer
  local min_y = -oy - 100            -- Top of screen (minus buffer)
  local max_y = -oy + self.size.y + 100 -- Bottom of screen (plus buffer)

  for i = 1, #cmds do
    local cmd = cmds[i]

    -- OPTIMIZATION 1: Stop if we passed the bottom (KEPT)
    if cmd.y > max_y then break end

    -- OPTIMIZATION 2: Intersection Check (KEPT)
    local cmd_h = cmd.h or cmd.font:get_height()
    
    if (cmd.y + cmd_h > min_y) then
      if cmd.type == TYPE.TEXT then
        renderer.draw_text(cmd.font, cmd.text, ox + cmd.x, oy + cmd.y, cmd.color)
      elseif cmd.type == TYPE.RECT then
        renderer.draw_rect(ox + cmd.x, oy + cmd.y, cmd.w, cmd.h, cmd.color)
      elseif cmd.type == TYPE.CANVAS then
        renderer.draw_canvas(cmd.canvas, ox + cmd.x, oy + cmd.y)
      end
    end
  end
  
  core.pop_clip_rect()
  
  -- Active View Hilight 
  if core.active_view == self then
    local border_w     = 2
    local border_color = style.syntax["keyword"]

    renderer.draw_rect(self.position.x,                    self.position.y,                      self.size.x,                 border_w, border_color) -- Top
    renderer.draw_rect(self.position.x,                    self.position.y + self.size.y - border_w, self.size.x,             border_w, border_color) -- Bottom
    renderer.draw_rect(self.position.x,                    self.position.y,                      border_w,                   self.size.y, border_color) -- Left
    renderer.draw_rect(self.position.x + self.size.x - border_w, self.position.y,                border_w,                   self.size.y, border_color) -- Right
  end



  -- Draw Scrollbar last to overlay content
  self:draw_scrollbar()


end

----------------------------------------------------------------------
-- 5. WIRING
----------------------------------------------------------------------

local function is_litemark(v) return v and v._is_litemark end

local function walk_views(visitor)
  local node = core.root_view.root_node
  local function rec(n)
    if n.type == "leaf" then
      for _, v in ipairs(n.views) do if visitor(v) then return true end end
    elseif n.a then
      if rec(n.a) then return true end
      if rec(n.b) then return true end
    end
    return false
  end
  rec(node)
end

local function open_in_panel(view)
  local panel_node
  walk_views(function(v) 
    if is_litemark(v) then 
      panel_node = core.root_view.root_node:get_node_for_view(v)
      return true 
    end 
  end)

  if panel_node then
    panel_node:add_view(view)
    core.set_active_view(view)
  else
    local active = core.root_view:get_active_node()
    active:split(config.dock_mode or "right", view)
    core.set_active_view(view)
  end
end


----------------------------------------------------------------------
-- 6. COMMANDS
----------------------------------------------------------------------

command.add(nil, {
  ["litemark:view project notes"] = function()
    local doc = open_or_create_doc()
    if not doc then return end

    if config.singleton_notes then
      local found = false
      walk_views(function(v)
        if v.doc == doc and is_litemark(v) then
          core.set_active_view(v)
          found = true
          return true
        end
      end)
      if found then return end
    end

    open_in_panel(NoteReadView(doc, "project"))
  end,

  ["litemark:view current markdown"] = function()
    local active = core.active_view
    if not active or not active.doc then return end

    local filename = active.doc.filename
    if filename and filename:match("%.md$") then
      open_in_panel(NoteReadView(active.doc, "markdown"))
    else
      core.error("LiteMark: current file is not a Markdown document")
    end
  end,

})

----------------------------------------------------------------------
-- 7. STATUS BAR
----------------------------------------------------------------------

if core.status_view then
  -- Left side: path only
  core.status_view:add_item({
    name = "litemark:status-path",
    alignment = StatusView.Item.LEFT,
    position = 1,
    
    predicate = function()
      return core.active_view and core.active_view._is_litemark
    end,

    get_item = function()
      local view = core.active_view
      local path = (view and view.doc and view.doc.filename) or "Untitled"
      return {
        style.text, path,
      }
    end
  })

  -- Right side: READ / EDIT mode tag
  core.status_view:add_item({
    name = "litemark:status-mode",
    alignment = StatusView.Item.RIGHT,
    position = 1,

    predicate = function()
      return core.active_view and core.active_view._is_litemark
    end,

    get_item = function()
      local view = core.active_view
      local mode_text, mode_color

      if view and view:is(NoteEditView) then
        mode_text  = "EDIT"
        mode_color = style.syntax["string"]
      else
        mode_text  = "READ"
        mode_color = style.accent
      end

      return {
        mode_color, mode_text,
      }
    end
  })
end



----------------------------------------------------------------------
-- 8. CONTEXT MENU INTEGRATION
----------------------------------------------------------------------

local contextmenu = require "plugins.contextmenu"

-- DocView .md: right-click in a markdown doc view.
contextmenu:register(function()
  local view = core.active_view
  return view
    and view:is(DocView)
    and view.doc
    and view.doc.filename
    and view.doc.filename:match("%.md$")
end, {
  { text = "View Markdown", command = "litemark:view current markdown" }
})

return {
  NoteReadView = NoteReadView,
  NoteEditView = NoteEditView,
  layout = layout,
  config = config,
  parser = parser
}
