-- @noindex

SECTION = "KRGSH_LOOP_COMPOSER"
DEFAULT_BARS = 8
BAR_CHOICES = { 1, 2, 4, 8, 16, 32, 64 }
BEAT_CHOICES = { 1, 2 }
EDGE_EPSILON = 0.05
LOOPSTATION_STOP_KEY = "loopstation_stop_requested"
LOOPSTATION_QUEUE_KEY = "loopstation_queue_state"
LAST_TAKE_GUIDS_KEY = "last_loopstation_take_guids"
REPLACE_AND_QUEUE_KEY = "replace_and_queue_requested"
LOOPSTATION_TARGET_KEY = "loopstation_target_guid"
DOCK_STATE_KEY = "view_dock_state"
RECORD_DUB_KEY = "recorddub_enabled"
TARGET_TRACKS_KEY = "target_tracks"
MIDI_MAP_PREFIX = "midi_map_"
MIDI_OVERDUB_RECMODE = 7
RECENT_MIDI_EVENT_LIMIT = 512

function project()
  return 0
end

function get_ext(key, default)
  local ok, value = reaper.GetProjExtState(project(), SECTION, key)
  if ok == 1 and value ~= "" then
    return value
  end
  return default
end

function set_ext(key, value)
  reaper.SetProjExtState(project(), SECTION, key, tostring(value))
end

function clear_ext(key)
  reaper.SetProjExtState(project(), SECTION, key, "")
end

function split_lines(value)
  local lines = {}
  for line in tostring(value or ""):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end


function loopstation_stop_requested()
  return get_ext(LOOPSTATION_STOP_KEY, "") == "1"
end

function loopstation_queue_state()
  return get_ext(LOOPSTATION_QUEUE_KEY, "")
end

function loopstation_target_guid()
  return get_ext(LOOPSTATION_TARGET_KEY, "")
end

function replace_and_queue_requested()
  return get_ext(REPLACE_AND_QUEUE_KEY, "") == "1"
end

function measure_at_time(time)
  local _, measure = reaper.TimeMap2_timeToBeats(project(), time)
  return measure
end

function time_at_measure(measure)
  if measure < 0 then
    measure = 0
  end
  return reaper.TimeMap2_beatsToTime(project(), 0, measure)
end

function time_at_measure_beat(measure, beat)
  if measure < 0 then
    measure = 0
  end
  return reaper.TimeMap2_beatsToTime(project(), beat, measure)
end

function precise_time()
  if reaper.time_precise then
    return reaper.time_precise()
  end
  return os.clock()
end

function current_bars()
  local bars = tonumber(get_ext("loop_bars", DEFAULT_BARS)) or DEFAULT_BARS
  if bars ~= 4 and bars ~= 8 and bars ~= 16 and bars ~= 32 and bars ~= 64 then
    bars = DEFAULT_BARS
  end
  return bars
end

function current_start()
  local saved = tonumber(get_ext("block_start", ""))
  if saved then
    return saved
  end

  local cursor = reaper.GetCursorPositionEx(project())
  local start_time = time_at_measure(measure_at_time(cursor))
  set_ext("block_start", start_time)
  return start_time
end

function block_end(start_time, bars)
  return time_at_measure(measure_at_time(start_time) + bars)
end

function set_loop_range(start_time, end_time, move_cursor)
  reaper.GetSet_LoopTimeRange2(project(), true, true, start_time, end_time, false)
  reaper.GetSet_LoopTimeRange2(project(), true, false, start_time, end_time, false)
  if move_cursor then
    reaper.SetEditCurPos2(project(), start_time, true, false)
  end
end

function apply_current_loop(move_cursor)
  local bars = current_bars()
  local start_time = current_start()
  set_loop_range(start_time, block_end(start_time, bars), move_cursor)
end

function save_block_start(start_time)
  local snapped = time_at_measure(measure_at_time(start_time))
  set_ext("block_start", snapped)
  return snapped
end

function source_end_for_duration(start_time, end_time, max_bars)
  local chosen_end = nil
  local start_measure = measure_at_time(start_time)
  local epsilon = 0.03

  for _, beats in ipairs(BEAT_CHOICES) do
    local candidate_end = time_at_measure_beat(start_measure, beats)
    if candidate_end <= end_time + epsilon then
      chosen_end = candidate_end
    end
  end

  for _, bars in ipairs(BAR_CHOICES) do
    if bars <= max_bars then
      local candidate_end = time_at_measure(start_measure + bars)
      if candidate_end <= end_time + epsilon then
        chosen_end = candidate_end
      end
    end
  end

  return chosen_end or time_at_measure_beat(start_measure, BEAT_CHOICES[1])
end


function sws_available()
  return reaper.APIExists and reaper.APIExists("CF_GetSWSVersion") and reaper.APIExists("BR_SetArrangeView")
end

function sws_version()
  if reaper.APIExists and reaper.APIExists("CF_GetSWSVersion") then
    return reaper.CF_GetSWSVersion()
  end
  return nil
end

function format_position(time)
  return reaper.format_timestr_pos(time, "", 2)
end
