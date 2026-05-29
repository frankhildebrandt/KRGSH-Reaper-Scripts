-- @noindex

function midi_take_for_item(item)
  local active_take = reaper.GetActiveTake(item)
  if active_take and reaper.TakeIsMIDI(active_take) then
    return active_take
  end

  local take_count = reaper.CountTakes(item)
  for i = 0, take_count - 1 do
    local take = reaper.GetMediaItemTake(item, i)
    if take and reaper.TakeIsMIDI(take) then
      return take
    end
  end

  return nil
end

function capture_midi_event_project_times(take)
  local positions = {
    notes = {},
    ccs = {},
    text = {},
  }
  if not take or not reaper.TakeIsMIDI(take) then
    return positions
  end

  local _, note_count, cc_count, text_count = reaper.MIDI_CountEvts(take)
  for i = 0, note_count - 1 do
    local retval, selected, muted, start_ppq, end_ppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if retval then
      positions.notes[i + 1] = {
        start_time = reaper.MIDI_GetProjTimeFromPPQPos(take, start_ppq),
        end_time = reaper.MIDI_GetProjTimeFromPPQPos(take, end_ppq),
      }
    end
  end

  for i = 0, cc_count - 1 do
    local retval, selected, muted, ppqpos, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if retval then
      positions.ccs[i + 1] = reaper.MIDI_GetProjTimeFromPPQPos(take, ppqpos)
    end
  end

  for i = 0, text_count - 1 do
    local retval, selected, muted, ppqpos, msg_type, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if retval then
      positions.text[i + 1] = reaper.MIDI_GetProjTimeFromPPQPos(take, ppqpos)
    end
  end

  return positions
end

function restore_midi_event_project_times(take, positions)
  if not take or not reaper.TakeIsMIDI(take) or not positions then
    return
  end

  local _, note_count, cc_count, text_count = reaper.MIDI_CountEvts(take)

  for i = 0, note_count - 1 do
    local timing = positions.notes and positions.notes[i + 1]
    local retval, selected, muted, start_ppq, end_ppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if retval and timing then
      reaper.MIDI_SetNote(
        take,
        i,
        selected,
        muted,
        reaper.MIDI_GetPPQPosFromProjTime(take, timing.start_time),
        reaper.MIDI_GetPPQPosFromProjTime(take, timing.end_time),
        chan,
        pitch,
        vel,
        true
      )
    end
  end

  for i = 0, cc_count - 1 do
    local project_time = positions.ccs and positions.ccs[i + 1]
    local retval, selected, muted, ppqpos, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if retval and project_time then
      reaper.MIDI_SetCC(
        take,
        i,
        selected,
        muted,
        reaper.MIDI_GetPPQPosFromProjTime(take, project_time),
        chanmsg,
        chan,
        msg2,
        msg3,
        true
      )
    end
  end

  for i = 0, text_count - 1 do
    local project_time = positions.text and positions.text[i + 1]
    local retval, selected, muted, ppqpos, msg_type, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if retval and project_time then
      reaper.MIDI_SetTextSysexEvt(
        take,
        i,
        selected,
        muted,
        reaper.MIDI_GetPPQPosFromProjTime(take, project_time),
        msg_type,
        msg,
        true
      )
    end
  end

  reaper.MIDI_Sort(take)
end

function insert_midi_leading_silence(item, start_time)
  if not item or not reaper.ValidatePtr2(project(), item, "MediaItem*") then
    return item
  end

  local take = midi_take_for_item(item)
  if not take then
    return item
  end

  local item_start, item_end = item_range(item)
  if item_start <= start_time + 0.001 then
    return item
  end

  local event_times = capture_midi_event_project_times(take)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", start_time)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(0.001, item_end - start_time))
  restore_midi_event_project_times(take, event_times)
  return item
end

function midi_items_at_time(track, start_time)
  local items = {}
  if not reaper.ValidatePtr2(project(), track, "MediaTrack*") then
    return items
  end

  local count = reaper.CountTrackMediaItems(track)
  for i = 0, count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start, item_end = item_range(item)
    if item_start <= start_time + 0.001 and item_end > start_time + 0.001 and midi_take_for_item(item) then
      items[#items + 1] = item
    end
  end

  return items
end

function midi_takes_at_time(track, start_time)
  local takes = {}
  if not reaper.ValidatePtr2(project(), track, "MediaTrack*") then
    return takes
  end

  local count = reaper.CountTrackMediaItems(track)
  for i = 0, count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local item_start, item_end = item_range(item)
    if item_start <= start_time + 0.001 and item_end > start_time + 0.001 then
      local take = midi_take_for_item(item)
      if take then
        takes[#takes + 1] = take
      end
    end
  end

  return takes
end

function midi_items_for_overdub(tracks, start_time)
  local items = {}
  local seen = {}
  for _, track in ipairs(tracks or {}) do
    local track_items = midi_items_at_time(track, start_time)
    for _, item in ipairs(track_items) do
      append_item_once(items, seen, item)
    end
  end
  return items
end

function midi_takes_for_items(items)
  local takes = {}
  for _, item in ipairs(items or {}) do
    if reaper.ValidatePtr2(project(), item, "MediaItem*") then
      local take = midi_take_for_item(item)
      if take then
        takes[#takes + 1] = take
      end
    end
  end
  return takes
end

function ensure_midi_items_for_overdub(tracks, start_time, end_time)
  if not reaper.CreateNewMIDIItemInProj then
    return midi_items_for_overdub(tracks, start_time)
  end

  for _, track in ipairs(tracks or {}) do
    if reaper.ValidatePtr2(project(), track, "MediaTrack*") and #midi_takes_at_time(track, start_time) == 0 then
      local item = reaper.CreateNewMIDIItemInProj(track, start_time, end_time, false)
      if item and reaper.ValidatePtr2(project(), item, "MediaItem*") then
        reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
        reaper.SetMediaItemSelected(item, false)
      end
    end
  end
  reaper.UpdateArrange()
  return midi_items_for_overdub(tracks, start_time)
end

function current_held_midi_notes()
  if not reaper.MIDI_GetRecentInputEvent then
    return {}
  end

  pcall(reaper.MIDI_GetRecentInputEvent, 0)

  local resolved = {}
  local held = {}
  for i = 0, RECENT_MIDI_EVENT_LIMIT - 1 do
    local ok, retval, msg = pcall(reaper.MIDI_GetRecentInputEvent, i)
    if not ok or not retval or retval == 0 or not msg or #msg < 3 then
      break
    end

    local status = msg:byte(1)
    local pitch = msg:byte(2) or 0
    local velocity = msg:byte(3) or 0
    local message_type = status & 0xF0
    local channel = status & 0x0F
    local key = tostring(channel) .. ":" .. tostring(pitch)

    if (message_type == 0x80 or message_type == 0x90) and not resolved[key] then
      resolved[key] = true
      if message_type == 0x90 and velocity > 0 then
        held[#held + 1] = {
          channel = channel,
          pitch = pitch,
          velocity = velocity,
        }
      end
    end
  end

  return held
end

function insert_held_note_ons(takes, start_time, end_time)
  local held_notes = current_held_midi_notes()
  if #held_notes == 0 then
    return
  end

  for _, take in ipairs(takes or {}) do
    if take and reaper.ValidatePtr2(project(), take, "MediaItem_Take*") and reaper.TakeIsMIDI(take) then
      local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, start_time)
      local end_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, end_time)
      for _, note in ipairs(held_notes) do
        local note_on = string.char(0x90 | note.channel, note.pitch, note.velocity)
        local note_off = string.char(0x80 | note.channel, note.pitch, 0)
        reaper.MIDI_InsertEvt(take, false, false, start_ppq, note_on)
        reaper.MIDI_InsertEvt(take, false, false, end_ppq, note_off)
      end
      reaper.MIDI_Sort(take)
    end
  end
end

function prepare_midi_overdub_recording(tracks, start_time, end_time)
  local items = ensure_midi_items_for_overdub(tracks, start_time, end_time)
  local takes = midi_takes_for_items(items)
  insert_held_note_ons(takes, start_time, end_time)
  return items
end


function midi_mapping_key(control_id)
  return MIDI_MAP_PREFIX .. tostring(control_id or "")
end

function parse_midi_mapping(value)
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

function encode_midi_mapping(event)
  if not event then
    return ""
  end
  return table.concat({ event.type, event.channel, event.number }, ":")
end

function midi_event_label(event)
  if not event then
    return ""
  end
  local kind = event.type == "cc" and "CC" or "Note"
  return kind .. " " .. tostring(event.number) .. " ch " .. tostring((event.channel or 0) + 1)
end

function recent_midi_event()
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

function mapping_matches(mapping, event)
  return mapping and event and
    mapping.type == event.type and
    mapping.channel == event.channel and
    mapping.number == event.number
end
