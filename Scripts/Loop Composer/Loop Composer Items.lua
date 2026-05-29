-- @noindex

function item_guid(item)
  local ok, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if ok then
    return guid
  end
  return ""
end

function snapshot_item_guids()
  local guids = {}
  local count = reaper.CountMediaItems(project())
  for i = 0, count - 1 do
    guids[item_guid(reaper.GetMediaItem(project(), i))] = true
  end
  return guids
end

function encode_guids(guids)
  return table.concat(guids, "\n")
end

function decode_guids(value)
  local guids = {}
  for guid in tostring(value or ""):gmatch("[^\n]+") do
    guids[guid] = true
  end
  return guids
end

function item_range(item)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return pos, pos + len
end

function overlaps(start_a, end_a, start_b, end_b)
  return start_a < end_b and end_a > start_b
end

function collect_new_items(initial_guids, start_time, end_time)
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

function append_item_once(items, seen, item)
  if not item or not reaper.ValidatePtr2(project(), item, "MediaItem*") then
    return
  end

  local guid = item_guid(item)
  if guid ~= "" and not seen[guid] then
    seen[guid] = true
    items[#items + 1] = item
  end
end


function store_last_loopstation_take(items)
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

function select_only_item(item)
  reaper.SelectAllMediaItems(project(), false)
  reaper.SetMediaItemSelected(item, true)
  reaper.UpdateArrange()
end

function trim_item_to_start(item, start_time)
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

function glue_item_to_exact_length(item, start_time, source_end)
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local source_len = math.max(0.001, source_end - item_start)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", source_len)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  select_only_item(item)
  reaper.Main_OnCommand(40362, 0) -- Item: Glue items, ignoring time selection

  local glued = reaper.GetSelectedMediaItem(project(), 0)
  return glued or item
end

function normalize_new_items(initial_guids, start_time, end_time, stopped_at, discard_preroll_tail_from, extra_items)
  local new_items = collect_new_items(initial_guids, start_time, end_time)
  local seen = {}
  local extra_item_guids = {}
  for _, item in ipairs(new_items) do
    seen[item_guid(item)] = true
  end

  for _, item in ipairs(extra_items or {}) do
    if reaper.ValidatePtr2(project(), item, "MediaItem*") then
      local item_start, item_end = item_range(item)
      if overlaps(item_start, item_end, start_time, end_time) then
        local guid = item_guid(item)
        if guid ~= "" then
          extra_item_guids[guid] = true
        end
        append_item_once(new_items, seen, item)
      end
    end
  end

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
        if not extra_item_guids[item_guid(item)] and item_end > recorded_end then
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
        trimmed = insert_midi_leading_silence(trimmed, start_time)
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

function collect_items_in_block(start_time, end_time)
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

function duplicate_items_to_block(items, offset)
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

function delete_items_by_guids(guids, start_time, end_time)
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
