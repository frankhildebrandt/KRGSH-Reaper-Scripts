-- @noindex

function M.start_loop_recording()
  local bars = current_bars()
  local start_time = current_start()
  local use_midi_overdub = recording_uses_midi_overdub()
  local end_time = block_end(start_time, bars)
  local record_context = begin_target_recording_context()
  local overdub_items = {}
  if use_midi_overdub then
    overdub_items = prepare_midi_overdub_recording(overdub_target_tracks(), start_time, end_time)
  end
  local initial_guids = snapshot_item_guids()
  local recording_started = false
  local recording_seen = false
  local recording_started_at = nil
  local finalized = false
  local last_pos = reaper.GetPlayPositionEx(project())

  set_loop_range(start_time, end_time, false)
  reaper.SetEditCurPos2(project(), start_time, true, false)
  reaper.GetSetRepeat(1)
  reaper.Main_OnCommand(1013, 0) -- Transport: Record
  recording_started = true
  recording_started_at = precise_time()
  last_pos = start_time

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
      stopped_at or reaper.GetCursorPositionEx(project()),
      nil,
      overdub_items
    )
    set_loop_range(start_time, end_time, false)
    reaper.Undo_EndBlock2(project(), "Loop Composer: loop recording", -1)
    record_context.restore()
  end

  local function watch()
    local state = reaper.GetPlayStateEx(project())
    local is_playing = (state & 1) == 1
    local is_recording = (state & 4) == 4
    local play_pos = reaper.GetPlayPositionEx(project())
    local reached_end = play_pos >= end_time - 0.02 or play_pos < last_pos - 0.02
    if is_recording then
      recording_seen = true
    end

    if recording_started and is_recording and reached_end then
      reaper.Main_OnCommand(1016, 0) -- Transport: Stop
      finalize(end_time)
      return
    end

    if recording_started and recording_seen and not is_recording then
      finalize(reaper.GetCursorPositionEx(project()))
      return
    end

    if not is_playing and (not recording_started or
        (not recording_seen and recording_started_at and precise_time() - recording_started_at > 0.75)) then
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
  local end_time = block_end(start_time, bars)
  local initial_guids = nil
  local record_context = nil
  local recording_started = false
  local recording_reached_block_start = false
  local recording_seen = false
  local recording_started_at = nil
  local finalized = false
  local last_pos = reaper.GetPlayPositionEx(project())
  local target_tracks = nil
  local target_guid = ""
  local overdub_items = {}

  if target_track and reaper.ValidatePtr2(project(), target_track, "MediaTrack*") then
    target_tracks = { target_track }
    target_guid = track_guid(target_track)
  end

  local use_midi_overdub = recording_uses_midi_overdub(target_tracks)

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
    reaper.SetEditCurPos2(project(), start_time, true, false)
    record_context = begin_target_recording_context(target_tracks)
    if use_midi_overdub then
      overdub_items = prepare_midi_overdub_recording(overdub_target_tracks(target_tracks), start_time, end_time)
    end
    initial_guids = snapshot_item_guids()
    set_ext(LOOPSTATION_QUEUE_KEY, "recording")
    recording_started = true
    recording_reached_block_start = true
    recording_started_at = precise_time()
    reaper.Main_OnCommand(1013, 0) -- Transport: Record
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
    clear_ext(LOOPSTATION_QUEUE_KEY)
    clear_ext(LOOPSTATION_TARGET_KEY)

    if initial_guids then
      reaper.Undo_BeginBlock2(project())
      local items = normalize_new_items(
        initial_guids,
        start_time,
        end_time,
        stopped_at or reaper.GetCursorPositionEx(project()),
        nil,
        overdub_items
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

  local function watch()
    local play_state = reaper.GetPlayStateEx(project())
    local is_playing = (play_state & 1) == 1
    local is_recording = (play_state & 4) == 4
    local play_pos = reaper.GetPlayPositionEx(project())
    local stop_requested = loopstation_stop_requested()
    if is_recording then
      recording_seen = true
    end

    if not is_playing and not is_recording then
      if not recording_started or recording_seen or
          (recording_started_at and precise_time() - recording_started_at > 0.75) then
        finalize(reaper.GetCursorPositionEx(project()))
        return
      end
    end

    if stop_requested then
      if is_recording then
        reaper.Main_OnCommand(1007, 0) -- Transport: Play
      end
      finalize(play_pos)
      return
    end

    if not recording_started and at_loop_start(play_pos) then
      record_context = begin_target_recording_context(target_tracks)
      if use_midi_overdub then
        overdub_items = prepare_midi_overdub_recording(overdub_target_tracks(target_tracks), start_time, end_time)
      end
      initial_guids = snapshot_item_guids()
      set_ext(LOOPSTATION_QUEUE_KEY, "recording")
      recording_started = true
      recording_started_at = precise_time()
      recording_reached_block_start = true
      reaper.Main_OnCommand(1013, 0) -- Transport: Record
      last_pos = play_pos
      reaper.defer(watch)
      return
    end

    if recording_started and is_recording and recording_reached_block_start and play_pos >= end_time - EDGE_EPSILON then
      reaper.Main_OnCommand(1007, 0) -- Transport: Play
      finalize(end_time)
      return
    end

    if recording_started and recording_seen and not is_recording then
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
