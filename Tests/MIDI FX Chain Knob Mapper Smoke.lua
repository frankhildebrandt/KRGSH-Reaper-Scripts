local script_dir = (... and (...):match("^(.*[/\\])")) or "Scripts/MIDI FX Chain Knob Mapper/"

local extstate = {}
local selected_track = { guid = "{TRACK-1}", name = "Track 1" }
local mock_time = 0
local fx = {
  { name = "JS: MIDI FX Chain Knob Mapper", guid = "{MAPPER}", params = { 2, 0, 0, 0, 0, 0, 0, 0 } },
  { name = "VST: Test FX", guid = "{TARGET}", params = { 0.5, 0.25 } },
}

extstate["KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER:track:{TRACK-1}"] =
  "1|1|0.010000|1|{TARGET}|VST: Test FX|0|Param 1"

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
  TrackFX_AddByName = function() return 0 end,
  TrackFX_GetFXGUID = function(_, index) return fx[index + 1].guid end,
  TrackFX_GetNumParams = function(_, index) return #fx[index + 1].params end,
  TrackFX_GetParamName = function(_, _, param) return true, "Param " .. tostring(param + 1) end,
  TrackFX_GetParam = function(_, index, param) return fx[index + 1].params[param + 1] or 0 end,
  TrackFX_SetParam = function(_, index, param, value) fx[index + 1].params[param + 1] = value end,
  TrackFX_GetParamNormalized = function(_, index, param) return fx[index + 1].params[param + 1] or 0 end,
  TrackFX_SetParamNormalized = function(_, index, param, value)
    if index == 0 and param >= 24 then
      fx[index + 1].params[param + 1] = 0.0001 + value * (0.05 - 0.0001)
    else
      fx[index + 1].params[param + 1] = value
    end
  end,
  GetProjExtState = function(_, section, key)
    local value = extstate[section .. ":" .. key] or ""
    return value ~= "" and 1 or 0, value
  end,
  SetProjExtState = function(_, section, key, value)
    extstate[section .. ":" .. key] = tostring(value or "")
  end,
  time_precise = function() return mock_time end,
  defer = function(fn) fn() end,
}

local gfx_mock = {
  mouse_x = 0,
  mouse_y = 0,
  mouse_cap = 0,
  w = 760,
  h = 392,
  init = function() end,
  setfont = function() end,
  set = function() end,
  rect = function() end,
  drawstr = function() end,
  update = function() end,
  getchar = function()
    if gfx_mock.after_first_loop then return -1 end
    gfx_mock.after_first_loop = true
    fx[2].params[2] = 0.75
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
setmetatable(env, { __index = _G })

local chunk, err = loadfile(script_dir .. "MIDI FX Chain Knob Mapper.lua", "t", env)
if not chunk then
  error(err)
end
chunk()

assert_equal(type(extstate), "table", "extstate table")
assert_equal(fx[1].params[1], 0, "slot 1 delta reset")
assert_equal(string.format("%.2f", fx[2].params[1]), "0.52", "slot 1 target nudge")
assert_equal(fx[1].params[9], 1, "slot 1 mapped status")

gfx_mock.after_first_loop = false
gfx_mock.mouse_x = 565
gfx_mock.mouse_y = 120
gfx_mock.mouse_cap = 1
fx[2].params[2] = 0.25
chunk()
assert_equal(extstate["KRGSH_MIDI_FX_CHAIN_KNOB_MAPPER:track:{TRACK-1}"]:match("2|1|0%.005000|1|{TARGET}|VST: Test FX|1|Param 2") ~= nil, true, "slot 2 learned target")

print("MIDI FX Chain Knob Mapper smoke tests passed")
