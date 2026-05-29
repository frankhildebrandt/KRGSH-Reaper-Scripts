-- @description MIDI FX Chain Knob Mapper
-- @version 1.0.0
-- @author KRGSH
-- @about
--   Assigns 8 relative MIDI knobs from the companion JSFX to parameters in the selected track FX chain.

local SECTION = "KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER"
local MAPPER_NAME = "MIDI FX Chain Knob Mapper"
local DEFAULT_SENSITIVITY = 0.005
local SLOT_COUNT = 8
local WIDTH = 760
local HEIGHT = 392

local slots = {}
local current_track
local current_track_guid = ""
local mapper_fx = -1
local mouse_was_down = false

local function clamp(value, lo, hi)
  if value < lo then return lo end
  if value > hi then return hi end
  return value
end

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

local function default_slot(slot)
  return {
    slot = slot,
    enabled = false,
    sensitivity = DEFAULT_SENSITIVITY,
    target_fx_guid = "",
    target_fx_index = -1,
    target_fx_name = "",
    target_param = -1,
    target_param_name = "",
  }
end

local function reset_slots()
  slots = {}
  for slot = 1, SLOT_COUNT do
    slots[slot] = default_slot(slot)
  end
end

local function ext_key(track_guid)
  return "track:" .. tostring(track_guid or "")
end

local function encode_slots()
  local lines = {}
  for slot = 1, SLOT_COUNT do
    local mapping = slots[slot] or default_slot(slot)
    lines[#lines + 1] = table.concat({
      slot,
      mapping.enabled and "1" or "0",
      string.format("%.6f", mapping.sensitivity or DEFAULT_SENSITIVITY),
      mapping.target_fx_index or -1,
      esc(mapping.target_fx_guid),
      esc(mapping.target_fx_name),
      mapping.target_param or -1,
      esc(mapping.target_param_name),
    }, "|")
  end
  return table.concat(lines, "\n")
end

local function decode_slots(value)
  reset_slots()
  for line in tostring(value or ""):gmatch("[^\n]+") do
    local fields = {}
    for field in (line .. "|"):gmatch("(.-)|") do
      fields[#fields + 1] = field
    end

    local slot = tonumber(fields[1])
    if slot and slot >= 1 and slot <= SLOT_COUNT then
      slots[slot] = {
        slot = slot,
        enabled = fields[2] == "1",
        sensitivity = tonumber(fields[3]) or DEFAULT_SENSITIVITY,
        target_fx_index = tonumber(fields[4]) or -1,
        target_fx_guid = unesc(fields[5]),
        target_fx_name = unesc(fields[6]),
        target_param = tonumber(fields[7]) or -1,
        target_param_name = unesc(fields[8]),
      }
    end
  end
end

local function save_slots()
  if current_track_guid == "" then return end
  reaper.SetProjExtState(0, SECTION, ext_key(current_track_guid), encode_slots())
end

local function load_slots(track_guid)
  local ok, value = reaper.GetProjExtState(0, SECTION, ext_key(track_guid))
  if ok == 1 and value ~= "" then
    decode_slots(value)
  else
    reset_slots()
  end
end

local function selected_track()
  if reaper.CountSelectedTracks(0) == 0 then return nil end
  return reaper.GetSelectedTrack(0, 0)
end

local function track_guid(track)
  if not track then return "" end
  return reaper.GetTrackGUID(track) or ""
end

local function fx_name(track, fx)
  local _, name = reaper.TrackFX_GetFXName(track, fx, "")
  return name or ""
end

local function menu_label(value)
  value = tostring(value or "")
  value = value:gsub("[|<>#!]", " ")
  value = value:gsub("%s+", " ")
  return value
end

local function find_mapper_fx(track)
  if not track then return -1 end
  for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
    if fx_name(track, fx):find(MAPPER_NAME, 1, true) then
      return fx
    end
  end
  return -1
end

local function ensure_mapper_fx(track)
  local fx = find_mapper_fx(track)
  if fx >= 0 then return fx end

  fx = reaper.TrackFX_AddByName(track, "JS: MIDI FX Chain Knob Mapper", false, 1)
  if fx < 0 then
    fx = reaper.TrackFX_AddByName(track, MAPPER_NAME, false, 1)
  end
  return fx
end

local function fx_guid(track, fx)
  if not track or fx < 0 then return "" end
  if reaper.TrackFX_GetFXGUID then
    return reaper.TrackFX_GetFXGUID(track, fx) or ""
  end
  return ""
end

local function resolve_target(track, mapping)
  if not track or not mapping or not mapping.enabled then return -1, -1 end

  local count = reaper.TrackFX_GetCount(track)
  if mapping.target_fx_guid and mapping.target_fx_guid ~= "" then
    for fx = 0, count - 1 do
      if fx ~= mapper_fx and fx_guid(track, fx) == mapping.target_fx_guid then
        return fx, mapping.target_param
      end
    end
  end

  if mapping.target_fx_name and mapping.target_fx_name ~= "" then
    for fx = 0, count - 1 do
      if fx ~= mapper_fx and fx_name(track, fx) == mapping.target_fx_name then
        return fx, mapping.target_param
      end
    end
  end

  if mapping.target_fx_index and mapping.target_fx_index >= 0 and mapping.target_fx_index < count then
    if mapping.target_fx_index ~= mapper_fx then
      return mapping.target_fx_index, mapping.target_param
    end
  end

  return -1, -1
end

local function param_name(track, fx, param)
  local _, name = reaper.TrackFX_GetParamName(track, fx, param, "")
  return name or ("Param " .. tostring(param + 1))
end

local function refresh_track()
  local track = selected_track()
  if track ~= current_track then
    current_track = track
    current_track_guid = track_guid(track)
    if track then
      mapper_fx = ensure_mapper_fx(track)
      load_slots(current_track_guid)
    else
      mapper_fx = -1
      reset_slots()
    end
  elseif track then
    mapper_fx = find_mapper_fx(track)
    if mapper_fx < 0 then
      mapper_fx = ensure_mapper_fx(track)
    end
  end
end

local function set_mapper_param(param, value)
  if current_track and mapper_fx >= 0 then
    reaper.TrackFX_SetParam(current_track, mapper_fx, param, value)
  end
end

local function update_mapper_status()
  if not current_track or mapper_fx < 0 then return end

  for slot = 1, SLOT_COUNT do
    local mapping = slots[slot]
    local fx, param = resolve_target(current_track, mapping)
    local mapped = fx >= 0 and param >= 0 and param < reaper.TrackFX_GetNumParams(current_track, fx)
    local value = 0
    if mapped then
      value = reaper.TrackFX_GetParamNormalized(current_track, fx, param)
    end

    set_mapper_param(8 + slot - 1, mapped and 1 or 0)
    set_mapper_param(16 + slot - 1, value)
    set_mapper_param(24 + slot - 1, mapping.sensitivity or DEFAULT_SENSITIVITY)
  end
end

local function poll_mapper_deltas()
  if not current_track or mapper_fx < 0 then return end

  for slot = 1, SLOT_COUNT do
    local delta = select(1, reaper.TrackFX_GetParam(current_track, mapper_fx, slot - 1))
    if math.abs(delta) >= 0.5 then
      set_mapper_param(slot - 1, 0)

      local mapping = slots[slot]
      local fx, param = resolve_target(current_track, mapping)
      if fx >= 0 and param >= 0 and param < reaper.TrackFX_GetNumParams(current_track, fx) then
        local current_value = reaper.TrackFX_GetParamNormalized(current_track, fx, param)
        local next_value = clamp(current_value + delta * (mapping.sensitivity or DEFAULT_SENSITIVITY), 0, 1)
        reaper.TrackFX_SetParamNormalized(current_track, fx, param, next_value)
      end
    end
  end
end

local function choose_fx(slot)
  if not current_track then return end

  local fx_indices = {}
  local items = { "Clear mapping" }
  for fx = 0, reaper.TrackFX_GetCount(current_track) - 1 do
    if fx ~= mapper_fx then
      fx_indices[#fx_indices + 1] = fx
      items[#items + 1] = menu_label(fx + 1 .. ": " .. fx_name(current_track, fx))
    end
  end

  gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
  local choice = gfx.showmenu(table.concat(items, "|"))
  if choice == 1 then
    slots[slot] = default_slot(slot)
    save_slots()
    return
  end

  local fx = fx_indices[choice - 1]
  if not fx then return end

  local mapping = slots[slot] or default_slot(slot)
  mapping.enabled = true
  mapping.target_fx_index = fx
  mapping.target_fx_guid = fx_guid(current_track, fx)
  mapping.target_fx_name = fx_name(current_track, fx)
  mapping.target_param = -1
  mapping.target_param_name = ""
  slots[slot] = mapping
  save_slots()
end

local function choose_param(slot)
  if not current_track then return end

  local mapping = slots[slot]
  local fx = select(1, resolve_target(current_track, mapping))
  if fx < 0 then return end

  local items = { "Clear mapping" }
  local params = {}
  for param = 0, reaper.TrackFX_GetNumParams(current_track, fx) - 1 do
    params[#params + 1] = param
    items[#items + 1] = menu_label(param + 1 .. ": " .. param_name(current_track, fx, param))
  end

  gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
  local choice = gfx.showmenu(table.concat(items, "|"))
  if choice == 1 then
    slots[slot] = default_slot(slot)
    save_slots()
    return
  end

  local param = params[choice - 1]
  if not param then return end

  mapping.enabled = true
  mapping.target_param = param
  mapping.target_param_name = param_name(current_track, fx, param)
  mapping.target_fx_index = fx
  mapping.target_fx_guid = fx_guid(current_track, fx)
  mapping.target_fx_name = fx_name(current_track, fx)
  slots[slot] = mapping
  save_slots()
end

local function adjust_sensitivity(slot, amount)
  local mapping = slots[slot] or default_slot(slot)
  mapping.sensitivity = clamp((mapping.sensitivity or DEFAULT_SENSITIVITY) + amount, 0.0001, 0.05)
  slots[slot] = mapping
  save_slots()
end

local function draw_text(x, y, text, r, g, b)
  gfx.set(r or 0.9, g or 0.9, b or 0.9, 1)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(text or ""))
end

local function draw_button(x, y, w, h, label, active)
  if active then
    gfx.set(0.18, 0.40, 0.44, 1)
  else
    gfx.set(0.13, 0.14, 0.15, 1)
  end
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.30, 0.32, 0.33, 1)
  gfx.rect(x, y, w, h, 0)
  draw_text(x + 8, y + 6, label, 0.88, 0.90, 0.88)
end

local function point_in_rect(x, y, w, h)
  return gfx.mouse_x >= x and gfx.mouse_x <= x + w and gfx.mouse_y >= y and gfx.mouse_y <= y + h
end

local function draw_ui()
  gfx.set(0.06, 0.065, 0.07, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gfx.setfont(1, "Arial", 18)
  draw_text(18, 14, "MIDI FX Chain Knob Mapper", 0.92, 0.92, 0.88)
  gfx.setfont(2, "Arial", 13)

  if not current_track then
    draw_text(18, 46, "Select a track to create or edit its 8 knob mappings.", 0.70, 0.73, 0.72)
    return
  end

  local _, track_name = reaper.GetTrackName(current_track, "")
  draw_text(18, 46, "Track: " .. track_name, 0.70, 0.73, 0.72)
  if mapper_fx < 0 then
    draw_text(18, 68, "Mapper JSFX was not found or could not be inserted.", 0.95, 0.50, 0.42)
    return
  end

  local y = 82
  for slot = 1, SLOT_COUNT do
    local mapping = slots[slot]
    local fx, param = resolve_target(current_track, mapping)
    local mapped = fx >= 0 and param >= 0 and param < reaper.TrackFX_GetNumParams(current_track, fx)

    gfx.set(0.095, 0.10, 0.105, 1)
    gfx.rect(14, y - 5, WIDTH - 28, 32, 1)

    draw_text(24, y + 3, string.format("Knob %d  CC%d", slot, 15 + slot), 0.85, 0.86, 0.84)

    local fx_label = mapped and fx_name(current_track, fx) or (mapping.enabled and "Unresolved FX" or "Choose FX")
    local param_label = mapped and param_name(current_track, fx, param) or "Choose parameter"
    draw_button(126, y - 1, 252, 24, fx_label, mapped)
    draw_button(386, y - 1, 252, 24, param_label, mapped)

    draw_button(646, y - 1, 28, 24, "-", false)
    draw_text(682, y + 3, string.format("%.3f", mapping.sensitivity or DEFAULT_SENSITIVITY), 0.72, 0.75, 0.74)
    draw_button(724, y - 1, 28, 24, "+", false)

    y = y + 36
  end
end

local function handle_mouse()
  local down = (gfx.mouse_cap & 1) == 1
  local clicked = down and not mouse_was_down
  mouse_was_down = down
  if not clicked or not current_track then return end

  local y = 82
  for slot = 1, SLOT_COUNT do
    if point_in_rect(126, y - 1, 252, 24) then
      choose_fx(slot)
      return
    end
    if point_in_rect(386, y - 1, 252, 24) then
      choose_param(slot)
      return
    end
    if point_in_rect(646, y - 1, 28, 24) then
      adjust_sensitivity(slot, -0.001)
      return
    end
    if point_in_rect(724, y - 1, 28, 24) then
      adjust_sensitivity(slot, 0.001)
      return
    end
    y = y + 36
  end
end

local function loop()
  refresh_track()
  poll_mapper_deltas()
  update_mapper_status()
  draw_ui()
  handle_mouse()

  gfx.update()
  if gfx.getchar() >= 0 then
    reaper.defer(loop)
  end
end

reset_slots()
gfx.init("MIDI FX Chain Knob Mapper", WIDTH, HEIGHT)
gfx.setfont(1, "Arial", 14)
loop()
