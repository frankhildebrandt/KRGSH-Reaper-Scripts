-- @noindex

local M = {}

local SECTION = "KRGSH_LOOP_COMPOSER"
local DEFAULT_BARS = 8
local BAR_CHOICES = { 1, 2, 4, 8, 16, 32, 64 }
local BEAT_CHOICES = { 1, 2 }
local EDGE_EPSILON = 0.05
local LOOPSTATION_STOP_KEY = "loopstation_stop_requested"
local LOOPSTATION_QUEUE_KEY = "loopstation_queue_state"
local LAST_TAKE_GUIDS_KEY = "last_loopstation_take_guids"
local REPLACE_AND_QUEUE_KEY = "replace_and_queue_requested"
local LOOPSTATION_TARGET_KEY = "loopstation_target_guid"
local DOCK_STATE_KEY = "view_dock_state"
local RECORD_DUB_KEY = "recorddub_enabled"
local TARGET_TRACKS_KEY = "target_tracks"
local MIDI_MAP_PREFIX = "midi_map_"
local MIDI_OVERDUB_RECMODE = 7
local recorddub_enabled

local function project()
  return 0
end

local function get_ext(key, default)
  local ok, value = reaper.GetProjExtState(project(), SECTION, key)
  if ok == 1 and value ~= "" then
    return value
  end
  return default
end

local function set_ext(key, value)
  reaper.SetProjExtState(project(), SECTION, key, tostring(value))
end

local function clear_ext(key)
  reaper.SetProjExtState(project(), SECTION, key, "")
end

local function split_lines(value)
  local lines = {}
  for line in tostring(value or ""):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

local function track_guid(track)
  if not track or not reaper.ValidatePtr2(project(), track, "MediaTrack*") then
    return ""
  end
  if reaper.GetTrackGUID then
    return reaper.GetTrackGUID(track)
  end
  local ok, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
  if ok then
    return guid
  end
  return ""
end

local function track_by_guid(guid)
  local count = reaper.CountTracks(project())
  for i = 0, count - 1 do
    local track = reaper.GetTrack(project(), i)
    if track_guid(track) == guid then
      return track
    end
  end
  return nil
end

local function track_name(track)
  if not track or not reaper.ValidatePtr2(project(), track, "MediaTrack*") then
    return "Missing track"
  end
  local _, name = reaper.GetTrackName(track, "")
  if name == "" then
    local index = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0)
    name = "Track " .. tostring(index)
  end
  return name
end

local function arm_track(track)
  if reaper.ValidatePtr2(project(), track, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
    if recorddub_enabled and recorddub_enabled() then
      reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", MIDI_OVERDUB_RECMODE)
    end
  end
end

local function disarm_all_tracks_except(allowed)
  allowed = allowed or {}
  local count = reaper.CountTracks(project())
  for i = 0, count - 1 do
    local track = reaper.GetTrack(project(), i)
    if not allowed[tostring(track)] then
      reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 0)
    end
  end
end

local function arm_tracks_exclusive(tracks)
  local allowed = {}
  for _, track in ipairs(tracks or {}) do
    if reaper.ValidatePtr2(project(), track, "MediaTrack*") then
      allowed[tostring(track)] = true
    end
  end

  disarm_all_tracks_except(allowed)
  for _, track in ipairs(tracks or {}) do
    arm_track(track)
  end
  reaper.UpdateArrange()
end

local function loopstation_stop_requested()
  return get_ext(LOOPSTATION_STOP_KEY, "") == "1"
end

local function loopstation_queue_state()
  return get_ext(LOOPSTATION_QUEUE_KEY, "")
end

local function loopstation_target_guid()
  return get_ext(LOOPSTATION_TARGET_KEY, "")
end

local function replace_and_queue_requested()
  return get_ext(REPLACE_AND_QUEUE_KEY, "") == "1"
end

local function measure_at_time(time)
  local _, measure = reaper.TimeMap2_timeToBeats(project(), time)
  return measure
end

local function time_at_measure(measure)
  if measure < 0 then
    measure = 0
  end
  return reaper.TimeMap2_beatsToTime(project(), 0, measure)
end

local function time_at_measure_beat(measure, beat)
  if measure < 0 then
    measure = 0
  end
  return reaper.TimeMap2_beatsToTime(project(), beat, measure)
end

local function time_one_beat_before(time)
  local qn = reaper.TimeMap2_timeToQN(project(), time)
  return reaper.TimeMap2_QNToTime(project(), math.max(0, qn - 1))
end

local function current_bars()
  local bars = tonumber(get_ext("loop_bars", DEFAULT_BARS)) or DEFAULT_BARS
  if bars ~= 4 and bars ~= 8 and bars ~= 16 and bars ~= 32 and bars ~= 64 then
    bars = DEFAULT_BARS
  end
  return bars
end

local function current_start()
  local saved = tonumber(get_ext("block_start", ""))
  if saved then
    return saved
  end

  local cursor = reaper.GetCursorPositionEx(project())
  local start_time = time_at_measure(measure_at_time(cursor))
  set_ext("block_start", start_time)
  return start_time
end

local function block_end(start_time, bars)
  return time_at_measure(measure_at_time(start_time) + bars)
end

local function set_loop_range(start_time, end_time, move_cursor)
  reaper.GetSet_LoopTimeRange2(project(), true, true, start_time, end_time, false)
  reaper.GetSet_LoopTimeRange2(project(), true, false, start_time, end_time, false)
  if move_cursor then
    reaper.SetEditCurPos2(project(), start_time, true, false)
  end
end

local function apply_current_loop(move_cursor)
  local bars = current_bars()
  local start_time = current_start()
  set_loop_range(start_time, block_end(start_time, bars), move_cursor)
end

local function save_block_start(start_time)
  local snapped = time_at_measure(measure_at_time(start_time))
  set_ext("block_start", snapped)
  return snapped
end

local function source_end_for_duration(start_time, end_time, max_bars)
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

local function item_guid(item)
  local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if ok then
    return guid
  end
  return ""
end

local function snapshot_item_guids()
  local guids = {}
  local count = reaper.CountMediaItems(project())
  for i = 0, count - 1 do
    guids[item_guid(reaper.GetMediaItem(project(), i))] = true
  end
  return guids
end

local function encode_guids(guids)
  return table.concat(guids, "\n")
end

local function decode_guids(value)
  local guids = {}
  for guid in tostring(value or ""):gmatch("[^\n]+") do
    guids[guid] = true
  end
  return guids
end

local function item_range(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len
end

local function overlaps(start_a, end_a, start_b, end_b)
  return start_a < end_b and end_a > start_b
end

local function collect_new_items(initial_guids, start_time, end_time)
  local items = {}
  local count = reaper.CountMediaItems(project())
  for i = 0, count - 1 do
    local item = reaper.GetMediaItem(project(), i)
    local guid = item_guid(item)
    local item_start, item_end = item_range(item)
    if not initial_guids[guid] and overlaps(item_start, item_end, start_time, end_time) then
      items[#items + 1] = item
    end
  end
  return items
end

local function store_last_loopstation_take(items)
  local guids = {}
  for _, item in ipairs(items or {}) do
    if reaper.ValidatePtr2(project(), item, "MediaItem*") then
      guids[#guids + 1] = item_guid(item)
    end
  end

  if #guids > 0 then
    set_ext(LAST_TAKE_GUIDS_KEY, encode_guids(guids))
  else
    clear_ext(LAST_TAKE_GUIDS_KEY)
  end
end

local function select_only_item(item)
  reaper.SelectAllMediaItems(project(), false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()
end

local function trim_item_to_start(item, start_time)
  local item_start, item_end = item_range(item)
  if item_end <= start_time then
    return nil
  end

  if item_start < start_time - 0.001 then
    local right_item = reaper.SplitMediaItem(item, start_time)
    if right_item then
      local track = reaper.GetMediaItem_Track(item)
      reaper.DeleteTrackMediaItem(track, item)
      return right_item
    end
  end

  return item
end

local function glue_item_to_exact_length(item, start_time, source_end)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local source_len = math.max(0.001, source_end - item_start)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", source_len)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  select_only_item(item)
  reaper.Main_OnCommand(40362, 0) -- Item: Glue items, ignoring time selection

  local glued = reaper.GetSelectedMediaItem(project(), 0)
  return glued or item
end

local function normalize_new_items(initial_guids, start_time, end_time, stopped_at, discard_preroll_tail_from)
  local new_items = collect_new_items(initial_guids, start_time, end_time)
  if #new_items == 0 then
    return {}
  end

  local recorded_end = stopped_at
  local trim_candidates = {}
  local discard_from = discard_preroll_tail_from or math.huge
  for _, item in ipairs(new_items) do
    if reaper.ValidatePtr2(project(), item, "MediaItem*") then
      local item_start, item_end = item_range(item)
      if item_start >= discard_from - 0.001 then
        local track = reaper.GetMediaItem_Track(item)
        reaper.DeleteTrackMediaItem(track, item)
      else
        trim_candidates[#trim_candidates + 1] = item
        if item_end > recorded_end then
          recorded_end = item_end
        end
      end
    end
  end

  if #trim_candidates == 0 then
    reaper.UpdateArrange()
    return {}
  end

  local max_bars = current_bars()
  local source_end = source_end_for_duration(start_time, recorded_end, max_bars)

  local normalized_items = {}
  reaper.PreventUIRefresh(1)
  for _, item in ipairs(trim_candidates) do
    if reaper.ValidatePtr2(project(), item, "MediaItem*") then
      local trimmed = trim_item_to_start(item, start_time)
      local glued = nil
      if trimmed and reaper.ValidatePtr2(project(), trimmed, "MediaItem*") then
        glued = glue_item_to_exact_length(trimmed, start_time, source_end)
      end
      if glued and reaper.ValidatePtr2(project(), glued, "MediaItem*") then
        local item_start = reaper.GetMediaItemInfo_Value(glued, "D_POSITION")
        local full_len = math.max(0.001, end_time - item_start)
        reaper.SetMediaItemInfo_Value(glued, "B_LOOPSRC", 1)
        reaper.SetMediaItemInfo_Value(glued, "D_LENGTH", full_len)
        reaper.SetMediaItemSelected(glued, true)
        normalized_items[#normalized_items + 1] = glued
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  return normalized_items
end

local function collect_items_in_block(start_time, end_time)
  local items = {}
  local count = reaper.CountMediaItems(project())
  for i = 0, count - 1 do
    local item = reaper.GetMediaItem(project(), i)
    local item_start, item_end = item_range(item)
    if overlaps(item_start, item_end, start_time, end_time) then
      items[#items + 1] = item
    end
  end
  return items
end

local function duplicate_items_to_block(items, offset)
  reaper.SelectAllMediaItems(project(), false)

  for _, item in ipairs(items) do
    if reaper.ValidatePtr2(project(), item, "MediaItem*") then
      local track = reaper.GetMediaItem_Track(item)
      local ok, chunk = reaper.GetItemStateChunk(item, "", false)
      if ok then
        chunk = chunk:gsub("\nGUID%s+%b{}\n", "\n")
        local new_item = reaper.AddMediaItemToTrack(track)
        reaper.SetItemStateChunk(new_item, chunk, false)
        local new_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION") + offset
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", new_pos)
        reaper.SetMediaItemSelected(new_item, true)
      end
    end
  end

  reaper.UpdateArrange()
end

local function delete_items_by_guids(guids, start_time, end_time)
  local deleted = 0
  local count = reaper.CountMediaItems(project())
  for i = count - 1, 0, -1 do
    local item = reaper.GetMediaItem(project(), i)
    local guid = item_guid(item)
    local item_start, item_end = item_range(item)
    if guids[guid] and overlaps(item_start, item_end, start_time, end_time) then
      local track = reaper.GetMediaItem_Track(item)
      reaper.DeleteTrackMediaItem(track, item)
      deleted = deleted + 1
    end
  end

  if deleted > 0 then
    reaper.UpdateArrange()
  end

  return deleted
end

local function sws_available()
  return reaper.APIExists and reaper.APIExists("CF_GetSWSVersion") and reaper.APIExists("BR_SetArrangeView")
end

local function sws_version()
  if reaper.APIExists and reaper.APIExists("CF_GetSWSVersion") then
    return reaper.CF_GetSWSVersion()
  end
  return nil
end

local function format_position(time)
  return reaper.format_timestr_pos(time, "", 2)
end

function recorddub_enabled()
  return get_ext(RECORD_DUB_KEY, "0") == "1"
end

local function decode_target_tracks()
  local slots = {}
  for _, line in ipairs(split_lines(get_ext(TARGET_TRACKS_KEY, ""))) do
    local guid, enabled = line:match("^([^|]+)|([^|]+)$")
    if guid and guid ~= "" then
      slots[#slots + 1] = {
        guid = guid,
        enabled = enabled ~= "0",
      }
    end
  end
  return slots
end

local function encode_target_tracks(slots)
  local lines = {}
  for _, slot in ipairs(slots or {}) do
    if slot.guid and slot.guid ~= "" then
      lines[#lines + 1] = slot.guid .. "|" .. (slot.enabled and "1" or "0")
    end
  end
  return table.concat(lines, "\n")
end

local function active_target_tracks()
  local tracks = {}
  for _, slot in ipairs(decode_target_tracks()) do
    if slot.enabled then
      local track = track_by_guid(slot.guid)
      if track then
        tracks[#tracks + 1] = track
      end
    end
  end
  return tracks
end

local function recorddub_tracks()
  local tracks = active_target_tracks()
  if #tracks > 0 then
    return tracks
  end

  local selected = {}
  local count = reaper.CountSelectedTracks(project())
  for i = 0, count - 1 do
    selected[#selected + 1] = reaper.GetSelectedTrack(project(), i)
  end
  return selected
end

local function apply_recorddub_to_tracks()
  if not recorddub_enabled() then
    return
  end

  for _, track in ipairs(recorddub_tracks()) do
    if reaper.ValidatePtr2(project(), track, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", MIDI_OVERDUB_RECMODE)
    end
  end
end

local function begin_target_recording_context(targets)
  targets = targets or active_target_tracks()
  if #targets == 0 then
    apply_recorddub_to_tracks()
    return { restore = function() end }
  end

  arm_tracks_exclusive(targets)

  local track_count = reaper.CountTracks(project())
  local states = {}
  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(project(), i)
    states[#states + 1] = {
      track = track,
      selected = reaper.IsTrackSelected(track),
      recarm = reaper.GetMediaTrackInfo_Value(track, "I_RECARM"),
      recmode = reaper.GetMediaTrackInfo_Value(track, "I_RECMODE"),
    }
    reaper.SetTrackSelected(track, false)
  end

  for _, track in ipairs(targets) do
    reaper.SetTrackSelected(track, true)
  end

  return {
    restore = function()
      for _, state in ipairs(states) do
        if reaper.ValidatePtr2(project(), state.track, "MediaTrack*") then
          reaper.SetTrackSelected(state.track, state.selected)
          reaper.SetMediaTrackInfo_Value(state.track, "I_RECARM", state.recarm)
          if not recorddub_enabled() then
            reaper.SetMediaTrackInfo_Value(state.track, "I_RECMODE", state.recmode)
          end
        end
      end
      reaper.UpdateArrange()
    end,
  }
end

local function midi_mapping_key(control_id)
  return MIDI_MAP_PREFIX .. tostring(control_id or "")
end

local function parse_midi_mapping(value)
  local event_type, channel, number = tostring(value or ""):match("^([^:]+):(%d+):(%d+)$")
  if not event_type then
    return nil
  end
  return {
    type = event_type,
    channel = tonumber(channel),
    number = tonumber(number),
  }
end

local function encode_midi_mapping(event)
  if not event then
    return ""
  end
  return table.concat({ event.type, event.channel, event.number }, ":")
end

local function midi_event_label(event)
  if not event then
    return ""
  end
  local kind = event.type == "cc" and "CC" or "Note"
  return kind .. " " .. tostring(event.number) .. " ch " .. tostring((event.channel or 0) + 1)
end

local function recent_midi_event()
  if not reaper.MIDI_GetRecentInputEvent then
    return nil
  end

  local ok, retval, msg, timestamp, device, project_pos, project_loop_count = pcall(reaper.MIDI_GetRecentInputEvent, 0)
  if not ok or not retval or retval == 0 or not msg or #msg < 2 then
    return nil
  end

  local status = msg:byte(1)
  local data1 = msg:byte(2) or 0
  local data2 = msg:byte(3) or 0
  local message_type = status & 0xF0
  local channel = status & 0x0F
  local event = nil

  if message_type == 0xB0 then
    event = { type = "cc", channel = channel, number = data1, value = data2 }
  elseif message_type == 0x90 and data2 > 0 then
    event = { type = "note", channel = channel, number = data1, value = data2 }
  end

  if not event then
    return nil
  end

  event.fingerprint = table.concat({
    tostring(retval),
    tostring(timestamp or ""),
    tostring(device or ""),
    tostring(project_pos or ""),
    tostring(project_loop_count or ""),
    tostring(status),
    tostring(data1),
    tostring(data2),
  }, ":")
  event.label = midi_event_label(event)
  return event
end

local function mapping_matches(mapping, event)
  return mapping and event and
    mapping.type == event.type and
    mapping.channel == event.channel and
    mapping.number == event.number
end

local function loop_status()
  local bars = current_bars()
  local start_time = current_start()
  local end_time = block_end(start_time, bars)
  local start_measure = measure_at_time(start_time) + 1
  local end_measure = measure_at_time(end_time)
  local play_state = reaper.GetPlayStateEx(project())
  local play_pos = reaper.GetPlayPositionEx(project())
  local progress = 0
  if end_time > start_time then
    progress = (play_pos - start_time) / (end_time - start_time)
    if progress < 0 then
      progress = 0
    elseif progress > 1 then
      progress = 1
    end
  end

  return {
    bars = bars,
    start_time = start_time,
    end_time = end_time,
    play_position = play_pos,
    play_position_text = format_position(play_pos),
    progress = progress,
    start_position = format_position(start_time),
    end_position = format_position(end_time),
    start_measure = start_measure,
    end_measure = end_measure,
    is_playing = (play_state & 1) == 1,
    is_paused = (play_state & 2) == 2,
    is_recording = (play_state & 4) == 4,
    repeat_enabled = reaper.GetSetRepeat(-1) == 1,
    sws_available = sws_available(),
    sws_version = sws_version(),
    recorddub_enabled = recorddub_enabled(),
    loopstation_queue_state = loopstation_queue_state(),
    loopstation_queued = loopstation_queue_state() ~= "",
    loopstation_target_guid = loopstation_target_guid(),
  }
end

function M.set_length(bars)
  reaper.Undo_BeginBlock2(project())
  set_ext("loop_bars", bars)
  apply_current_loop(true)
  reaper.Undo_EndBlock2(project(), "Loop Composer: set loop length to " .. bars .. " bars", -1)
end

function M.set_current_block_from_cursor()
  reaper.Undo_BeginBlock2(project())
  local start_time = save_block_start(reaper.GetCursorPositionEx(project()))
  set_loop_range(start_time, block_end(start_time, current_bars()), true)
  reaper.Undo_EndBlock2(project(), "Loop Composer: set current loop block from edit cursor", -1)
end

function M.navigate(direction)
  reaper.Undo_BeginBlock2(project())
  local bars = current_bars()
  local start_measure = measure_at_time(current_start()) + (direction * bars)
  local start_time = save_block_start(time_at_measure(start_measure))
  set_loop_range(start_time, block_end(start_time, bars), true)
  reaper.Undo_EndBlock2(project(), "Loop Composer: go to " .. (direction < 0 and "previous" or "next") .. " loop block", -1)
end

function M.create_next_block()
  reaper.Undo_BeginBlock2(project())
  local bars = current_bars()
  local start_time = current_start()
  local end_time = block_end(start_time, bars)
  local items = collect_items_in_block(start_time, end_time)

  local next_start = time_at_measure(measure_at_time(start_time) + bars)
  local next_end = block_end(next_start, bars)
  local offset = next_start - start_time

  if #items > 0 then
    duplicate_items_to_block(items, offset)
  end

  save_block_start(next_start)
  set_loop_range(next_start, next_end, true)

  reaper.Undo_EndBlock2(project(), "Loop Composer: create next loop block from current", -1)
end

function M.start_loop_recording()
  local bars = current_bars()
  local start_time = current_start()
  local prerecord_time = time_one_beat_before(start_time)
  local end_time = block_end(start_time, bars)
  local record_context = begin_target_recording_context()
  local initial_guids = snapshot_item_guids()
  local finalized = false
  local last_pos = reaper.GetPlayPositionEx(project())

  set_loop_range(start_time, end_time, false)
  reaper.SetEditCurPos2(project(), prerecord_time, true, false)
  reaper.GetSetRepeat(1)
  reaper.Main_OnCommand(1013, 0) -- Transport: Record
  last_pos = prerecord_time

  local function finalize(stopped_at)
    if finalized then
      return
    end
    finalized = true
    reaper.Undo_BeginBlock2(project())
    normalize_new_items(
      initial_guids,
      start_time,
      end_time,
      stopped_at or reaper.GetCursorPositionEx(project())
    )
    set_loop_range(start_time, end_time, false)
    reaper.Undo_EndBlock2(project(), "Loop Composer: loop recording", -1)
    record_context.restore()
  end

  local function watch()
    local state = reaper.GetPlayStateEx(project())
    local is_recording = (state & 4) == 4
    local play_pos = reaper.GetPlayPositionEx(project())
    local reached_end = play_pos >= end_time - 0.02 or play_pos < last_pos - 0.02

    if is_recording and reached_end then
      reaper.Main_OnCommand(1016, 0) -- Transport: Stop
      finalize(end_time)
      return
    end

    if not is_recording then
      finalize(reaper.GetCursorPositionEx(project()))
      return
    end

    last_pos = play_pos
    reaper.defer(watch)
  end

  reaper.defer(watch)
end

function M.start_loopstation_mode()
  reaper.Undo_BeginBlock2(project())
  local start_time = current_start()
  set_loop_range(start_time, block_end(start_time, current_bars()), true)
  reaper.GetSetRepeat(1)

  local state = reaper.GetPlayStateEx(project())
  if (state & 1) ~= 1 then
    reaper.Main_OnCommand(1007, 0) -- Transport: Play
  end

  reaper.Undo_EndBlock2(project(), "Loop Composer: start loopstation mode", -1)
end

function M.queue_loopstation_recording(target_track)
  local bars = current_bars()
  local start_time = current_start()
  local prerecord_time = time_one_beat_before(start_time)
  local end_time = block_end(start_time, bars)
  local loop_prerecord_time = time_one_beat_before(end_time)
  local initial_guids = nil
  local record_context = nil
  local recording_started = false
  local recording_started_from_loop_preroll = false
  local recording_reached_block_start = false
  local finalized = false
  local last_pos = reaper.GetPlayPositionEx(project())
  local target_tracks = nil
  local target_guid = ""

  if target_track and reaper.ValidatePtr2(project(), target_track, "MediaTrack*") then
    target_tracks = { target_track }
    target_guid = track_guid(target_track)
  end

  clear_ext(LOOPSTATION_STOP_KEY)
  clear_ext(REPLACE_AND_QUEUE_KEY)
  if target_guid ~= "" then
    set_ext(LOOPSTATION_TARGET_KEY, target_guid)
  else
    clear_ext(LOOPSTATION_TARGET_KEY)
  end
  set_ext(LOOPSTATION_QUEUE_KEY, "queued")
  set_loop_range(start_time, end_time, false)
  reaper.GetSetRepeat(1)

  local state = reaper.GetPlayStateEx(project())
  if (state & 1) ~= 1 then
    reaper.SetEditCurPos2(project(), prerecord_time, true, false)
    record_context = begin_target_recording_context(target_tracks)
    initial_guids = snapshot_item_guids()
    set_ext(LOOPSTATION_QUEUE_KEY, "recording")
    recording_started = true
    recording_reached_block_start = true
    reaper.Main_OnCommand(1013, 0) -- Transport: Record
    last_pos = prerecord_time
  elseif last_pos < start_time or last_pos >= end_time then
    reaper.SetEditCurPos2(project(), start_time, true, false)
    last_pos = start_time
  end

  local function finalize(stopped_at)
    if finalized then
      return
    end
    finalized = true
    clear_ext(LOOPSTATION_STOP_KEY)
    clear_ext(LOOPSTATION_QUEUE_KEY)
    clear_ext(LOOPSTATION_TARGET_KEY)

    if initial_guids then
      reaper.Undo_BeginBlock2(project())
      local discard_preroll_tail_from = recording_started_from_loop_preroll and loop_prerecord_time or nil
      local items = normalize_new_items(
        initial_guids,
        start_time,
        end_time,
        stopped_at or reaper.GetCursorPositionEx(project()),
        discard_preroll_tail_from
      )
      store_last_loopstation_take(items)
      set_loop_range(start_time, end_time, false)
      reaper.Undo_EndBlock2(project(), "Loop Composer: loopstation recording", -1)
    end

    if record_context then
      record_context.restore()
    end

    if replace_and_queue_requested() then
      clear_ext(REPLACE_AND_QUEUE_KEY)
      M.replace_and_queue_loopstation_recording()
    end
  end

  local function at_loop_start(play_pos)
    return play_pos <= start_time + EDGE_EPSILON or play_pos < last_pos - EDGE_EPSILON
  end

  local function at_loop_prerecord_start(play_pos)
    return play_pos >= loop_prerecord_time - EDGE_EPSILON or play_pos < last_pos - EDGE_EPSILON
  end

  local function watch()
    local play_state = reaper.GetPlayStateEx(project())
    local is_playing = (play_state & 1) == 1
    local is_recording = (play_state & 4) == 4
    local play_pos = reaper.GetPlayPositionEx(project())
    local stop_requested = loopstation_stop_requested()

    if not is_playing and not is_recording then
      finalize(reaper.GetCursorPositionEx(project()))
      return
    end

    if stop_requested then
      if is_recording then
        reaper.Main_OnCommand(1007, 0) -- Transport: Play
      end
      finalize(play_pos)
      return
    end

    if not recording_started and at_loop_prerecord_start(play_pos) then
      record_context = begin_target_recording_context(target_tracks)
      initial_guids = snapshot_item_guids()
      set_ext(LOOPSTATION_QUEUE_KEY, "recording")
      recording_started = true
      recording_started_from_loop_preroll = true
      reaper.Main_OnCommand(1013, 0) -- Transport: Record
      last_pos = play_pos
      reaper.defer(watch)
      return
    end

    if recording_started and recording_started_from_loop_preroll and at_loop_start(play_pos) then
      recording_reached_block_start = true
    end

    if recording_started and is_recording and recording_reached_block_start and play_pos >= end_time - EDGE_EPSILON then
      reaper.Main_OnCommand(1007, 0) -- Transport: Play
      finalize(end_time)
      return
    end

    if recording_started and not is_recording then
      finalize(reaper.GetCursorPositionEx(project()))
      return
    end

    last_pos = play_pos
    reaper.defer(watch)
  end

  reaper.defer(watch)
end

function M.stop_loopstation_recording()
  set_ext(LOOPSTATION_STOP_KEY, "1")
  clear_ext(LOOPSTATION_QUEUE_KEY)
  clear_ext(LOOPSTATION_TARGET_KEY)

  local state = reaper.GetPlayStateEx(project())
  local is_recording = (state & 4) == 4
  if is_recording then
    reaper.Main_OnCommand(1007, 0) -- Transport: Play
  end
end

function M.replace_and_queue_loopstation_recording()
  local state = reaper.GetPlayStateEx(project())
  if (state & 4) == 4 then
    set_ext(REPLACE_AND_QUEUE_KEY, "1")
    M.stop_loopstation_recording()
    return
  end

  local bars = current_bars()
  local start_time = current_start()
  local end_time = block_end(start_time, bars)
  local guids = decode_guids(get_ext(LAST_TAKE_GUIDS_KEY, ""))

  reaper.Undo_BeginBlock2(project())
  delete_items_by_guids(guids, start_time, end_time)
  clear_ext(LAST_TAKE_GUIDS_KEY)
  reaper.Undo_EndBlock2(project(), "Loop Composer: replace last loopstation take", -1)

  M.queue_loopstation_recording()
end

function M.apply_current_loop()
  reaper.Undo_BeginBlock2(project())
  apply_current_loop(true)
  reaper.Undo_EndBlock2(project(), "Loop Composer: apply current loop block", -1)
end

function M.play()
  reaper.Main_OnCommand(1007, 0) -- Transport: Play
end

function M.stop()
  reaper.Main_OnCommand(1016, 0) -- Transport: Stop
end

function M.pause()
  reaper.Main_OnCommand(1008, 0) -- Transport: Pause
end

function M.record()
  reaper.Main_OnCommand(1013, 0) -- Transport: Record
end

function M.toggle_repeat()
  reaper.GetSetRepeat(reaper.GetSetRepeat(-1) == 1 and 0 or 1)
end

function M.jump_block_start()
  reaper.SetEditCurPos2(project(), current_start(), true, false)
end

function M.jump_block_end()
  reaper.SetEditCurPos2(project(), block_end(current_start(), current_bars()), true, false)
end

function M.dock_state()
  return tonumber(get_ext(DOCK_STATE_KEY, "0")) or 0
end

function M.set_dock_state(state)
  set_ext(DOCK_STATE_KEY, tonumber(state) or 0)
end

function M.toggle_recorddub()
  local enabled = not recorddub_enabled()
  set_ext(RECORD_DUB_KEY, enabled and "1" or "0")
  if enabled then
    apply_recorddub_to_tracks()
  end
  return enabled
end

function M.set_recorddub(enabled)
  set_ext(RECORD_DUB_KEY, enabled and "1" or "0")
  if enabled then
    apply_recorddub_to_tracks()
  end
end

function M.target_tracks()
  local tracks = {}
  local active_loopstation_target = loopstation_target_guid()
  for index, slot in ipairs(decode_target_tracks()) do
    local track = track_by_guid(slot.guid)
    tracks[#tracks + 1] = {
      index = index,
      guid = slot.guid,
      exists = track ~= nil,
      enabled = slot.enabled,
      name = track_name(track),
      track_number = track and math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0) or 0,
      loopstation_active = active_loopstation_target ~= "" and active_loopstation_target == slot.guid,
    }
  end
  return tracks
end

function M.set_target_tracks_from_selection()
  local slots = {}
  local tracks = {}
  local count = reaper.CountSelectedTracks(project())
  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(project(), i)
    local guid = track_guid(track)
    if guid ~= "" then
      slots[#slots + 1] = { guid = guid, enabled = true }
      tracks[#tracks + 1] = track
    end
  end
  set_ext(TARGET_TRACKS_KEY, encode_target_tracks(slots))
  arm_tracks_exclusive(tracks)
  return #slots
end

function M.clear_target_tracks()
  clear_ext(TARGET_TRACKS_KEY)
end

function M.toggle_target_track(index)
  local slots = decode_target_tracks()
  local slot = slots[index]
  if slot then
    slot.enabled = not slot.enabled
    set_ext(TARGET_TRACKS_KEY, encode_target_tracks(slots))
  end
end

function M.select_target_track(index)
  local slots = decode_target_tracks()
  local slot = slots[index]
  if not slot then
    return false
  end

  local track = track_by_guid(slot.guid)
  if not track then
    return false
  end

  local count = reaper.CountTracks(project())
  for i = 0, count - 1 do
    reaper.SetTrackSelected(reaper.GetTrack(project(), i), false)
  end
  reaper.SetTrackSelected(track, true)
  reaper.SetOnlyTrackSelected(track)
  arm_tracks_exclusive({ track })
  reaper.UpdateArrange()
  return true
end

function M.toggle_target_loopstation_recording(index)
  local slots = decode_target_tracks()
  local slot = slots[index]
  if not slot then
    return false, "Target track missing"
  end

  local track = track_by_guid(slot.guid)
  if not track then
    return false, "Target track not found"
  end

  if loopstation_queue_state() ~= "" then
    M.stop_loopstation_recording()
    return true, "Recording stop requested"
  end

  M.select_target_track(index)
  M.queue_loopstation_recording(track)
  return true, "Recording queued for " .. track_name(track)
end

function M.recent_midi_event()
  return recent_midi_event()
end

function M.get_midi_mapping(control_id)
  local mapping = parse_midi_mapping(get_ext(midi_mapping_key(control_id), ""))
  if mapping then
    mapping.label = midi_event_label(mapping)
  end
  return mapping
end

function M.set_midi_mapping(control_id, event)
  set_ext(midi_mapping_key(control_id), encode_midi_mapping(event))
end

function M.reset_midi_mapping(control_id)
  clear_ext(midi_mapping_key(control_id))
end

function M.midi_mapping_label(control_id)
  local mapping = M.get_midi_mapping(control_id)
  return mapping and mapping.label or ""
end

function M.midi_event_matches(control_id, event)
  return mapping_matches(M.get_midi_mapping(control_id), event)
end

function M.status()
  return loop_status()
end

function M.focus_current_block()
  if not sws_available() then
    return false, "SWS extension is not available."
  end

  local status = loop_status()
  local left = math.max(0, status.start_time - ((status.end_time - status.start_time) * 0.08))
  local right = status.end_time + ((status.end_time - status.start_time) * 0.08)

  reaper.BR_SetArrangeView(project(), left, right)
  reaper.UpdateArrange()
  return true
end

return M
