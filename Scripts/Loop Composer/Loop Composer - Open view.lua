-- @description Loop Composer - Open view
-- @version 1.4.9
-- @author KRGSH
-- @noindex
-- @provides
--   [nomain] Loop Composer Core.lua

local script_path = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
local core = dofile(script_path .. "Loop Composer Core.lua")

local WINDOW_TITLE = "Loop Composer"
local WIDTH = 560
local BASE_HEIGHT = 740
local HEIGHT = BASE_HEIGHT
local PADDING = 14
local GAP = 8
local BUTTON_H = 34
local ICON_BUTTON = 38

local colors = {
  bg = { 0.09, 0.10, 0.11, 1 },
  panel = { 0.15, 0.16, 0.17, 1 },
  panel_alt = { 0.20, 0.21, 0.22, 1 },
  text = { 0.90, 0.91, 0.90, 1 },
  muted = { 0.60, 0.64, 0.65, 1 },
  accent = { 0.15, 0.56, 0.82, 1 },
  accent_dark = { 0.08, 0.32, 0.48, 1 },
  record = { 0.78, 0.18, 0.16, 1 },
  warning = { 0.92, 0.66, 0.25, 1 },
  ok = { 0.28, 0.70, 0.42, 1 },
  border = { 0.33, 0.35, 0.36, 1 },
}

local mouse_left_was_down = false
local mouse_right_was_down = false
local last_message = ""
local learning_control = nil
local last_midi_fingerprint = ""
local controls = {}
local actions = {}

local function set_color(color, alpha)
  gfx.set(color[1], color[2], color[3], alpha or color[4])
end

local function rect(x, y, w, h, color, filled)
  set_color(color)
  gfx.rect(x, y, w, h, filled and 1 or 0)
end

local function circle(x, y, radius, color, filled)
  set_color(color)
  gfx.circle(x, y, radius, filled and 1 or 0)
end

local function line(x1, y1, x2, y2, color)
  set_color(color)
  gfx.line(x1, y1, x2, y2)
end

local function text(x, y, value, color)
  set_color(color or colors.text)
  gfx.x = x
  gfx.y = y
  gfx.drawstr(tostring(value or ""))
end

local function text_width(value)
  return gfx.measurestr(tostring(value or ""))
end

local function fit_label(value, max_width)
  local label = tostring(value or "")
  if text_width(label) <= max_width then
    return label
  end

  local suffix = "..."
  local limit = math.max(1, #label)
  while limit > 1 do
    local candidate = label:sub(1, limit) .. suffix
    if text_width(candidate) <= max_width then
      return candidate
    end
    limit = limit - 1
  end
  return suffix
end

local function inside(mx, my, x, y, w, h)
  return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function flash_color(base, strength)
  return {
    math.min(1, base[1] + strength),
    math.min(1, base[2] + strength),
    math.min(1, base[3] + strength),
    base[4],
  }
end

local function draw_icon(kind, x, y, color)
  local cx = x + ICON_BUTTON / 2
  local cy = y + BUTTON_H / 2
  local c = color or colors.text

  if kind == "play" then
    set_color(c)
    gfx.triangle(cx - 5, cy - 8, cx - 5, cy + 8, cx + 8, cy)
  elseif kind == "stop" then
    rect(cx - 7, cy - 7, 14, 14, c, true)
  elseif kind == "pause" then
    rect(cx - 8, cy - 8, 5, 16, c, true)
    rect(cx + 3, cy - 8, 5, 16, c, true)
  elseif kind == "record" then
    circle(cx, cy, 8, c, true)
  elseif kind == "loop" then
    line(cx - 11, cy - 3, cx + 7, cy - 3, c)
    line(cx + 7, cy - 3, cx + 3, cy - 7, c)
    line(cx + 7, cy - 3, cx + 3, cy + 1, c)
    line(cx + 11, cy + 4, cx - 7, cy + 4, c)
    line(cx - 7, cy + 4, cx - 3, cy, c)
    line(cx - 7, cy + 4, cx - 3, cy + 8, c)
  elseif kind == "prev" then
    set_color(c)
    gfx.triangle(cx + 7, cy - 8, cx + 7, cy + 8, cx - 4, cy)
    rect(cx - 9, cy - 8, 3, 16, c, true)
  elseif kind == "next" then
    set_color(c)
    gfx.triangle(cx - 7, cy - 8, cx - 7, cy + 8, cx + 4, cy)
    rect(cx + 7, cy - 8, 3, 16, c, true)
  elseif kind == "start" then
    rect(cx - 10, cy - 8, 3, 16, c, true)
    line(cx + 8, cy - 8, cx - 1, cy, c)
    line(cx - 1, cy, cx + 8, cy + 8, c)
  elseif kind == "end" then
    rect(cx + 7, cy - 8, 3, 16, c, true)
    line(cx - 8, cy - 8, cx + 1, cy, c)
    line(cx + 1, cy, cx - 8, cy + 8, c)
  elseif kind == "zoom" then
    circle(cx - 3, cy - 3, 7, c, false)
    line(cx + 3, cy + 3, cx + 11, cy + 11, c)
  elseif kind == "dock" then
    rect(cx - 10, cy - 8, 20, 16, c, false)
    rect(cx - 10, cy - 8, 20, 5, c, true)
  elseif kind == "queue" then
    circle(cx - 5, cy, 6, c, false)
    line(cx + 2, cy, cx + 10, cy, c)
    line(cx + 7, cy - 4, cx + 11, cy, c)
    line(cx + 7, cy + 4, cx + 11, cy, c)
  elseif kind == "retry" then
    circle(cx, cy, 9, c, false)
    line(cx + 7, cy - 5, cx + 12, cy - 7, c)
    line(cx + 7, cy - 5, cx + 8, cy - 11, c)
  elseif kind == "apply" then
    line(cx - 9, cy, cx - 2, cy + 7, c)
    line(cx - 2, cy + 7, cx + 10, cy - 8, c)
  end
end

local function mapping_suffix(control_id)
  local label = core.midi_mapping_label(control_id)
  if label ~= "" then
    return "  [" .. label .. "]"
  end
  return ""
end

local function desired_height_for_tracks(track_count)
  local rows = math.max(1, math.ceil((track_count or 0) / 2))
  local tracks_bottom = 508 + 28 + 44 + (rows * (BUTTON_H + GAP))
  return math.max(BASE_HEIGHT, tracks_bottom + 42)
end

local function open_context_menu(control)
  gfx.x = gfx.mouse_x
  gfx.y = gfx.mouse_y
  local choice = gfx.showmenu("MIDI learn|Reset MIDI mapping||Reserved")
  if choice == 1 then
    learning_control = control
    last_message = "Move a MIDI control for " .. control.label
  elseif choice == 2 then
    core.reset_midi_mapping(control.id)
    if learning_control and learning_control.id == control.id then
      learning_control = nil
    end
    last_message = "MIDI mapping reset for " .. control.label
  end
end

local function run_action(control)
  if not control or not control.action then
    return
  end

  local ok, result, message = pcall(control.action)
  if ok then
    last_message = message or result or ""
  else
    last_message = tostring(result)
  end
end

local function register_control(id, label, action)
  local control = { id = id, label = label, action = action }
  controls[#controls + 1] = control
  actions[id] = control
  return control
end

local function button(id, label, icon, x, y, w, h, action, options)
  options = options or {}
  local control = register_control(id, label, action)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local is_hot = inside(mx, my, x, y, w, h)
  local left_down = (gfx.mouse_cap & 1) == 1
  local right_down = (gfx.mouse_cap & 2) == 2
  local left_clicked = is_hot and left_down and not mouse_left_was_down
  local right_clicked = is_hot and right_down and not mouse_right_was_down
  local active = options.active
  local base = options.style or colors.panel_alt
  local fill = active and (options.active_color or colors.accent_dark) or base

  if options.pulse then
    local pulse = 0.10 + ((math.sin(reaper.time_precise() * 7) + 1) * 0.10)
    fill = flash_color(fill, pulse)
  end

  if is_hot then
    fill = flash_color(fill, 0.05)
  end

  rect(x, y, w, h, fill, true)
  rect(x, y, w, h, is_hot and colors.accent or colors.border, false)

  if icon then
    draw_icon(icon, x + 1, y, options.icon_color or colors.text)
    if label and label ~= "" and w > ICON_BUTTON + 22 then
      text(x + ICON_BUTTON + 3, y + 10, fit_label(label, w - ICON_BUTTON - 14), colors.text)
    end
  else
    local fitted = fit_label(label, w - 16)
    text(x + math.max(8, (w - text_width(fitted)) / 2), y + 10, fitted, colors.text)
  end

  local mapped = core.midi_mapping_label(id)
  if mapped ~= "" then
    circle(x + w - 8, y + 8, 3, colors.ok, true)
  end

  if learning_control and learning_control.id == id then
    rect(x + 2, y + 2, w - 4, h - 4, colors.warning, false)
  end

  if right_clicked then
    open_context_menu(control)
  elseif left_clicked then
    run_action(control)
  end
end

local function label_value(label, value, x, y, right)
  text(x, y, label, colors.muted)
  local value_text = tostring(value or "")
  text(right - text_width(value_text), y, value_text, colors.text)
end

local function section_title(value, x, y, w)
  text(x, y, value, colors.text)
  rect(x, y + 19, w, 1, colors.border, true)
end

local function draw_status(status, x, y, w)
  rect(x, y, w, 102, colors.panel, true)
  local right = x + w - 12
  label_value("Length", status.bars .. " bars", x + 12, y + 12, right)
  label_value("Measures", status.start_measure .. " - " .. status.end_measure, x + 12, y + 34, right)
  label_value("Time", status.start_position .. " - " .. status.end_position, x + 12, y + 56, right)

  local transport = "Stopped"
  local transport_color = colors.muted
  if status.is_recording then
    transport = "Recording"
    transport_color = colors.record
  elseif status.is_paused then
    transport = "Paused"
    transport_color = colors.warning
  elseif status.is_playing then
    transport = "Playing"
    transport_color = colors.accent
  end

  text(x + 12, y + 78, "Transport", colors.muted)
  text(right - text_width(transport), y + 78, transport, transport_color)

  local progress_x = x + 104
  local progress_y = y + 82
  local progress_w = w - 202
  rect(progress_x, progress_y, progress_w, 7, colors.bg, true)
  rect(progress_x, progress_y, progress_w * status.progress, 7, status.is_recording and colors.record or colors.accent, true)
end

local function draw_animation(status, x, y, w)
  rect(x, y, w, 46, colors.panel, true)
  local t = reaper.time_precise()

  if status.is_recording then
    local pulse = 0.45 + (math.sin(t * 7) + 1) * 0.22
    circle(x + 24, y + 23, 9 + (pulse * 5), colors.record, false)
    circle(x + 24, y + 23, 7, colors.record, true)
    text(x + 44, y + 15, "Recording pass", colors.text)
  elseif status.is_playing then
    local bar_x = x + 18
    local bar_y = y + 24
    local bar_w = w - 36
    local playhead_x = bar_x + (bar_w * status.progress)
    local glow = 0.10 + ((math.sin(t * 8) + 1) * 0.08)

    text(x + 18, y + 8, "Playing block", colors.text)
    rect(bar_x, bar_y, bar_w, 5, colors.bg, true)
    rect(bar_x, bar_y, math.max(2, bar_w * status.progress), 5, colors.accent, true)
    line(playhead_x, bar_y - 5, playhead_x, bar_y + 10, flash_color(colors.accent, glow))
  else
    text(x + 18, y + 15, "Ready", colors.muted)
  end
end

local function draw_transport(status, y)
  section_title("Transport", PADDING, y, WIDTH - PADDING * 2)
  local x = PADDING
  local by = y + 28

  button("transport_play", "Play", "play", x, by, ICON_BUTTON, BUTTON_H, function()
    core.play()
    return "Play"
  end, { active = status.is_playing and not status.is_recording, active_color = colors.accent_dark })
  x = x + ICON_BUTTON + GAP
  button("transport_pause", "Pause", "pause", x, by, ICON_BUTTON, BUTTON_H, function()
    core.pause()
    return "Pause"
  end, { active = status.is_paused, active_color = colors.warning })
  x = x + ICON_BUTTON + GAP
  button("transport_stop", "Stop", "stop", x, by, ICON_BUTTON, BUTTON_H, function()
    core.stop()
    return "Stop"
  end)
  x = x + ICON_BUTTON + GAP
  button("transport_record", "Record", "record", x, by, ICON_BUTTON, BUTTON_H, function()
    core.record()
    return "Record"
  end, { active = status.is_recording, style = colors.record, icon_color = colors.text })
  x = x + ICON_BUTTON + GAP
  button("transport_repeat", "Loop", "loop", x, by, ICON_BUTTON, BUTTON_H, function()
    core.toggle_repeat()
    return "Loop toggled"
  end, { active = status.repeat_enabled, active_color = colors.accent_dark })
  x = x + ICON_BUTTON + GAP
  button("block_start", "Start", "start", x, by, ICON_BUTTON, BUTTON_H, function()
    core.jump_block_start()
    return "Jumped to block start"
  end)
  x = x + ICON_BUTTON + GAP
  button("block_end", "End", "end", x, by, ICON_BUTTON, BUTTON_H, function()
    core.jump_block_end()
    return "Jumped to block end"
  end)
  x = x + ICON_BUTTON + GAP
  button("block_prev", "Prev", "prev", x, by, ICON_BUTTON, BUTTON_H, function()
    core.navigate(-1)
    return "Previous block"
  end)
  x = x + ICON_BUTTON + GAP
  button("block_next", "Next", "next", x, by, ICON_BUTTON, BUTTON_H, function()
    core.navigate(1)
    return "Next block"
  end)
  x = x + ICON_BUTTON + GAP
  button("dock_toggle", "Dock", "dock", x, by, ICON_BUTTON, BUTTON_H, function()
    local dock_state = gfx.dock(-1)
    local next_state = dock_state == 0 and 1 or 0
    gfx.dock(next_state)
    core.set_dock_state(next_state)
    return next_state == 0 and "Floating view" or "Docked view"
  end, { active = gfx.dock(-1) ~= 0, active_color = colors.accent_dark })
end

local function draw_length_buttons(y)
  section_title("Block length", PADDING, y, WIDTH - PADDING * 2)
  local lengths = { 4, 8, 16, 32, 64 }
  local button_w = (WIDTH - (PADDING * 2) - (GAP * (#lengths - 1))) / #lengths
  local by = y + 28

  for i, bars in ipairs(lengths) do
    local x = PADDING + ((button_w + GAP) * (i - 1))
    button("length_" .. bars, tostring(bars), nil, x, by, button_w, BUTTON_H, function()
      core.set_length(bars)
      return bars .. " bars selected"
    end)
  end
end

local function draw_loopstation(status, y)
  section_title("Loopstation", PADDING, y, WIDTH - PADDING * 2)
  local by = y + 28
  button("loopstation_start", "Start", "play", PADDING, by, 102, BUTTON_H, function()
    core.start_loopstation_mode()
    return "Loopstation started"
  end, { style = colors.accent_dark })
  button("loopstation_queue", "Queue", "queue", PADDING + 110, by, 102, BUTTON_H, function()
    core.queue_loopstation_recording()
    return "Recording queued"
  end, {
    active = status.loopstation_queued,
    style = colors.record,
    active_color = colors.record,
    pulse = status.loopstation_queued,
  })
  button("loopstation_stop", "Stop Rec", "stop", PADDING + 220, by, 102, BUTTON_H, function()
    core.stop_loopstation_recording()
    return "Recording stop requested"
  end)
  button("loopstation_retry", "Retry", "retry", PADDING + 330, by, 92, BUTTON_H, function()
    core.replace_and_queue_loopstation_recording()
    return "Last take replaced"
  end)
  button("loopstation_zoom", "Zoom", "zoom", PADDING + 430, by, 102, BUTTON_H, function()
    local ok, message = core.focus_current_block()
    if ok then
      return "Focused current block"
    end
    return message
  end, { active = status.sws_available, active_color = colors.accent_dark })
end

local function draw_block_tools(status, y)
  section_title("Block tools", PADDING, y, WIDTH - PADDING * 2)
  local by = y + 28
  button("block_record", "Record block", "record", PADDING, by, 132, BUTTON_H, function()
    core.start_loop_recording()
    return "Recording current block"
  end, { style = colors.record })
  button("block_apply_loop", "Apply loop", "apply", PADDING + 140, by, 122, BUTTON_H, function()
    core.apply_current_loop()
    return "Loop block applied"
  end)
  button("block_set_cursor", "Set", "start", PADDING + 270, by, 76, BUTTON_H, function()
    core.set_current_block_from_cursor()
    return "Block set from cursor"
  end)
  button("block_create_next", "Create next", "next", PADDING + 354, by, 114, BUTTON_H, function()
    core.create_next_block()
    return "Next block created"
  end)
  button("recorddub_mode", "Dub", nil, PADDING + 476, by, 56, BUTTON_H, function()
    local enabled = core.toggle_recorddub()
    return enabled and "MIDI record dub enabled" or "MIDI record dub disabled"
  end, { active = status.recorddub_enabled, active_color = colors.accent_dark })
end

local function draw_tracks(status, y, tracks)
  section_title("Target tracks", PADDING, y, WIDTH - PADDING * 2)
  local by = y + 28

  button("tracks_use_selected", "Use selected", nil, PADDING, by, 116, BUTTON_H, function()
    local count = core.set_target_tracks_from_selection()
    return tostring(count) .. " target tracks mapped"
  end)
  button("tracks_clear", "Clear", nil, PADDING + 124, by, 72, BUTTON_H, function()
    core.clear_target_tracks()
    return "Target tracks cleared"
  end)

  local mode = status.recorddub_enabled and "MIDI record dub" or "Normal record"
  local mode_color = status.recorddub_enabled and colors.ok or colors.muted
  text(PADDING + 210, by + 10, mode, mode_color)

  local row_y = by + 44
  if #tracks == 0 then
    text(PADDING, row_y + 8, "No target tracks. Select tracks in REAPER, then use selected.", colors.muted)
    return
  end

  for i, track in ipairs(tracks) do
    local column = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local w = (WIDTH - (PADDING * 2) - GAP) / 2
    local x = PADDING + (column * (w + GAP))
    local y_pos = row_y + (row * (BUTTON_H + GAP))
    local id = "track_slot_" .. tostring(i)
    local label = tostring(track.track_number) .. "  " .. track.name
    button(id, label, "queue", x, y_pos, w, BUTTON_H, function()
      local ok, message = core.toggle_target_loopstation_recording(i)
      return message or (ok and "Recording queued" or "Target track unavailable")
    end, {
      active = track.loopstation_active,
      active_color = track.exists and colors.record or colors.warning,
      style = track.enabled and colors.panel_alt or colors.panel,
      pulse = track.loopstation_active,
    })
  end
end

local function draw_sws_status(status)
  local message = "SWS missing"
  local color = colors.warning
  if status.sws_available then
    message = "SWS " .. tostring(status.sws_version or "available")
    color = colors.accent
  end
  text(PADDING, 42, message, color)
end

local function process_midi()
  local event = core.recent_midi_event()
  if not event or event.fingerprint == last_midi_fingerprint then
    return
  end

  last_midi_fingerprint = event.fingerprint
  if learning_control then
    core.set_midi_mapping(learning_control.id, event)
    last_message = learning_control.label .. " mapped to " .. event.label
    learning_control = nil
    return
  end

  for id, control in pairs(actions) do
    if core.midi_event_matches(id, event) then
      run_action(control)
      return
    end
  end
end

local function draw()
  process_midi()
  controls = {}
  actions = {}

  local status = core.status()
  local tracks = core.target_tracks()
  local desired_height = desired_height_for_tracks(#tracks)
  if desired_height ~= HEIGHT and gfx.dock(-1) == 0 then
    HEIGHT = desired_height
    gfx.init(WINDOW_TITLE, WIDTH, HEIGHT, core.dock_state())
    gfx.setfont(1, "Arial", 13)
  else
    HEIGHT = math.max(desired_height, gfx.h)
  end

  rect(0, 0, WIDTH, HEIGHT, colors.bg, true)

  gfx.setfont(1, "Arial", 18)
  text(PADDING, 16, "Loop Composer", colors.text)
  gfx.setfont(1, "Arial", 13)
  draw_sws_status(status)

  local dock_label = gfx.dock(-1) == 0 and "Floating" or "Docked"
  text(WIDTH - PADDING - text_width(dock_label), 16, dock_label, colors.muted)

  draw_status(status, PADDING, 64, WIDTH - PADDING * 2)
  draw_animation(status, PADDING, 174, WIDTH - PADDING * 2)
  draw_transport(status, 236)
  draw_length_buttons(304)
  draw_loopstation(status, 372)
  draw_block_tools(status, 440)
  draw_tracks(status, 508, tracks)

  if learning_control then
    text(PADDING, HEIGHT - 20, "MIDI learn: " .. learning_control.label .. mapping_suffix(learning_control.id), colors.warning)
  elseif last_message ~= "" then
    text(PADDING, HEIGHT - 20, last_message, colors.muted)
  end

  mouse_left_was_down = (gfx.mouse_cap & 1) == 1
  mouse_right_was_down = (gfx.mouse_cap & 2) == 2
end

gfx.init(WINDOW_TITLE, WIDTH, HEIGHT, core.dock_state())
gfx.setfont(1, "Arial", 13)

local function loop()
  draw()
  gfx.update()
  if gfx.getchar() >= 0 then
    reaper.defer(loop)
  else
    core.set_dock_state(gfx.dock(-1))
  end
end

loop()
