-- @description MIDI FX Chain Knob Mapper
-- @version 2.0.3
-- @author KRGSH
-- @about
--   Maps global recent MIDI CC16-CC23 input directly to parameters in the selected track FX chain.

local SECTION = "KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER"
local DEFAULT_SENSITIVITY = 0.005
local SLOT_COUNT = 8
local CC_FIRST = 16
local CC_LAST = 23
local WIDTH = 840
local HEIGHT = 392
local MIDI_SCAN_LIMIT = 32
local MIDI_SEEN_LIMIT = 512

local slots = {}
local current_track
local current_track_guid = ""
local mouse_was_down = false
local learn_slot = nil
local learn_snapshot = nil
local learn_started_at = 0
local last_dock_state = nil
local seen_midi = {}
local seen_midi_order = {}
local midi_primed = false
local last_cc = nil
local last_cc_value = nil
local last_cc_delta = nil
local last_cc_slot = nil
local midi_activity_until = 0
local midi_api_missing = false

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

local function dock_state()
  local ok, value = reaper.GetProjExtState(0, SECTION, "dock_state")
  return ok == 1 and tonumber(value) or 0
end

local function save_dock_state()
  local state = gfx.dock(-1)
  if state ~= last_dock_state then
    last_dock_state = state
    reaper.SetProjExtState(0, SECTION, "dock_state", tostring(state))
  end
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

local function fx_guid(track, fx)
  if not track or fx < 0 then return "" end
  if reaper.TrackFX_GetFXGUID then
    return reaper.TrackFX_GetFXGUID(track, fx) or ""
  end
  return ""
end

local function menu_label(value)
  value = tostring(value or "")
  value = value:gsub("[|<>#!]", " ")
  value = value:gsub("%s+", " ")
  return value
end

local function resolve_target(track, mapping)
  if not track or not mapping or not mapping.enabled then return -1, -1 end

  local count = reaper.TrackFX_GetCount(track)
  if mapping.target_fx_guid and mapping.target_fx_guid ~= "" then
    for fx = 0, count - 1 do
      if fx_guid(track, fx) == mapping.target_fx_guid then
        return fx, mapping.target_param
      end
    end
  end

  if mapping.target_fx_name and mapping.target_fx_name ~= "" then
    for fx = 0, count - 1 do
      if fx_name(track, fx) == mapping.target_fx_name then
        return fx, mapping.target_param
      end
    end
  end

  if mapping.target_fx_index and mapping.target_fx_index >= 0 and mapping.target_fx_index < count then
    return mapping.target_fx_index, mapping.target_param
  end

  return -1, -1
end

local function param_name(track, fx, param)
  local _, name = reaper.TrackFX_GetParamName(track, fx, param, "")
  return name or ("Param " .. tostring(param + 1))
end

local function param_value_label(track, fx, param)
  if not track or fx < 0 or param < 0 then return "--" end

  if reaper.TrackFX_GetFormattedParamValue then
    local ok, value = reaper.TrackFX_GetFormattedParamValue(track, fx, param, "")
    if ok and value and value ~= "" then
      return value
    end
  end

  return string.format("%.1f%%", reaper.TrackFX_GetParamNormalized(track, fx, param) * 100)
end

local function capture_parameter_snapshot(track)
  local snapshot = {}
  if not track then return snapshot end

  for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
    for param = 0, reaper.TrackFX_GetNumParams(track, fx) - 1 do
      snapshot[fx .. ":" .. param] = reaper.TrackFX_GetParamNormalized(track, fx, param)
    end
  end

  return snapshot
end

local function assign_slot(slot, fx, param)
  local mapping = slots[slot] or default_slot(slot)
  mapping.enabled = true
  mapping.target_fx_index = fx
  mapping.target_fx_guid = fx_guid(current_track, fx)
  mapping.target_fx_name = fx_name(current_track, fx)
  mapping.target_param = param
  mapping.target_param_name = param_name(current_track, fx, param)
  slots[slot] = mapping
  save_slots()
end

local function start_learn(slot)
  if not current_track then return end
  learn_slot = slot
  learn_snapshot = capture_parameter_snapshot(current_track)
  learn_started_at = reaper.time_precise and reaper.time_precise() or 0
end

local function cancel_learn()
  learn_slot = nil
  learn_snapshot = nil
  learn_started_at = 0
end

local function poll_learn()
  if not learn_slot or not current_track or not learn_snapshot then return end

  local now = reaper.time_precise and reaper.time_precise() or 0
  if learn_started_at > 0 and now - learn_started_at > 20 then
    cancel_learn()
    return
  end

  local best_fx, best_param, best_delta = nil, nil, 0
  for fx = 0, reaper.TrackFX_GetCount(current_track) - 1 do
    for param = 0, reaper.TrackFX_GetNumParams(current_track, fx) - 1 do
      local key = fx .. ":" .. param
      local old_value = learn_snapshot[key]
      if old_value ~= nil then
        local value = reaper.TrackFX_GetParamNormalized(current_track, fx, param)
        local delta = math.abs(value - old_value)
        if delta > best_delta then
          best_fx, best_param, best_delta = fx, param, delta
        end
      end
    end
  end

  if best_fx and best_delta >= 0.00001 then
    assign_slot(learn_slot, best_fx, best_param)
    cancel_learn()
  end
end

local function refresh_track()
  local track = selected_track()
  if track ~= current_track then
    cancel_learn()
    current_track = track
    current_track_guid = track_guid(track)
    if track then
      load_slots(current_track_guid)
    else
      reset_slots()
    end
  end
end

local function valid_midi_byte(value)
  value = tonumber(value)
  return value and value >= 0 and value <= 127 and value == math.floor(value)
end

local function relativeCCValueToDelta(value)
  value = tonumber(value)
  if not valid_midi_byte(value) then return 0 end

  if value == 0 or value == 64 then return 0 end
  if value >= 1 and value <= 63 then return value end
  return value - 128
end

local function relativeCCEventToDelta(status, cc_number, cc_value, expected_channel)
  if not valid_midi_byte(status) or not valid_midi_byte(cc_number) or not valid_midi_byte(cc_value) then
    return 0
  end

  if (status & 0xF0) ~= 0xB0 then return 0 end

  local channel = status & 0x0F
  if expected_channel ~= nil and channel ~= expected_channel then
    return 0
  end

  return relativeCCValueToDelta(cc_value)
end

local function run_unit_tests()
  local cases = {
    { 1, 1 },
    { 2, 2 },
    { 63, 63 },
    { 64, 0 },
    { 65, -63 },
    { 126, -2 },
    { 127, -1 },
    { 0, 0 },
    { -1, 0 },
    { 128, 0 },
  }

  for _, case in ipairs(cases) do
    local actual = relativeCCValueToDelta(case[1])
    if actual ~= case[2] then
      error("relativeCCValueToDelta(" .. tostring(case[1]) .. ") expected " .. tostring(case[2]) .. ", got " .. tostring(actual), 2)
    end
  end

  if relativeCCEventToDelta(0x90, 16, 1) ~= 0 then
    error("non-CC event should be ignored", 2)
  end

  if relativeCCEventToDelta(0xB0, 16, 127, 1) ~= 0 then
    error("wrong MIDI channel should be ignored", 2)
  end

  if relativeCCEventToDelta(0xB1, 16, 127, 1) ~= -1 then
    error("matching MIDI channel should be decoded", 2)
  end
end

local function export_for_tests()
  return {
    relativeCCValueToDelta = relativeCCValueToDelta,
    relativeCCEventToDelta = relativeCCEventToDelta,
    run_unit_tests = run_unit_tests,
  }
end

if rawget(_G, "KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER_TEST") then
  return export_for_tests()
end

local function relative_delta(status, cc_number, cc_value)
  if cc_number < CC_FIRST or cc_number > CC_LAST then
    return 0
  end

  return relativeCCEventToDelta(status, cc_number, cc_value)
end

local function cc_to_slot(cc_number)
  if cc_number >= CC_FIRST and cc_number <= CC_LAST then
    return cc_number - CC_FIRST + 1
  end

  return 0
end

local function remember_midi_event(key)
  if seen_midi[key] then return false end

  seen_midi[key] = true
  seen_midi_order[#seen_midi_order + 1] = key
  while #seen_midi_order > MIDI_SEEN_LIMIT do
    local old_key = table.remove(seen_midi_order, 1)
    seen_midi[old_key] = nil
  end

  return true
end

local function apply_slot_delta(slot, delta)
  if not current_track or delta == 0 then return end

  local mapping = slots[slot]
  local fx, param = resolve_target(current_track, mapping)
  if fx >= 0 and param >= 0 and param < reaper.TrackFX_GetNumParams(current_track, fx) then
    local current_value = reaper.TrackFX_GetParamNormalized(current_track, fx, param)
    local next_value = clamp(current_value + delta * (mapping.sensitivity or DEFAULT_SENSITIVITY), 0, 1)
    reaper.TrackFX_SetParamNormalized(current_track, fx, param, next_value)
  end
end

local function poll_midi_input()
  if not reaper.MIDI_GetRecentInputEvent then
    midi_api_missing = true
    return
  end

  midi_api_missing = false
  local events = {}
  for idx = 0, MIDI_SCAN_LIMIT - 1 do
    local ok, retval, msg, timestamp, device, project_pos, project_loop_count = pcall(reaper.MIDI_GetRecentInputEvent, idx)
    if not ok or not retval or retval == 0 or not msg or #msg < 3 then break end

    local status, data1, data2 = msg:byte(1, 3)
    if status and (status & 0xF0) == 0xB0 then
      local key = table.concat({
        tostring(timestamp),
        tostring(device),
        tostring(project_pos),
        tostring(project_loop_count),
        tostring(status),
        tostring(data1),
        tostring(data2),
      }, ":")
      if remember_midi_event(key) then
        events[#events + 1] = { status = status, cc = data1, value = data2 }
      end
    end
  end

  if not midi_primed then
    midi_primed = true
    return
  end

  for idx = #events, 1, -1 do
    local event = events[idx]
    local delta = relative_delta(event.status, event.cc, event.value)
    local slot = cc_to_slot(event.cc)

    last_cc = event.cc
    last_cc_value = event.value
    last_cc_delta = delta
    last_cc_slot = slot
    midi_activity_until = reaper.time_precise and (reaper.time_precise() + 1.0) or 1

    if slot > 0 then
      apply_slot_delta(slot, delta)
    end
  end
end

local function choose_fx(slot)
  if not current_track then return end

  local fx_indices = {}
  local items = { "Clear mapping" }
  for fx = 0, reaper.TrackFX_GetCount(current_track) - 1 do
    fx_indices[#fx_indices + 1] = fx
    items[#items + 1] = menu_label(fx + 1 .. ": " .. fx_name(current_track, fx))
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

  assign_slot(slot, fx, param)
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

local function midi_status_label()
  if midi_api_missing then
    return "MIDI_GetRecentInputEvent not available"
  end

  local now = reaper.time_precise and reaper.time_precise() or 0
  if last_cc and midi_activity_until >= now then
    local slot = last_cc_slot and ("  slot " .. tostring(last_cc_slot)) or "  ignored"
    return string.format("Last CC %d value %d delta %+d%s", last_cc, last_cc_value or 0, last_cc_delta or 0, slot)
  end

  return "Waiting for global CC16-CC23"
end

local function draw_ui()
  gfx.set(0.06, 0.065, 0.07, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  gfx.setfont(1, "Arial", 18)
  draw_text(18, 14, "MIDI FX Chain Knob Mapper", 0.92, 0.92, 0.88)
  gfx.setfont(2, "Arial", 13)
  draw_button(WIDTH - 88, 14, 70, 24, gfx.dock(-1) == 0 and "Dock" or "Float", gfx.dock(-1) ~= 0)

  if not current_track then
    draw_text(18, 46, "Select a track to create or edit its 8 knob mappings.", 0.70, 0.73, 0.72)
    draw_text(18, 68, midi_status_label(), 0.70, 0.73, 0.72)
    return
  end

  local _, track_name = reaper.GetTrackName(current_track, "")
  draw_text(18, 46, "Track: " .. track_name, 0.70, 0.73, 0.72)
  draw_text(360, 46, midi_status_label(), 0.70, 0.73, 0.72)

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
    local value_label = mapped and param_value_label(current_track, fx, param) or "--"
    local active = last_cc_slot == slot and (midi_activity_until >= (reaper.time_precise and reaper.time_precise() or 0))
    draw_button(126, y - 1, 190, 24, fx_label, mapped or active)
    draw_button(324, y - 1, 170, 24, param_label, mapped or active)
    draw_button(502, y - 1, 78, 24, value_label, mapped)
    draw_button(588, y - 1, 72, 24, learn_slot == slot and "Learning" or "Learn", learn_slot == slot)

    draw_button(672, y - 1, 28, 24, "-", false)
    draw_text(708, y + 3, string.format("%.3f", mapping.sensitivity or DEFAULT_SENSITIVITY), 0.72, 0.75, 0.74)
    draw_button(784, y - 1, 28, 24, "+", false)

    y = y + 36
  end
end

local function handle_mouse()
  local down = (gfx.mouse_cap & 1) == 1
  local clicked = down and not mouse_was_down
  mouse_was_down = down
  if not clicked then return end

  if point_in_rect(WIDTH - 88, 14, 70, 24) then
    if gfx.dock(-1) == 0 then
      gfx.dock(1)
    else
      gfx.dock(0)
    end
    save_dock_state()
    return
  end

  if not current_track then return end

  local y = 82
  for slot = 1, SLOT_COUNT do
    if point_in_rect(126, y - 1, 190, 24) then
      choose_fx(slot)
      return
    end
    if point_in_rect(324, y - 1, 170, 24) then
      choose_param(slot)
      return
    end
    if point_in_rect(588, y - 1, 72, 24) then
      if learn_slot == slot then
        cancel_learn()
      else
        start_learn(slot)
      end
      return
    end
    if point_in_rect(672, y - 1, 28, 24) then
      adjust_sensitivity(slot, -0.001)
      return
    end
    if point_in_rect(784, y - 1, 28, 24) then
      adjust_sensitivity(slot, 0.001)
      return
    end
    y = y + 36
  end
end

local function loop()
  refresh_track()
  poll_midi_input()
  poll_learn()
  draw_ui()
  handle_mouse()
  save_dock_state()

  gfx.update()
  if gfx.getchar() >= 0 then
    reaper.defer(loop)
  end
end

reset_slots()
last_dock_state = dock_state()
gfx.init("MIDI FX Chain Knob Mapper", WIDTH, HEIGHT, last_dock_state)
gfx.setfont(1, "Arial", 14)
loop()
