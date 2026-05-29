local script_dir = (... and (...):match("^(.*[/\\])")) or "Scripts/MIDI FX Chain Knob Mapper/"

local extstate = {}
local selected_track = { guid = "{TRACK-1}", name = "Track 1" }
local mock_time = 0
local midi_event_count = 0
local midi_repeat_with_moving_project_pos = false
local set_param_calls = 0
local fx = {
  { name = "VST: Test FX", guid = "{TARGET}", params = { 0.5, 0.25 } },
}

extstate["KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER:track:{TRACK-1}"] =
  "1|1|0.005000|0|{TARGET}|VST: Test FX|0|Param 1"

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local reaper_mock = {
  CountSelectedTracks = function() return 1 end,
  GetSelectedTrack = function() return selected_track end,
  GetTrackGUID = function(track) return track.guid end,
  GetTrackName = function(track) return true, track.name end,
  TrackFX_GetCount = function() return #fx end,
  TrackFX_GetFXName = function(_, index) return true, fx[index + 1].name end,
  TrackFX_GetFXGUID = function(_, index) return fx[index + 1].guid end,
  TrackFX_GetNumParams = function(_, index) return #fx[index + 1].params end,
  TrackFX_GetParamName = function(_, _, param) return true, "Param " .. tostring(param + 1) end,
  TrackFX_GetFormattedParamValue = function(_, index, param)
    return true, string.format("%.0f", (fx[index + 1].params[param + 1] or 0) * 100)
  end,
  TrackFX_FormatParamValueNormalized = function(_, _, _, value)
    return true, string.format("%.0f", (value or 0) * 100)
  end,
  TrackFX_GetParamNormalized = function(_, index, param) return fx[index + 1].params[param + 1] or 0 end,
  TrackFX_SetParamNormalized = function(_, index, param, value)
    set_param_calls = set_param_calls + 1
    fx[index + 1].params[param + 1] = value
  end,
  GetProjExtState = function(_, section, key)
    local value = extstate[section .. ":" .. key] or ""
    return value ~= "" and 1 or 0, value
  end,
  SetProjExtState = function(_, section, key, value)
    extstate[section .. ":" .. key] = tostring(value or "")
  end,
  time_precise = function() return mock_time end,
  MIDI_GetRecentInputEvent = function(index)
    if index == 0 and midi_event_count < 2 then
      midi_event_count = midi_event_count + 1
      local timestamp = midi_repeat_with_moving_project_pos and 100 or midi_event_count
      local project_pos = midi_repeat_with_moving_project_pos and midi_event_count or 0
      return 1, string.char(0xB0, 16, 2), timestamp, 0, project_pos, 0
    end
    return 0, "", 0, 0, 0, 0
  end,
  defer = function(fn) fn() end,
}

local gfx_mock
gfx_mock = {
  mouse_x = 0,
  mouse_y = 0,
  mouse_cap = 0,
  w = 760,
  h = 392,
  init = function() end,
  dock = function(state)
    if state and state >= 0 then
      gfx_mock.dock_state = state
    end
    return gfx_mock.dock_state or 0
  end,
  setfont = function() end,
  set = function() end,
  rect = function() end,
  drawstr = function() end,
  update = function() end,
  getchar = function()
    if gfx_mock.after_first_loop then return -1 end
    gfx_mock.after_first_loop = true
    fx[1].params[2] = 0.75
    return 0
  end,
}

local env = {
  reaper = reaper_mock,
  gfx = gfx_mock,
  math = math,
  string = string,
  table = table,
  tostring = tostring,
  tonumber = tonumber,
  select = select,
  ipairs = ipairs,
  pairs = pairs,
  print = print,
}
env._G = env
setmetatable(env, { __index = _G })

local chunk, err = loadfile(script_dir .. "MIDI FX Chain Knob Mapper.lua", "t", env)
if not chunk then
  error(err)
end

env.KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER_TEST = true
local helpers = chunk()
helpers.run_unit_tests()
assert_equal(helpers.relativeCCValueToDelta(1), 1, "relative 1")
assert_equal(helpers.relativeCCValueToDelta(2), 2, "relative 2")
assert_equal(helpers.relativeCCValueToDelta(63), 63, "relative 63")
assert_equal(helpers.relativeCCValueToDelta(64), 0, "relative 64")
assert_equal(helpers.relativeCCValueToDelta(65), -63, "relative 65")
assert_equal(helpers.relativeCCValueToDelta(126), -2, "relative 126")
assert_equal(helpers.relativeCCValueToDelta(127), -1, "relative 127")
assert_equal(helpers.relativeCCValueToDelta(128), -1, "relative 128")
assert_equal(helpers.relativeCCValueToDelta(0), 0, "relative 0")
assert_equal(helpers.relativeCCValueToDelta(65, "binary_offset"), 1, "binary offset +1")
assert_equal(helpers.relativeCCValueToDelta(63, "binary_offset"), -1, "binary offset -1")
assert_equal(helpers.relativeCCValueToDelta(65, "signed_bit"), -1, "signed bit -1")
assert_equal(helpers.relativeCCValueToDelta(1, "inc_dec_1_127"), 1, "inc/dec 1/127 +1")
assert_equal(helpers.relativeCCValueToDelta(127, "inc_dec_1_127"), -1, "inc/dec 1/127 -1")
assert_equal(helpers.relativeCCValueToDelta(128, "inc_dec_1_127"), -1, "inc/dec 1/128 -1")
assert_equal(helpers.relativeCCValueToDelta(65, "inc_dec_63_65"), 1, "inc/dec 63/65 +1")
assert_equal(helpers.relativeCCValueToDelta(63, "inc_dec_63_65"), -1, "inc/dec 63/65 -1")

local absolute_mapping = helpers.normalizeSlot({ input_mode = "absolute", min = 0.25, max = 0.75 }, 1)
assert_equal(string.format("%.3f", helpers.absoluteCCValueToNormalized(127, absolute_mapping)), "0.750", "absolute max")
absolute_mapping.invert = true
assert_equal(string.format("%.3f", helpers.absoluteCCValueToNormalized(127, absolute_mapping)), "0.250", "absolute invert")
local curve_mapping = helpers.normalizeSlot({ curve = 2 }, 1)
assert_equal(string.format("%.3f", helpers.normalizedToMappingOutput(0.5, curve_mapping)), "0.250", "curve shaping")
set_param_calls = 0
assert_equal(string.format("%.3f", helpers.displayDeltaToNormalizedDelta(selected_track, 0, 0, 1)), "0.010", "display delta fallback")
assert_equal(set_param_calls, 0, "display delta conversion does not set parameter")
assert_equal(string.format("%.3f", helpers.displayValueToNormalized(selected_track, 0, 0, 17, 0.16, 16)), "0.165", "integer display target search")
helpers.decode_slots("1|1|0.005000|0|{TARGET}|VST: Test FX|0|Param 1")
local migrated = helpers.encode_slots()
assert_equal(migrated:match("1|1|1%.000000|0|{TARGET}|VST: Test FX|0|Param 1|relative|twos_complement|0%.000000|1%.000000|1%.000000|0|1") ~= nil, true, "legacy migration")

env.KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER_TEST = nil
chunk, err = loadfile(script_dir .. "MIDI FX Chain Knob Mapper.lua", "t", env)
if not chunk then
  error(err)
end
chunk()

assert_equal(type(extstate), "table", "extstate table")
assert_equal(string.format("%.2f", fx[1].params[1]), "0.52", "slot 1 target nudge")

gfx_mock.after_first_loop = false
midi_event_count = 2
gfx_mock.mouse_x = 590
gfx_mock.mouse_y = 132
gfx_mock.mouse_cap = 1
fx[1].params[2] = 0.25
chunk()
assert_equal(extstate["KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER:track:{TRACK-1}"]:match("2|1|1%.000000|0|{TARGET}|VST: Test FX|1|Param 2") ~= nil, true, "slot 2 learned target")

midi_repeat_with_moving_project_pos = true
midi_event_count = 0
gfx_mock.after_first_loop = false
gfx_mock.mouse_cap = 0
fx[1].params[1] = 0.50
chunk()
assert_equal(string.format("%.2f", fx[1].params[1]), "0.50", "moving project position does not replay relative event")

print("MIDI FX Chain Knob Mapper smoke tests passed")
