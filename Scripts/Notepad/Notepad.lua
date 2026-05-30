-- @description Notepad
-- @version 1.1.1
-- @author KRGSH
-- @provides
--   [main] Notepad - Install toolbar.lua
--   [data] ../../Data/toolbar_icons/notepad.svg
-- @about
--   Dockable dark-mode Markdown notepad for REAPER projects. Notes are saved
--   into the project via ProjExtState.

local SECTION = "KRGSH_NOTEPAD"
local WINDOW_TITLE = "Notepad"
local DEFAULT_NOTE_TITLE = "Project Notes"
local DEFAULT_NOTE_BODY = "# Project Notes\n\n"
local NOTE_PREFIX = "note:"
local WIDTH = 980
local HEIGHT = 620
local SIDEBAR_WIDTH = 220
local AUTOSAVE_INTERVAL = 0.75
local DEFAULT_FONT_SIZE = 14
local MIN_FONT_SIZE = 10
local MAX_FONT_SIZE = 28

local notes = {}
local active_id = ""
local next_id = 1
local dirty = false
local last_save_at = 0
local title_buffer = ""
local body_buffer = ""
local last_dock_id = 0
local view_mode = "edit"
local note_browser_open = true
local font_size = DEFAULT_FONT_SIZE

local function esc(value)
  value = tostring(value or "")
  value = value:gsub("%%", "%%25")
  value = value:gsub("|", "%%7C")
  value = value:gsub("\n", "%%0A")
  return value
end

local function unesc(value)
  value = tostring(value or "")
  value = value:gsub("%%0A", "\n")
  value = value:gsub("%%7C", "|")
  value = value:gsub("%%25", "%%")
  return value
end

local function trim(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$")
end

local function normalized_title(value)
  value = trim(value)
  if value == "" then
    return "Untitled"
  end
  return value:gsub("[\r\n]+", " ")
end

local function clamp(value, lo, hi)
  value = tonumber(value) or lo
  if value < lo then return lo end
  if value > hi then return hi end
  return value
end

local function normalize_view_mode(value)
  value = tostring(value or "")
  if value == "preview" then
    return "preview"
  end
  return "edit"
end

local function normalize_bool(value, fallback)
  value = tostring(value or "")
  if value == "1" or value == "true" then return true end
  if value == "0" or value == "false" then return false end
  return fallback
end

local function note_index_by_id(id)
  for index, note in ipairs(notes) do
    if note.id == id then
      return index
    end
  end
  return nil
end

local function active_note()
  return notes[note_index_by_id(active_id) or 1]
end

local function sync_buffers_from_active()
  local note = active_note()
  if note then
    title_buffer = note.title
    body_buffer = note.body
  else
    title_buffer = ""
    body_buffer = ""
  end
end

local function make_note(title, body)
  local note = {
    id = tostring(next_id),
    title = normalized_title(title or DEFAULT_NOTE_TITLE),
    body = tostring(body or ""),
  }
  next_id = next_id + 1
  return note
end

local function ensure_default_note()
  if #notes == 0 then
    notes[1] = make_note(DEFAULT_NOTE_TITLE, DEFAULT_NOTE_BODY)
  end
  if not note_index_by_id(active_id) then
    active_id = notes[1].id
  end
  sync_buffers_from_active()
end

local function encode_note_list()
  local fields = {}
  for _, note in ipairs(notes) do
    fields[#fields + 1] = table.concat({ esc(note.id), esc(note.title) }, "|")
  end
  return table.concat(fields, "\n")
end

local function decode_note_list(value)
  notes = {}
  next_id = 1
  for line in tostring(value or ""):gmatch("[^\n]+") do
    local id, title = line:match("^(.-)|(.*)$")
    id = unesc(id or "")
    if id ~= "" then
      notes[#notes + 1] = {
        id = id,
        title = normalized_title(unesc(title or "")),
        body = "",
      }
      local number_id = tonumber(id)
      if number_id and number_id >= next_id then
        next_id = math.floor(number_id) + 1
      end
    end
  end
end

local function serialize_notes()
  local bodies = {}
  for _, note in ipairs(notes) do
    bodies[note.id] = note.body
  end
  return {
    list = encode_note_list(),
    bodies = bodies,
    active_id = active_id,
    next_id = tostring(next_id),
  }
end

local function load_state_from_table(state)
  state = state or {}
  decode_note_list(state.list or "")
  for _, note in ipairs(notes) do
    note.body = tostring((state.bodies and state.bodies[note.id]) or "")
  end
  active_id = tostring(state.active_id or "")
  next_id = tonumber(state.next_id) or next_id
  ensure_default_note()
  return serialize_notes()
end

local function add_note(title, body)
  local note = make_note(title or ("Note " .. tostring(#notes + 1)), body or "")
  notes[#notes + 1] = note
  active_id = note.id
  sync_buffers_from_active()
  dirty = true
  return note
end

local function duplicate_active_note()
  local note = active_note()
  if not note then return nil end
  return add_note(note.title .. " Copy", note.body)
end

local function delete_note(id)
  if #notes <= 1 then
    local note = active_note()
    if note then
      note.title = DEFAULT_NOTE_TITLE
      note.body = DEFAULT_NOTE_BODY
      active_id = note.id
      sync_buffers_from_active()
      dirty = true
    end
    return false
  end

  local index = note_index_by_id(id or active_id)
  if not index then return false end
  table.remove(notes, index)
  if active_id == id or not note_index_by_id(active_id) then
    local next_note = notes[math.min(index, #notes)] or notes[1]
    active_id = next_note and next_note.id or ""
  end
  sync_buffers_from_active()
  dirty = true
  return true
end

local function select_note(id)
  if id ~= active_id and note_index_by_id(id) then
    active_id = id
    sync_buffers_from_active()
    dirty = true
  end
end

local function apply_buffers_to_active()
  local note = active_note()
  if not note then return end
  local title = normalized_title(title_buffer)
  local body = tostring(body_buffer or "")
  if note.title ~= title or note.body ~= body then
    note.title = title
    note.body = body
    dirty = true
  end
end

local function ext_get(key)
  local ok, value = reaper.GetProjExtState(0, SECTION, key)
  if ok == 1 then return value end
  return ""
end

local function ext_set(key, value)
  reaper.SetProjExtState(0, SECTION, key, tostring(value or ""))
end

local function load_project_state()
  decode_note_list(ext_get("notes"))
  for _, note in ipairs(notes) do
    note.body = ext_get(NOTE_PREFIX .. note.id)
  end
  active_id = ext_get("active_id")
  next_id = tonumber(ext_get("next_id")) or next_id
  last_dock_id = tonumber(ext_get("dock_id")) or 0
  view_mode = normalize_view_mode(ext_get("view_mode"))
  note_browser_open = normalize_bool(ext_get("note_browser_open"), true)
  font_size = clamp(ext_get("font_size"), MIN_FONT_SIZE, MAX_FONT_SIZE)
  ensure_default_note()
  dirty = false
end

local function save_project_state(force)
  if not force and not dirty then return end
  apply_buffers_to_active()
  ext_set("notes", encode_note_list())
  ext_set("active_id", active_id)
  ext_set("next_id", tostring(next_id))
  ext_set("dock_id", tostring(last_dock_id or 0))
  ext_set("view_mode", view_mode)
  ext_set("note_browser_open", note_browser_open and "1" or "0")
  ext_set("font_size", tostring(font_size))
  for _, note in ipairs(notes) do
    ext_set(NOTE_PREFIX .. note.id, note.body)
  end
  dirty = false
  last_save_at = reaper.time_precise and reaper.time_precise() or 0
end

local function strip_inline_markdown(value)
  value = tostring(value or "")
  value = value:gsub("`([^`]+)`", "%1")
  value = value:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1 <%2>")
  value = value:gsub("%*%*([^%*]+)%*%*", "%1")
  value = value:gsub("__([^_]+)__", "%1")
  value = value:gsub("%*([^%*]+)%*", "%1")
  value = value:gsub("_([^_]+)_", "%1")
  return value
end

local function markdown_blocks(markdown)
  local blocks = {}
  local in_code = false
  for line in (tostring(markdown or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^```") then
      in_code = not in_code
      blocks[#blocks + 1] = { type = "code_fence", text = "" }
    elseif in_code then
      blocks[#blocks + 1] = { type = "code", text = line }
    else
      local hashes, heading = line:match("^(#+)%s+(.+)$")
      local bullet = line:match("^%s*[-%*+]%s+(.+)$")
      local number = line:match("^%s*%d+%.%s+(.+)$")
      local quote = line:match("^>%s*(.*)$")
      if hashes then
        blocks[#blocks + 1] = { type = "heading", level = math.min(#hashes, 3), text = strip_inline_markdown(heading) }
      elseif bullet then
        blocks[#blocks + 1] = { type = "bullet", text = strip_inline_markdown(bullet) }
      elseif number then
        blocks[#blocks + 1] = { type = "number", text = strip_inline_markdown(number) }
      elseif quote then
        blocks[#blocks + 1] = { type = "quote", text = strip_inline_markdown(quote) }
      elseif trim(line) == "" then
        blocks[#blocks + 1] = { type = "blank", text = "" }
      else
        blocks[#blocks + 1] = { type = "paragraph", text = strip_inline_markdown(line) }
      end
    end
  end
  return blocks
end

local helpers = {
  add_note = add_note,
  delete_note = delete_note,
  duplicate_active_note = duplicate_active_note,
  encode_note_list = encode_note_list,
  decode_note_list = decode_note_list,
  load_state_from_table = load_state_from_table,
  markdown_blocks = markdown_blocks,
  normalized_title = normalized_title,
  normalize_view_mode = normalize_view_mode,
  serialize_notes = serialize_notes,
  strip_inline_markdown = strip_inline_markdown,
}

if KRGSH_NOTEPAD_TEST then
  return helpers
end

local function imgui_missing()
  reaper.ShowMessageBox(
    "Notepad requires ReaImGui. Install ReaImGui from ReaPack, then run this action again.",
    WINDOW_TITLE,
    0
  )
end

if not reaper.ImGui_CreateContext then
  imgui_missing()
  return helpers
end

local ctx = reaper.ImGui_CreateContext(WINDOW_TITLE)
local font = reaper.ImGui_CreateFont and reaper.ImGui_CreateFont("sans-serif")
local mono_font = reaper.ImGui_CreateFont and reaper.ImGui_CreateFont("monospace")
if font and reaper.ImGui_Attach then reaper.ImGui_Attach(ctx, font) end
if mono_font and reaper.ImGui_Attach then reaper.ImGui_Attach(ctx, mono_font) end

local function color(r, g, b, a)
  if reaper.ImGui_ColorConvertDouble4ToU32 then
    return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a or 1)
  end
  return 0xffffffff
end

local colors = {
  text = color(0.90, 0.91, 0.90, 1),
  muted = color(0.58, 0.62, 0.64, 1),
  accent = color(0.17, 0.55, 0.78, 1),
  quote = color(0.70, 0.78, 0.64, 1),
  code = color(0.86, 0.80, 0.62, 1),
}

local style_colors = {
  WindowBg = { 0.09, 0.10, 0.11, 1 },
  ChildBg = { 0.12, 0.13, 0.14, 1 },
  FrameBg = { 0.16, 0.17, 0.18, 1 },
  FrameBgHovered = { 0.20, 0.22, 0.23, 1 },
  FrameBgActive = { 0.22, 0.25, 0.27, 1 },
  Button = { 0.16, 0.18, 0.19, 1 },
  ButtonHovered = { 0.22, 0.27, 0.30, 1 },
  ButtonActive = { 0.13, 0.43, 0.62, 1 },
  Header = { 0.14, 0.34, 0.46, 1 },
  HeaderHovered = { 0.17, 0.45, 0.62, 1 },
  HeaderActive = { 0.12, 0.38, 0.54, 1 },
  Text = { 0.90, 0.91, 0.90, 1 },
  TextDisabled = { 0.50, 0.54, 0.55, 1 },
  Border = { 0.30, 0.32, 0.34, 1 },
}

local function push_style()
  local count = 0
  for name, rgba in pairs(style_colors) do
    local key = reaper["ImGui_Col_" .. name]
    if key then
      reaper.ImGui_PushStyleColor(ctx, key(), color(rgba[1], rgba[2], rgba[3], rgba[4]))
      count = count + 1
    end
  end
  return count
end

local function button(label)
  return reaper.ImGui_Button(ctx, label)
end

local CHILD_FLAGS_NONE = 0
local CHILD_FLAGS_BORDER = reaper.ImGui_ChildFlags_Borders and reaper.ImGui_ChildFlags_Borders()
  or reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border()
  or 0

local function begin_child(id, w, h, child_flags, window_flags)
  child_flags = tonumber(child_flags) or CHILD_FLAGS_NONE
  return reaper.ImGui_BeginChild(ctx, id, w, h, child_flags, window_flags or 0)
end

local function draw_sidebar()
  if begin_child("notes", SIDEBAR_WIDTH, 0, CHILD_FLAGS_BORDER) then
    reaper.ImGui_Text(ctx, "Notes")
    reaper.ImGui_Separator(ctx)
    for _, note in ipairs(notes) do
      local selected = note.id == active_id
      if reaper.ImGui_Selectable(ctx, note.title .. "##" .. note.id, selected) then
        apply_buffers_to_active()
        select_note(note.id)
      end
    end
    reaper.ImGui_Separator(ctx)
    if button("Add") then
      apply_buffers_to_active()
      add_note()
      save_project_state(true)
    end
    reaper.ImGui_SameLine(ctx)
    if button("Duplicate") then
      apply_buffers_to_active()
      duplicate_active_note()
      save_project_state(true)
    end
    if button("Delete") then
      apply_buffers_to_active()
      delete_note(active_id)
      save_project_state(true)
    end
    reaper.ImGui_EndChild(ctx)
  end
end

local function draw_preview()
  if begin_child("preview", 0, 0, CHILD_FLAGS_BORDER) then
    if font and reaper.ImGui_PushFont then reaper.ImGui_PushFont(ctx, font, font_size) end
    local number = 1
    for _, block in ipairs(markdown_blocks(body_buffer)) do
      if block.type == "heading" then
        if font and reaper.ImGui_PushFont then reaper.ImGui_PushFont(ctx, font, font_size + 2) end
        reaper.ImGui_TextColored(ctx, colors.accent, block.text)
        if font and reaper.ImGui_PopFont then reaper.ImGui_PopFont(ctx) end
        reaper.ImGui_Separator(ctx)
      elseif block.type == "bullet" then
        reaper.ImGui_BulletText(ctx, block.text)
      elseif block.type == "number" then
        reaper.ImGui_TextWrapped(ctx, tostring(number) .. ". " .. block.text)
        number = number + 1
      elseif block.type == "quote" then
        reaper.ImGui_TextColored(ctx, colors.quote, "> " .. block.text)
      elseif block.type == "code" then
        if mono_font and reaper.ImGui_PushFont then reaper.ImGui_PushFont(ctx, mono_font, font_size) end
        reaper.ImGui_TextColored(ctx, colors.code, block.text == "" and " " or block.text)
        if mono_font and reaper.ImGui_PopFont then reaper.ImGui_PopFont(ctx) end
      elseif block.type == "blank" or block.type == "code_fence" then
        reaper.ImGui_Dummy(ctx, 1, 6)
      else
        reaper.ImGui_TextWrapped(ctx, block.text)
      end
    end
    if font and reaper.ImGui_PopFont then reaper.ImGui_PopFont(ctx) end
    reaper.ImGui_EndChild(ctx)
  end
end

local function draw_editor()
  local note = active_note()
  if not note then return end

  if reaper.ImGui_Button(ctx, note_browser_open and "<" or ">") then
    note_browser_open = not note_browser_open
    dirty = true
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, view_mode == "edit" and "Preview" or "Edit") then
    apply_buffers_to_active()
    view_mode = view_mode == "edit" and "preview" or "edit"
    dirty = true
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 120)
  local font_changed, next_font_size = reaper.ImGui_SliderDouble(ctx, "Font size", font_size, MIN_FONT_SIZE, MAX_FONT_SIZE, "%.0f")
  if font_changed then
    font_size = clamp(next_font_size, MIN_FONT_SIZE, MAX_FONT_SIZE)
    dirty = true
  end

  local title_changed, next_title = reaper.ImGui_InputText(ctx, "Title", title_buffer)
  if title_changed then
    title_buffer = next_title
    apply_buffers_to_active()
  end

  local _, available_h = reaper.ImGui_GetContentRegionAvail(ctx)

  if view_mode == "preview" then
    draw_preview()
    return
  end

  if begin_child("editor", 0, available_h, CHILD_FLAGS_BORDER) then
    local input_flags = reaper.ImGui_InputTextFlags_AllowTabInput and reaper.ImGui_InputTextFlags_AllowTabInput() or 0
    if font and reaper.ImGui_PushFont then reaper.ImGui_PushFont(ctx, font, font_size) end
    local changed, next_body = reaper.ImGui_InputTextMultiline(ctx, "##body", body_buffer, -1, -1, input_flags)
    if font and reaper.ImGui_PopFont then reaper.ImGui_PopFont(ctx) end
    if changed then
      body_buffer = next_body
      apply_buffers_to_active()
    end
    reaper.ImGui_EndChild(ctx)
  end
end

local function maybe_autosave()
  local now = reaper.time_precise and reaper.time_precise() or 0
  if dirty and (now - last_save_at) >= AUTOSAVE_INTERVAL then
    save_project_state(false)
  end
end

local function loop()
  local style_count = push_style()
  reaper.ImGui_SetNextWindowSize(ctx, WIDTH, HEIGHT, reaper.ImGui_Cond_FirstUseEver())
  if last_dock_id and last_dock_id ~= 0 and reaper.ImGui_SetNextWindowDockID then
    reaper.ImGui_SetNextWindowDockID(ctx, last_dock_id, reaper.ImGui_Cond_FirstUseEver())
  end

  local visible, open = reaper.ImGui_Begin(ctx, WINDOW_TITLE, true)
  if visible then
    if reaper.ImGui_GetWindowDockID then
      local dock_id = reaper.ImGui_GetWindowDockID(ctx)
      if dock_id and dock_id ~= last_dock_id then
        last_dock_id = dock_id
        dirty = true
      end
    end

    if note_browser_open then
      draw_sidebar()
      reaper.ImGui_SameLine(ctx)
    end
    if begin_child("main", 0, 0, CHILD_FLAGS_NONE) then
      draw_editor()
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_End(ctx)
  end
  if style_count > 0 then
    reaper.ImGui_PopStyleColor(ctx, style_count)
  end

  maybe_autosave()
  if open then
    reaper.defer(loop)
  else
    save_project_state(true)
  end
end

load_project_state()
last_save_at = reaper.time_precise and reaper.time_precise() or 0
reaper.atexit(function() save_project_state(true) end)
loop()

return helpers
