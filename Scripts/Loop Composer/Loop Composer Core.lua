-- @noindex

local M = {}

local SECTION = "KRGSH_LOOP_COMPOSER"
local DEFAULT_BARS = 8
local BAR_CHOICES = { 1, 2, 4, 8, 16, 32, 64 }
local EDGE_EPSILON = 0.05
local LOOPSTATION_STOP_KEY = "loopstation_stop_requested"
local LAST_TAKE_GUIDS_KEY = "last_loopstation_take_guids"
local REPLACE_AND_QUEUE_KEY = "replace_and_queue_requested"

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

local function loopstation_stop_requested()
  return get_ext(LOOPSTATION_STOP_KEY, "") == "1"
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

local function source_bars_for_duration(start_time, end_time, max_bars)
  local chosen = 1
  local start_measure = measure_at_time(start_time)
  local epsilon = 0.03

  for _, bars in ipairs(BAR_CHOICES) do
    if bars <= max_bars then
      local candidate_end = time_at_measure(start_measure + bars)
      if candidate_end <= end_time + epsilon then
        chosen = bars
      end
    end
  end

  return chosen
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

local function glue_item_to_exact_length(item, start_time, source_end)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  if math.abs(item_start - start_time) < 0.03 then
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", start_time)
    item_start = start_time
  end

  local source_len = math.max(0.001, source_end - item_start)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", source_len)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  select_only_item(item)
  reaper.Main_OnCommand(40362, 0) -- Item: Glue items, ignoring time selection

  local glued = reaper.GetSelectedMediaItem(project(), 0)
  return glued or item
end

local function normalize_new_items(initial_guids, start_time, end_time, stopped_at)
  local new_items = collect_new_items(initial_guids, start_time, end_time)
  if #new_items == 0 then
    return {}
  end

  local recorded_end = stopped_at
  for _, item in ipairs(new_items) do
    local _, item_end = item_range(item)
    if item_end > recorded_end then
      recorded_end = item_end
    end
  end

  local max_bars = current_bars()
  local source_bars = source_bars_for_duration(start_time, recorded_end, max_bars)
  local source_end = time_at_measure(measure_at_time(start_time) + source_bars)

  local normalized_items = {}
  reaper.PreventUIRefresh(1)
  for _, item in ipairs(new_items) do
    if reaper.ValidatePtr2(project(), item, "MediaItem*") then
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local glued = glue_item_to_exact_length(item, start_time, source_end)
      if reaper.ValidatePtr2(project(), glued, "MediaItem*") then
        item_start = reaper.GetMediaItemInfo_Value(glued, "D_POSITION")
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

local function loop_status()
  local bars = current_bars()
  local start_time = current_start()
  local end_time = block_end(start_time, bars)
  local start_measure = measure_at_time(start_time) + 1
  local end_measure = measure_at_time(end_time)
  local play_state = reaper.GetPlayStateEx(project())

  return {
    bars = bars,
    start_time = start_time,
    end_time = end_time,
    start_position = format_position(start_time),
    end_position = format_position(end_time),
    start_measure = start_measure,
    end_measure = end_measure,
    is_playing = (play_state & 1) == 1,
    is_recording = (play_state & 4) == 4,
    repeat_enabled = reaper.GetSetRepeat(-1) == 1,
    sws_available = sws_available(),
    sws_version = sws_version(),
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
  local end_time = block_end(start_time, bars)
  local initial_guids = snapshot_item_guids()
  local finalized = false
  local last_pos = reaper.GetPlayPositionEx(project())

  set_loop_range(start_time, end_time, true)
  reaper.GetSetRepeat(1)
  reaper.Main_OnCommand(1013, 0) -- Transport: Record

  local function finalize(stopped_at)
    if finalized then
      return
    end
    finalized = true
    reaper.Undo_BeginBlock2(project())
    normalize_new_items(initial_guids, start_time, end_time, stopped_at or reaper.GetCursorPositionEx(project()))
    set_loop_range(start_time, end_time, false)
    reaper.Undo_EndBlock2(project(), "Loop Composer: loop recording", -1)
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

function M.queue_loopstation_recording()
  local bars = current_bars()
  local start_time = current_start()
  local end_time = block_end(start_time, bars)
  local initial_guids = nil
  local recording_started = false
  local finalized = false
  local last_pos = reaper.GetPlayPositionEx(project())

  clear_ext(LOOPSTATION_STOP_KEY)
  clear_ext(REPLACE_AND_QUEUE_KEY)
  set_loop_range(start_time, end_time, false)
  reaper.GetSetRepeat(1)

  local state = reaper.GetPlayStateEx(project())
  if (state & 1) ~= 1 then
    reaper.SetEditCurPos2(project(), start_time, true, false)
    reaper.Main_OnCommand(1007, 0) -- Transport: Play
    last_pos = start_time
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

    if initial_guids then
      reaper.Undo_BeginBlock2(project())
      local items = normalize_new_items(initial_guids, start_time, end_time, stopped_at or reaper.GetCursorPositionEx(project()))
      store_last_loopstation_take(items)
      set_loop_range(start_time, end_time, false)
      reaper.Undo_EndBlock2(project(), "Loop Composer: loopstation recording", -1)
    end

    if replace_and_queue_requested() then
      clear_ext(REPLACE_AND_QUEUE_KEY)
      M.replace_and_queue_loopstation_recording()
    end
  end

  local function at_loop_start(play_pos)
    return play_pos <= start_time + EDGE_EPSILON or play_pos < last_pos - EDGE_EPSILON
  end

  local function reached_loop_end(play_pos)
    return play_pos >= end_time - EDGE_EPSILON or play_pos < last_pos - EDGE_EPSILON
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

    if not recording_started and at_loop_start(play_pos) then
      initial_guids = snapshot_item_guids()
      recording_started = true
      reaper.Main_OnCommand(1013, 0) -- Transport: Record
      last_pos = play_pos
      reaper.defer(watch)
      return
    end

    if recording_started and is_recording and reached_loop_end(play_pos) then
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
