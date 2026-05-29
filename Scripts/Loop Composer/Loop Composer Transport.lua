-- @noindex

function loop_status()
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
  local count = reaper.CountSelectedTracks(project())
  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(project(), i)
    local guid = track_guid(track)
    if guid ~= "" then
      slots[#slots + 1] = { guid = guid, enabled = true }
    end
  end
  set_ext(TARGET_TRACKS_KEY, encode_target_tracks(slots))
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
