-- @noindex

function track_guid(track)
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

function track_by_guid(guid)
  local count = reaper.CountTracks(project())
  for i = 0, count - 1 do
    local track = reaper.GetTrack(project(), i)
    if track_guid(track) == guid then
      return track
    end
  end
  return nil
end

function track_name(track)
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

function arm_track(track)
  if reaper.ValidatePtr2(project(), track, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
    if recorddub_enabled and recorddub_enabled() then
      reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", MIDI_OVERDUB_RECMODE)
    end
  end
end

function disarm_all_tracks_except(allowed)
  allowed = allowed or {}
  local count = reaper.CountTracks(project())
  for i = 0, count - 1 do
    local track = reaper.GetTrack(project(), i)
    if not allowed[tostring(track)] then
      reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 0)
    end
  end
end

function arm_tracks_exclusive(tracks)
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


function recorddub_enabled()
  return get_ext(RECORD_DUB_KEY, "0") == "1"
end

function decode_target_tracks()
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

function encode_target_tracks(slots)
  local lines = {}
  for _, slot in ipairs(slots or {}) do
    if slot.guid and slot.guid ~= "" then
      lines[#lines + 1] = slot.guid .. "|" .. (slot.enabled and "1" or "0")
    end
  end
  return table.concat(lines, "\n")
end

function active_target_tracks()
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

function recorddub_tracks()
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

function apply_recorddub_to_tracks()
  if not recorddub_enabled() then
    return
  end

  for _, track in ipairs(recorddub_tracks()) do
    if reaper.ValidatePtr2(project(), track, "MediaTrack*") then
      reaper.SetMediaTrackInfo_Value(track, "I_RECMODE", MIDI_OVERDUB_RECMODE)
    end
  end
end

function tracks_use_midi_overdub(tracks)
  for _, track in ipairs(tracks or {}) do
    if reaper.ValidatePtr2(project(), track, "MediaTrack*") and
        reaper.GetMediaTrackInfo_Value(track, "I_RECMODE") == MIDI_OVERDUB_RECMODE then
      return true
    end
  end
  return false
end

function filter_midi_overdub_tracks(tracks)
  local filtered = {}
  for _, track in ipairs(tracks or {}) do
    if reaper.ValidatePtr2(project(), track, "MediaTrack*") and
        reaper.GetMediaTrackInfo_Value(track, "I_RECMODE") == MIDI_OVERDUB_RECMODE then
      filtered[#filtered + 1] = track
    end
  end
  return filtered
end

function selected_tracks()
  local tracks = {}
  local count = reaper.CountSelectedTracks(project())
  for i = 0, count - 1 do
    tracks[#tracks + 1] = reaper.GetSelectedTrack(project(), i)
  end
  return tracks
end

function armed_tracks()
  local tracks = {}
  local count = reaper.CountTracks(project())
  for i = 0, count - 1 do
    local track = reaper.GetTrack(project(), i)
    if reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1 then
      tracks[#tracks + 1] = track
    end
  end
  return tracks
end

function overdub_target_tracks(targets)
  local active_targets = active_target_tracks()
  local selected = selected_tracks()
  local armed = armed_tracks()

  if recorddub_enabled() then
    if targets and #targets > 0 then
      return targets
    elseif #active_targets > 0 then
      return active_targets
    elseif #selected > 0 then
      return selected
    end
    return armed
  end

  if targets and #targets > 0 then
    return filter_midi_overdub_tracks(targets)
  elseif #active_targets > 0 then
    return filter_midi_overdub_tracks(active_targets)
  end

  local selected_overdub = filter_midi_overdub_tracks(selected)
  if #selected_overdub > 0 then
    return selected_overdub
  end

  return filter_midi_overdub_tracks(armed)
end

function recording_uses_midi_overdub(targets)
  if recorddub_enabled() then
    return true
  end
  if targets and #targets > 0 then
    return tracks_use_midi_overdub(targets)
  end
  local active_targets = active_target_tracks()
  if #active_targets > 0 then
    return tracks_use_midi_overdub(active_targets)
  end
  return tracks_use_midi_overdub(selected_tracks()) or tracks_use_midi_overdub(armed_tracks())
end

function begin_target_recording_context(targets)
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
