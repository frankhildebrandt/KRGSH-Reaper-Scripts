-- @description MIDI FX Chain Knob Mapper
-- @version 2.1.4
-- @author KRGSH
-- @about
--   Maps global recent MIDI CC16-CC23 input directly to parameters in the selected track FX chain.

local SECTION = "KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER"
local DEFAULT_SENSITIVITY = 1
local DEFAULT_DISPLAY_RANGE = 100
local DEFAULT_INPUT_MODE = "relative"
local DEFAULT_RELATIVE_MODE = "twos_complement"
local SLOT_COUNT = 8
local CC_FIRST = 16
local CC_LAST = 23
local WIDTH = 840
local HEIGHT = 392
local MIDI_SCAN_LIMIT = 32
local MIDI_SEEN_LIMIT = 512

local RELATIVE_MODES = {
  { id = "twos_complement", label = "Two's complement" },
  { id = "binary_offset", label = "Binary offset" },
  { id = "signed_bit", label = "Signed bit" },
  { id = "inc_dec_1_127", label = "Inc/dec 1/127" },
  { id = "inc_dec_63_65", label = "Inc/dec 63/65" },
}

local RELATIVE_MODE_LABELS = {}
local RELATIVE_MODE_IDS = {}
for _, mode in ipairs(RELATIVE_MODES) do
  RELATIVE_MODE_LABELS[mode.id] = mode.label
  RELATIVE_MODE_IDS[#RELATIVE_MODE_IDS + 1] = mode.id
end

local slots = {}
local current_track
local current_track_guid = ""
local mouse_was_down = false
local mouse_dragging_curve = nil
local learn_slot = nil
local learn_snapshot = nil
local learn_started_at = 0
local last_dock_state = nil
local seen_midi = {}
local seen_midi_order = {}
local slot_source_devices = {}
local midi_primed = false
local last_cc = nil
local last_cc_value = nil
local last_cc_delta = nil
local last_cc_slot = nil
local midi_activity_until = 0
local midi_api_missing = false
local ui_regions = {}
local edit_focus = nil

local function clamp(value, lo, hi)
  value = tonumber(value) or lo
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

local function bool_to_field(value)
  return value and "1" or "0"
end

local function field_to_bool(value)
  return value == "1" or value == "true"
end

local function valid_relative_mode(value)
  value = tostring(value or "")
  return RELATIVE_MODE_LABELS[value] ~= nil
end

local function normalize_input_mode(value)
  value = tostring(value or DEFAULT_INPUT_MODE)
  if value == "absolute" or value == "relative" then
    return value
  end
  return DEFAULT_INPUT_MODE
end

local function normalize_relative_mode(value)
  if valid_relative_mode(value) then
    return tostring(value)
  end
  return DEFAULT_RELATIVE_MODE
end

local function normalize_sensitivity(value)
  value = tonumber(value) or DEFAULT_SENSITIVITY

  -- Versions before 2.0.4 stored normalized-unit sensitivities such as
  -- 0.005. Sensitivity is now expressed in displayed parameter units.
  if value > 0 and value <= 0.05 then
    return DEFAULT_SENSITIVITY
  end

  return clamp(value, 0.01, 100)
end

local function normalize_bound(value, fallback)
  return clamp(tonumber(value) or fallback, 0, 1)
end

local function normalize_curve(value)
  return clamp(tonumber(value) or 1, 0.10, 8)
end

local function valid_midi_byte(value)
  value = tonumber(value)
  return value and value >= 0 and value <= 255 and value == math.floor(value)
end

local function valid_midi_data_byte(value)
  value = tonumber(value)
  return value and value >= 0 and value <= 127 and value == math.floor(value)
end

local function valid_relative_value_byte(value)
  value = tonumber(value)
  return value and value >= 0 and value <= 128 and value == math.floor(value)
end

local function default_slot(slot)
  return {
    slot = slot,
    enabled = false,
    sensitivity = DEFAULT_SENSITIVITY,
    input_mode = DEFAULT_INPUT_MODE,
    relative_mode = DEFAULT_RELATIVE_MODE,
    min = 0,
    max = 1,
    curve = 1,
    invert = false,
    collapsed = true,
    target_fx_guid = "",
    target_fx_index = -1,
    target_fx_name = "",
    target_param = -1,
    target_param_name = "",
  }
end

local function normalize_slot(mapping, slot)
  local normalized = default_slot(slot or (mapping and mapping.slot) or 1)
  if mapping then
    for key, value in pairs(mapping) do
      normalized[key] = value
    end
  end

  normalized.slot = slot or tonumber(normalized.slot) or 1
  normalized.enabled = normalized.enabled == true
  normalized.sensitivity = normalize_sensitivity(normalized.sensitivity)
  normalized.input_mode = normalize_input_mode(normalized.input_mode)
  normalized.relative_mode = normalize_relative_mode(normalized.relative_mode)
  normalized.min = normalize_bound(normalized.min, 0)
  normalized.max = normalize_bound(normalized.max, 1)
  normalized.curve = normalize_curve(normalized.curve)
  normalized.invert = normalized.invert == true
  normalized.collapsed = normalized.collapsed ~= false
  normalized.target_fx_index = tonumber(normalized.target_fx_index) or -1
  normalized.target_param = tonumber(normalized.target_param) or -1
  normalized.target_fx_guid = tostring(normalized.target_fx_guid or "")
  normalized.target_fx_name = tostring(normalized.target_fx_name or "")
  normalized.target_param_name = tostring(normalized.target_param_name or "")
  return normalized
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
    local mapping = normalize_slot(slots[slot], slot)
    lines[#lines + 1] = table.concat({
      slot,
      bool_to_field(mapping.enabled),
      string.format("%.6f", mapping.sensitivity),
      mapping.target_fx_index,
      esc(mapping.target_fx_guid),
      esc(mapping.target_fx_name),
      mapping.target_param,
      esc(mapping.target_param_name),
      esc(mapping.input_mode),
      esc(mapping.relative_mode),
      string.format("%.6f", mapping.min),
      string.format("%.6f", mapping.max),
      string.format("%.6f", mapping.curve),
      bool_to_field(mapping.invert),
      bool_to_field(mapping.collapsed),
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
      slots[slot] = normalize_slot({
        slot = slot,
        enabled = fields[2] == "1",
        sensitivity = fields[3],
        target_fx_index = fields[4],
        target_fx_guid = unesc(fields[5]),
        target_fx_name = unesc(fields[6]),
        target_param = fields[7],
        target_param_name = unesc(fields[8]),
        input_mode = unesc(fields[9]),
        relative_mode = unesc(fields[10]),
        min = fields[11],
        max = fields[12],
        curve = fields[13],
        invert = field_to_bool(fields[14]),
        collapsed = fields[15] == nil and true or field_to_bool(fields[15]),
      }, slot)
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

local function formatted_param_number(track, fx, param)
  if not reaper.TrackFX_GetFormattedParamValue then return nil end

  local ok, value = reaper.TrackFX_GetFormattedParamValue(track, fx, param, "")
  if not ok or not value or value == "" then return nil end

  local number = value:match("[-+]?%d+[%.%,]?%d*")
  if not number then return nil end

  number = number:gsub(",", ".")
  return tonumber(number)
end

local function formatted_param_number_at_normalized(track, fx, param, normalized_value)
  if not reaper.TrackFX_FormatParamValueNormalized then return nil end

  local ok, retval, value = pcall(reaper.TrackFX_FormatParamValueNormalized, track, fx, param, normalized_value, "")
  if not ok or not retval or not value or value == "" then return nil end

  local number = value:match("[-+]?%d+[%.%,]?%d*")
  if not number then return nil end

  number = number:gsub(",", ".")
  return tonumber(number)
end

local function display_value_to_normalized(track, fx, param, target_display, current_normalized, current_display)
  if not reaper.TrackFX_FormatParamValueNormalized or not target_display or not current_display then
    return nil
  end

  current_normalized = clamp(current_normalized, 0, 1)
  if target_display == current_display then
    return current_normalized
  end

  local upward = target_display > current_display
  local lo = upward and current_normalized or 0
  local hi = upward and 1 or current_normalized
  local best = nil

  for _ = 1, 18 do
    local mid = (lo + hi) * 0.5
    local display = formatted_param_number_at_normalized(track, fx, param, mid)
    if not display then return nil end

    if upward then
      if display >= target_display then
        best = mid
        hi = mid
      else
        lo = mid
      end
    else
      if display <= target_display then
        best = mid
        lo = mid
      else
        hi = mid
      end
    end
  end

  return best
end

local function display_delta_to_normalized_delta(track, fx, param, display_delta)
  local current_normalized = reaper.TrackFX_GetParamNormalized(track, fx, param)
  local current_display = formatted_param_number(track, fx, param)

  if current_display then
    local probe_offset = current_normalized <= 0.95 and 0.01 or -0.01
    local probe_display = formatted_param_number_at_normalized(track, fx, param, clamp(current_normalized + probe_offset, 0, 1))

    if probe_display and probe_display ~= current_display then
      local display_per_normalized = (probe_display - current_display) / probe_offset
      if display_per_normalized ~= 0 then
        return display_delta / display_per_normalized
      end
    end
  end

  if reaper.TrackFX_GetParam then
    local ok, _, minimum, maximum = pcall(reaper.TrackFX_GetParam, track, fx, param)
    if ok and minimum and maximum and maximum ~= minimum then
      return display_delta / (maximum - minimum)
    end
  end

  return display_delta / DEFAULT_DISPLAY_RANGE
end

local function mapping_bounds(mapping)
  mapping = normalize_slot(mapping, mapping and mapping.slot or 1)
  local lo = mapping.min
  local hi = mapping.max
  if lo > hi then
    lo, hi = hi, lo
  end
  return lo, hi
end

local function apply_curve(value, curve)
  value = clamp(value, 0, 1)
  curve = normalize_curve(curve)
  if math.abs(curve - 1) < 0.000001 then
    return value
  end
  return clamp(value ^ curve, 0, 1)
end

local function normalized_to_mapping_output(value, mapping)
  mapping = normalize_slot(mapping, mapping and mapping.slot or 1)
  value = clamp(value, 0, 1)
  if mapping.invert then
    value = 1 - value
  end
  value = apply_curve(value, mapping.curve)

  local lo, hi = mapping_bounds(mapping)
  return clamp(lo + ((hi - lo) * value), lo, hi)
end

local function absoluteCCValueToNormalized(value, mapping)
  if not value or not valid_midi_data_byte(value) then return nil end
  return normalized_to_mapping_output(value / 127, mapping or default_slot(1))
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
  local mapping = normalize_slot(slots[slot], slot)
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

local function relativeCCValueToDelta(value, mode)
  value = tonumber(value)
  if not valid_relative_value_byte(value) then return 0 end

  mode = normalize_relative_mode(mode)
  if mode == "binary_offset" then
    if value == 64 then return 0 end
    return value - 64
  elseif mode == "signed_bit" then
    local magnitude = value & 0x3F
    if magnitude == 0 then return 0 end
    return (value & 0x40) == 0x40 and -magnitude or magnitude
  elseif mode == "inc_dec_1_127" then
    if value == 1 then return 1 end
    if value == 127 or value == 128 then return -1 end
    return 0
  elseif mode == "inc_dec_63_65" then
    if value == 65 then return 1 end
    if value == 63 then return -1 end
    return 0
  end

  if value == 0 or value == 64 then return 0 end
  if value == 128 then return -1 end
  if value >= 1 and value <= 63 then return value end
  return value - 128
end

local function relativeCCEventToDelta(status, cc_number, cc_value, expected_channel, mode)
  if not valid_midi_byte(status) or not valid_midi_data_byte(cc_number) or not valid_relative_value_byte(cc_value) then
    return 0
  end

  if (status & 0xF0) ~= 0xB0 then return 0 end

  local channel = status & 0x0F
  if expected_channel ~= nil and channel ~= expected_channel then
    return 0
  end

  return relativeCCValueToDelta(cc_value, mode)
end

local function run_unit_tests()
  local cases = {
    { "twos_complement", 1, 1 },
    { "twos_complement", 2, 2 },
    { "twos_complement", 63, 63 },
    { "twos_complement", 64, 0 },
    { "twos_complement", 65, -63 },
    { "twos_complement", 126, -2 },
    { "twos_complement", 127, -1 },
    { "twos_complement", 128, -1 },
    { "twos_complement", 0, 0 },
    { "binary_offset", 64, 0 },
    { "binary_offset", 65, 1 },
    { "binary_offset", 127, 63 },
    { "binary_offset", 63, -1 },
    { "binary_offset", 1, -63 },
    { "signed_bit", 1, 1 },
    { "signed_bit", 63, 63 },
    { "signed_bit", 65, -1 },
    { "signed_bit", 127, -63 },
    { "inc_dec_1_127", 1, 1 },
    { "inc_dec_1_127", 127, -1 },
    { "inc_dec_1_127", 128, -1 },
    { "inc_dec_1_127", 64, 0 },
    { "inc_dec_63_65", 65, 1 },
    { "inc_dec_63_65", 63, -1 },
    { "inc_dec_63_65", 1, 0 },
    { "twos_complement", -1, 0 },
  }

  for _, case in ipairs(cases) do
    local actual = relativeCCValueToDelta(case[2], case[1])
    if actual ~= case[3] then
      error("relativeCCValueToDelta(" .. tostring(case[2]) .. ", " .. tostring(case[1]) .. ") expected " .. tostring(case[3]) .. ", got " .. tostring(actual), 2)
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

  local mapping = normalize_slot({ input_mode = "absolute", min = 0.25, max = 0.75 }, 1)
  if string.format("%.3f", absoluteCCValueToNormalized(127, mapping)) ~= "0.750" then
    error("absolute max mapping failed", 2)
  end

  mapping.invert = true
  if string.format("%.3f", absoluteCCValueToNormalized(127, mapping)) ~= "0.250" then
    error("absolute invert mapping failed", 2)
  end

  mapping = normalize_slot({ curve = 2 }, 1)
  if string.format("%.3f", normalized_to_mapping_output(0.5, mapping)) ~= "0.250" then
    error("curve mapping failed", 2)
  end

  decode_slots("1|1|0.005000|0|{TARGET}|VST: Test FX|0|Param 1")
  if slots[1].sensitivity ~= DEFAULT_SENSITIVITY or slots[1].input_mode ~= DEFAULT_INPUT_MODE then
    error("legacy slot migration failed", 2)
  end
end

local function export_for_tests()
  return {
    RELATIVE_MODE_IDS = RELATIVE_MODE_IDS,
    DEFAULT_RELATIVE_MODE = DEFAULT_RELATIVE_MODE,
    absoluteCCValueToNormalized = absoluteCCValueToNormalized,
    decode_slots = decode_slots,
    displayValueToNormalized = display_value_to_normalized,
    displayDeltaToNormalizedDelta = display_delta_to_normalized_delta,
    encode_slots = encode_slots,
    normalizedToMappingOutput = normalized_to_mapping_output,
    normalizeSlot = normalize_slot,
    relativeCCValueToDelta = relativeCCValueToDelta,
    relativeCCEventToDelta = relativeCCEventToDelta,
    run_unit_tests = run_unit_tests,
  }
end

if rawget(_G, "KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER_TEST") then
  return export_for_tests()
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

local function apply_slot_midi_event(slot, status, cc_value)
  if not current_track then return 0 end

  local mapping = normalize_slot(slots[slot], slot)
  slots[slot] = mapping
  local fx, param = resolve_target(current_track, mapping)
  if fx < 0 or param < 0 or param >= reaper.TrackFX_GetNumParams(current_track, fx) then
    return 0
  end

  if mapping.input_mode == "absolute" then
    local next_value = absoluteCCValueToNormalized(cc_value, mapping)
    if next_value then
      reaper.TrackFX_SetParamNormalized(current_track, fx, param, next_value)
    end
    return next_value or 0
  end

  local delta = relativeCCEventToDelta(status, CC_FIRST + slot - 1, cc_value, nil, mapping.relative_mode)
  if delta == 0 then return 0 end

  local current_value = reaper.TrackFX_GetParamNormalized(current_track, fx, param)
  local display_delta = delta * mapping.sensitivity
  local lo, hi = mapping_bounds(mapping)
  local current_display = formatted_param_number(current_track, fx, param)
  local next_value = nil

  if current_display then
    next_value = display_value_to_normalized(current_track, fx, param, current_display + display_delta, current_value, current_display)
  end

  if not next_value then
    local normalized_delta = display_delta_to_normalized_delta(current_track, fx, param, display_delta)
    next_value = current_value + normalized_delta
  end

  next_value = clamp(next_value, lo, hi)
  reaper.TrackFX_SetParamNormalized(current_track, fx, param, next_value)
  return delta
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
      -- retval is REAPER's stable recent-event sequence number. The timestamp
      -- is relative to the current play position, so it can drift between polls.
      local key = table.concat({
        tostring(retval),
        tostring(device),
        tostring(status),
        tostring(data1),
        tostring(data2),
      }, ":")
      if remember_midi_event(key) then
        events[#events + 1] = { status = status, cc = data1, value = data2, device = device }
      end
    end
  end

  if not midi_primed then
    midi_primed = true
    return
  end

  for idx = #events, 1, -1 do
    local event = events[idx]
    local slot = cc_to_slot(event.cc)
    local mapping = slot > 0 and normalize_slot(slots[slot], slot) or nil
    local result = 0

    if slot > 0 then
      local event_device = tostring(event.device or "")
      local source_device = slot_source_devices[slot]
      if not source_device or source_device == event_device then
        slot_source_devices[slot] = event_device
        result = apply_slot_midi_event(slot, event.status, event.value)
      end
    end

    last_cc = event.cc
    last_cc_value = event.value
    last_cc_delta = mapping and mapping.input_mode == "absolute" and string.format("%.3f", result) or result
    last_cc_slot = slot
    midi_activity_until = reaper.time_precise and (reaper.time_precise() + 1.0) or 1
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

  local mapping = normalize_slot(slots[slot], slot)
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

  local mapping = normalize_slot(slots[slot], slot)
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
  local mapping = normalize_slot(slots[slot], slot)
  mapping.sensitivity = clamp(mapping.sensitivity + amount, 0.01, 100)
  slots[slot] = mapping
  save_slots()
end

local function choose_input_mode(slot)
  local mapping = normalize_slot(slots[slot], slot)
  gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
  local choice = gfx.showmenu("Relative|Absolute")
  if choice == 1 then
    mapping.input_mode = "relative"
  elseif choice == 2 then
    mapping.input_mode = "absolute"
  else
    return
  end
  slots[slot] = mapping
  save_slots()
end

local function choose_relative_mode(slot)
  local mapping = normalize_slot(slots[slot], slot)
  local items = {}
  for _, mode in ipairs(RELATIVE_MODES) do
    items[#items + 1] = menu_label(mode.label)
  end

  gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
  local choice = gfx.showmenu(table.concat(items, "|"))
  local selected = RELATIVE_MODE_IDS[choice]
  if not selected then return end

  mapping.relative_mode = selected
  slots[slot] = mapping
  save_slots()
end

local function toggle_slot(slot)
  local mapping = normalize_slot(slots[slot], slot)
  mapping.collapsed = not mapping.collapsed
  slots[slot] = mapping
  save_slots()
end

local function toggle_invert(slot)
  local mapping = normalize_slot(slots[slot], slot)
  mapping.invert = not mapping.invert
  slots[slot] = mapping
  save_slots()
end

local function field_value(mapping, field)
  if field == "sensitivity" then
    return mapping.sensitivity
  elseif field == "min" then
    return mapping.min
  elseif field == "max" then
    return mapping.max
  elseif field == "curve" then
    return mapping.curve
  end
  return nil
end

local function set_field_value(slot, field, value)
  local mapping = normalize_slot(slots[slot], slot)
  if field == "sensitivity" then
    mapping.sensitivity = normalize_sensitivity(value)
  elseif field == "min" then
    mapping.min = normalize_bound(value, mapping.min)
  elseif field == "max" then
    mapping.max = normalize_bound(value, mapping.max)
  elseif field == "curve" then
    mapping.curve = normalize_curve(value)
  end
  slots[slot] = mapping
  save_slots()
end

local function begin_edit(slot, field)
  local mapping = normalize_slot(slots[slot], slot)
  local value = field_value(mapping, field)
  edit_focus = {
    slot = slot,
    field = field,
    text = string.format(field == "sensitivity" and "%.3f" or "%.4f", value or 0),
  }
end

local function commit_edit()
  if not edit_focus then return end
  set_field_value(edit_focus.slot, edit_focus.field, tonumber((edit_focus.text or ""):gsub(",", ".")))
  edit_focus = nil
end

local function cancel_edit()
  edit_focus = nil
end

local function draw_text(x, y, text, r, g, b)
  gfx.set(r or 0.9, g or 0.9, b or 0.9, 1)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(text or ""))
end

local function trim_label(label, max_chars)
  label = tostring(label or "")
  if #label <= max_chars then return label end
  if max_chars <= 3 then return label:sub(1, max_chars) end
  return label:sub(1, max_chars - 3) .. "..."
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
  draw_text(x + 7, y + 6, trim_label(label, math.max(3, math.floor((w - 12) / 7))), 0.88, 0.90, 0.88)
end

local function draw_field(x, y, w, h, slot, field, value)
  local focused = edit_focus and edit_focus.slot == slot and edit_focus.field == field
  local label = focused and edit_focus.text or string.format(field == "sensitivity" and "%.3f" or "%.3f", value or 0)
  draw_button(x, y, w, h, label, focused)
end

local function draw_curve_editor(x, y, w, h, mapping)
  gfx.set(0.08, 0.085, 0.09, 1)
  gfx.rect(x, y, w, h, 1)
  gfx.set(0.26, 0.28, 0.29, 1)
  gfx.rect(x, y, w, h, 0)

  local points = 24
  local last_x, last_y
  for i = 0, points do
    local t = i / points
    local shaped = apply_curve(mapping.invert and (1 - t) or t, mapping.curve)
    local px = x + (t * w)
    local py = y + h - (shaped * h)
    if last_x and gfx.line then
      gfx.set(0.30, 0.72, 0.74, 1)
      gfx.line(last_x, last_y, px, py)
    end
    last_x, last_y = px, py
  end
end

local function add_region(kind, x, y, w, h, slot, field)
  ui_regions[#ui_regions + 1] = {
    kind = kind,
    x = x,
    y = y,
    w = w,
    h = h,
    slot = slot,
    field = field,
  }
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
    local slot = last_cc_slot and last_cc_slot > 0 and ("  slot " .. tostring(last_cc_slot)) or "  ignored"
    return string.format("Last CC %d value %d result %s%s", last_cc, last_cc_value or 0, tostring(last_cc_delta or 0), slot)
  end

  return "Waiting for global CC16-CC23"
end

local function draw_ui()
  ui_regions = {}
  gfx.set(0.06, 0.065, 0.07, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)

  local view_w = math.max(gfx.w, 320)
  local right = view_w - 14
  local dock_x = math.max(222, right - 70)

  gfx.setfont(1, "Arial", 18)
  draw_text(18, 14, "MIDI FX Chain Knob Mapper", 0.92, 0.92, 0.88)
  gfx.setfont(2, "Arial", 13)
  draw_button(dock_x, 14, 70, 24, gfx.dock(-1) == 0 and "Dock" or "Float", gfx.dock(-1) ~= 0)
  add_region("dock", dock_x, 14, 70, 24)

  if not current_track then
    draw_text(18, 46, "Select a track to create or edit its 8 knob mappings.", 0.70, 0.73, 0.72)
    draw_text(18, 68, midi_status_label(), 0.70, 0.73, 0.72)
    return
  end

  local _, track_name = reaper.GetTrackName(current_track, "")
  draw_text(18, 46, trim_label("Track: " .. track_name, 42), 0.70, 0.73, 0.72)
  draw_text(math.min(360, 18), 66, trim_label(midi_status_label(), math.floor((view_w - 34) / 7)), 0.70, 0.73, 0.72)

  local y = 92
  local row_x = 14
  local row_w = math.max(292, view_w - 28)
  local compact = row_w < 680

  for slot = 1, SLOT_COUNT do
    local mapping = normalize_slot(slots[slot], slot)
    slots[slot] = mapping
    local fx, param = resolve_target(current_track, mapping)
    local mapped = fx >= 0 and param >= 0 and param < reaper.TrackFX_GetNumParams(current_track, fx)
    local active = last_cc_slot == slot and (midi_activity_until >= (reaper.time_precise and reaper.time_precise() or 0))
    local expanded = not mapping.collapsed
    local row_h = expanded and (compact and 208 or 88) or (compact and 62 or 32)

    if y < gfx.h then
      gfx.set(0.095, 0.10, 0.105, 1)
      gfx.rect(row_x, y - 5, row_w, row_h, 1)

      local x = row_x + 8
      draw_button(x, y - 1, 22, 24, expanded and "-" or "+", expanded)
      add_region("toggle", x, y - 1, 22, 24, slot)
      x = x + 30
      draw_text(x, y + 4, string.format("K%d CC%d", slot, CC_FIRST + slot - 1), 0.85, 0.86, 0.84)
      x = x + (compact and 52 or 82)

      local fx_label = mapped and fx_name(current_track, fx) or (mapping.enabled and "Unresolved FX" or "Choose FX")
      local param_label = mapped and param_name(current_track, fx, param) or "Choose parameter"
      local value_label = mapped and param_value_label(current_track, fx, param) or "--"
      local value_w = compact and 44 or 72
      local small_w = compact and math.max(50, math.floor((row_x + row_w - x - value_w - 12) / 2)) or 174

      draw_button(x, y - 1, small_w, 24, fx_label, mapped or active)
      add_region("fx", x, y - 1, small_w, 24, slot)
      x = x + small_w + 6
      draw_button(x, y - 1, small_w, 24, param_label, mapped or active)
      add_region("param", x, y - 1, small_w, 24, slot)
      x = x + small_w + 6
      draw_button(x, y - 1, value_w, 24, value_label, mapped)
      x = x + value_w + 8

      if not compact and x + 168 <= row_x + row_w then
        draw_button(x, y - 1, 64, 24, learn_slot == slot and "Learning" or "Learn", learn_slot == slot)
        add_region("learn", x, y - 1, 64, 24, slot)
        x = x + 72
        draw_button(x, y - 1, 24, 24, "-", false)
        add_region("sens_down", x, y - 1, 24, 24, slot)
        x = x + 28
        draw_field(x, y - 1, 62, 24, slot, "sensitivity", mapping.sensitivity)
        add_region("field", x, y - 1, 62, 24, slot, "sensitivity")
        x = x + 66
        draw_button(x, y - 1, 24, 24, "+", false)
        add_region("sens_up", x, y - 1, 24, 24, slot)
      end

      if compact then
        local ty = y + 30
        local tx = row_x + 10
        draw_button(tx, ty, 62, 24, learn_slot == slot and "Learning" or "Learn", learn_slot == slot)
        add_region("learn", tx, ty, 62, 24, slot)
        draw_button(tx + 68, ty, 24, 24, "-", false)
        add_region("sens_down", tx + 68, ty, 24, 24, slot)
        draw_field(tx + 96, ty, 62, 24, slot, "sensitivity", mapping.sensitivity)
        add_region("field", tx + 96, ty, 62, 24, slot, "sensitivity")
        draw_button(tx + 162, ty, 24, 24, "+", false)
        add_region("sens_up", tx + 162, ty, 24, 24, slot)
      end

      if expanded then
        local ay = y + (compact and 62 or 32)
        local ax = row_x + 10

        if compact then
          draw_button(ax, ay, 78, 24, mapping.input_mode == "absolute" and "Absolute" or "Relative", mapping.input_mode == "absolute")
          add_region("input_mode", ax, ay, 78, 24, slot)
          if mapping.input_mode == "relative" then
            draw_button(ax + 86, ay, math.min(150, row_w - 106), 24, RELATIVE_MODE_LABELS[mapping.relative_mode] or "Relative", false)
            add_region("relative_mode", ax + 86, ay, math.min(150, row_w - 106), 24, slot)
          end

          ay = ay + 30
          draw_text(ax, ay + 6, "Min", 0.64, 0.67, 0.66)
          draw_field(ax + 28, ay, 46, 24, slot, "min", mapping.min)
          add_region("field", ax + 28, ay, 46, 24, slot, "min")
          draw_text(ax + 80, ay + 6, "Max", 0.64, 0.67, 0.66)
          draw_field(ax + 110, ay, 46, 24, slot, "max", mapping.max)
          add_region("field", ax + 110, ay, 46, 24, slot, "max")

          ay = ay + 30
          draw_text(ax, ay + 6, "Curve", 0.64, 0.67, 0.66)
          draw_field(ax + 44, ay, 54, 24, slot, "curve", mapping.curve)
          add_region("field", ax + 44, ay, 54, 24, slot, "curve")
          draw_button(ax + 106, ay, 58, 24, mapping.invert and "Invert" or "Normal", mapping.invert)
          add_region("invert", ax + 106, ay, 58, 24, slot)

          local curve_y = ay + 30
          local curve_w = math.min(row_w - 20, 240)
          draw_curve_editor(row_x + 10, curve_y, curve_w, 44, mapping)
          add_region("curve_editor", row_x + 10, curve_y, curve_w, 44, slot)
        else
          draw_button(ax, ay, 78, 24, mapping.input_mode == "absolute" and "Absolute" or "Relative", mapping.input_mode == "absolute")
          add_region("input_mode", ax, ay, 78, 24, slot)
          ax = ax + 86
          if mapping.input_mode == "relative" then
            draw_button(ax, ay, 150, 24, RELATIVE_MODE_LABELS[mapping.relative_mode] or "Relative", false)
            add_region("relative_mode", ax, ay, 150, 24, slot)
            ax = ax + 158
          end

          draw_text(ax, ay + 6, "Min", 0.64, 0.67, 0.66)
          draw_field(ax + 28, ay, 54, 24, slot, "min", mapping.min)
          add_region("field", ax + 28, ay, 54, 24, slot, "min")
          ax = ax + 88
          draw_text(ax, ay + 6, "Max", 0.64, 0.67, 0.66)
          draw_field(ax + 30, ay, 54, 24, slot, "max", mapping.max)
          add_region("field", ax + 30, ay, 54, 24, slot, "max")
          ax = ax + 92
          draw_text(ax, ay + 6, "Curve", 0.64, 0.67, 0.66)
          draw_field(ax + 44, ay, 54, 24, slot, "curve", mapping.curve)
          add_region("field", ax + 44, ay, 54, 24, slot, "curve")
          ax = ax + 106
          draw_button(ax, ay, 58, 24, mapping.invert and "Invert" or "Normal", mapping.invert)
          add_region("invert", ax, ay, 58, 24, slot)

          local curve_x = math.max(row_x + row_w - 128, ax + 66)
          draw_curve_editor(curve_x, ay, 112, 44, mapping)
          add_region("curve_editor", curve_x, ay, 112, 44, slot)
        end
      end
    end

    y = y + row_h + 8
  end
end

local function curve_from_mouse(region)
  local relative = 1 - clamp((gfx.mouse_y - region.y) / region.h, 0, 1)
  return clamp(0.10 + ((1 - relative) * 7.90), 0.10, 8)
end

local function handle_region(region)
  if region.kind == "dock" then
    if gfx.dock(-1) == 0 then gfx.dock(1) else gfx.dock(0) end
    save_dock_state()
  elseif region.kind == "toggle" then
    toggle_slot(region.slot)
  elseif region.kind == "fx" then
    choose_fx(region.slot)
  elseif region.kind == "param" then
    choose_param(region.slot)
  elseif region.kind == "learn" then
    if learn_slot == region.slot then cancel_learn() else start_learn(region.slot) end
  elseif region.kind == "sens_down" then
    adjust_sensitivity(region.slot, -0.001)
  elseif region.kind == "sens_up" then
    adjust_sensitivity(region.slot, 0.001)
  elseif region.kind == "input_mode" then
    choose_input_mode(region.slot)
  elseif region.kind == "relative_mode" then
    choose_relative_mode(region.slot)
  elseif region.kind == "invert" then
    toggle_invert(region.slot)
  elseif region.kind == "field" then
    begin_edit(region.slot, region.field)
  elseif region.kind == "curve_editor" then
    mouse_dragging_curve = region
    set_field_value(region.slot, "curve", curve_from_mouse(region))
  end
end

local function handle_mouse()
  local down = (gfx.mouse_cap & 1) == 1
  local clicked = down and not mouse_was_down
  local released = not down and mouse_was_down
  mouse_was_down = down

  if released then
    mouse_dragging_curve = nil
  end

  if down and mouse_dragging_curve then
    set_field_value(mouse_dragging_curve.slot, "curve", curve_from_mouse(mouse_dragging_curve))
    return
  end

  if not clicked then return end

  for idx = #ui_regions, 1, -1 do
    local region = ui_regions[idx]
    if point_in_rect(region.x, region.y, region.w, region.h) then
      handle_region(region)
      return
    end
  end

  if edit_focus then
    commit_edit()
  end
end

local function handle_keyboard(char)
  if not edit_focus or not char or char < 0 then return end

  if char == 13 or char == 10 then
    commit_edit()
  elseif char == 27 then
    cancel_edit()
  elseif char == 8 or char == 127 then
    edit_focus.text = (edit_focus.text or ""):sub(1, -2)
  elseif char >= 32 and char <= 126 then
    local c = string.char(char)
    if c:match("[%d%.,%-]") then
      edit_focus.text = tostring(edit_focus.text or "") .. c
    end
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
  local char = gfx.getchar()
  handle_keyboard(char)
  if char >= 0 then
    reaper.defer(loop)
  end
end

reset_slots()
last_dock_state = dock_state()
gfx.init("MIDI FX Chain Knob Mapper", WIDTH, HEIGHT, last_dock_state)
gfx.setfont(1, "Arial", 14)
loop()
