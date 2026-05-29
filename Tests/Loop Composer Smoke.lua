local script_dir = (... and (...):match("^(.*[/\\])")) or "Scripts/Loop Composer/"
local extstate = {}

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local reaper_mock = {
  get_action_context = function()
    return nil, script_dir .. "Loop Composer Smoke.lua"
  end,
  GetProjExtState = function(_, section, key)
    local value = extstate[section .. ":" .. key] or ""
    return value ~= "" and 1 or 0, value
  end,
  SetProjExtState = function(_, section, key, value)
    extstate[section .. ":" .. key] = tostring(value or "")
  end,
  TimeMap2_timeToBeats = function(_, time)
    return 0, math.floor((time or 0) / 4)
  end,
  TimeMap2_beatsToTime = function(_, beat, measure)
    return ((measure or 0) * 4) + (beat or 0)
  end,
  GetCursorPositionEx = function()
    return 0
  end,
  GetPlayStateEx = function()
    return 0
  end,
  GetPlayPositionEx = function()
    return 0
  end,
  GetSetRepeat = function()
    return 0
  end,
  CountSelectedTracks = function()
    return 0
  end,
  CountTracks = function()
    return 0
  end,
  APIExists = function()
    return false
  end,
  format_timestr_pos = function(time)
    return tostring(time)
  end,
}

local env = {
  M = {},
  reaper = reaper_mock,
}
setmetatable(env, { __index = _G })

for _, module in ipairs({
  "Loop Composer Env.lua",
  "Loop Composer Tracks.lua",
  "Loop Composer Items.lua",
  "Loop Composer Midi.lua",
  "Loop Composer Recording.lua",
  "Loop Composer Transport.lua",
}) do
  local chunk, err = loadfile(script_dir .. module, "t", env)
  if not chunk then
    error(err)
  end
  chunk()
end

assert_equal(type(env.M.set_length), "function", "facade set_length")
assert_equal(type(env.M.queue_loopstation_recording), "function", "facade queue_loopstation_recording")
assert_equal(type(env.M.status), "function", "facade status")

assert_equal(env.current_bars(), 8, "default bars")
env.set_ext("loop_bars", "32")
assert_equal(env.current_bars(), 32, "saved bars")
env.set_ext("loop_bars", "3")
assert_equal(env.current_bars(), 8, "invalid bars fallback")

local mapping = env.parse_midi_mapping("cc:1:74")
assert_equal(mapping.type, "cc", "mapping type")
assert_equal(mapping.channel, 1, "mapping channel")
assert_equal(mapping.number, 74, "mapping number")
assert_equal(env.encode_midi_mapping(mapping), "cc:1:74", "mapping encode")
assert_equal(env.midi_event_label(mapping), "CC 74 ch 2", "mapping label")
assert_equal(env.mapping_matches(mapping, { type = "cc", channel = 1, number = 74 }), true, "mapping match")

local slots = env.decode_target_tracks("track-a|1\ntrack-b|0")
assert_equal(#slots, 2, "target slot count")
assert_equal(slots[1].enabled, true, "target slot enabled")
assert_equal(slots[2].enabled, false, "target slot disabled")
assert_equal(env.encode_target_tracks(slots), "track-a|1\ntrack-b|0", "target slot encode")

local status = env.M.status()
assert_equal(status.bars, 8, "status bars fallback")
assert_equal(status.start_measure, 1, "status start measure")
assert_equal(status.end_measure, 8, "status end measure")

print("Loop Composer smoke tests passed")
