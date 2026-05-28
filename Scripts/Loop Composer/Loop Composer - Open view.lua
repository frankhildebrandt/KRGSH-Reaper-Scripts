-- @description Loop Composer - Open view
-- @version 1.1.0
-- @author KRGSH
-- @noindex
-- @provides
--   [nomain] Loop Composer Core.lua

local script_path = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
local core = dofile(script_path .. "Loop Composer Core.lua")

local WINDOW_TITLE = "Loop Composer"
local WIDTH = 430
local HEIGHT = 500
local PADDING = 16
local BUTTON_H = 34
local GAP = 8

local colors = {
  bg = { 0.10, 0.11, 0.12, 1 },
  panel = { 0.16, 0.17, 0.18, 1 },
  panel_alt = { 0.20, 0.21, 0.22, 1 },
  text = { 0.90, 0.91, 0.90, 1 },
  muted = { 0.62, 0.65, 0.66, 1 },
  accent = { 0.15, 0.55, 0.85, 1 },
  accent_dark = { 0.09, 0.34, 0.52, 1 },
  record = { 0.74, 0.18, 0.16, 1 },
  warning = { 0.90, 0.64, 0.24, 1 },
  border = { 0.33, 0.35, 0.36, 1 },
}

local function set_color(color)
  gfx.set(color[1], color[2], color[3], color[4])
end

local function rect(x, y, w, h, color, filled)
  set_color(color)
  gfx.rect(x, y, w, h, filled and 1 or 0)
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

local function inside(mx, my, x, y, w, h)
  return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local mouse_was_down = false
local last_message = ""

local function button(label, x, y, w, h, action, style)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local is_hot = inside(mx, my, x, y, w, h)
  local mouse_down = (gfx.mouse_cap & 1) == 1
  local clicked = is_hot and mouse_down and not mouse_was_down
  local base = style or colors.panel_alt

  rect(x, y, w, h, is_hot and colors.accent_dark or base, true)
  rect(x, y, w, h, is_hot and colors.accent or colors.border, false)
  text(x + math.max(8, (w - text_width(label)) / 2), y + 10, label, colors.text)

  if clicked and action then
    local ok, result, message = pcall(action)
    if ok then
      last_message = message or result or ""
    else
      last_message = tostring(result)
    end
  end
end

local function label_value(label, value, x, y)
  text(x, y, label, colors.muted)
  local value_text = tostring(value or "")
  text(WIDTH - PADDING - text_width(value_text), y, value_text, colors.text)
end

local function section_title(value, x, y)
  text(x, y, value, colors.text)
  rect(x, y + 20, WIDTH - (PADDING * 2), 1, colors.border, true)
end

local function draw_status(status, y)
  rect(PADDING, y, WIDTH - (PADDING * 2), 104, colors.panel, true)
  label_value("Length", status.bars .. " bars", PADDING + 12, y + 14)
  label_value("Measures", status.start_measure .. " - " .. status.end_measure, PADDING + 12, y + 38)
  label_value("Time", status.start_position .. " - " .. status.end_position, PADDING + 12, y + 62)

  local transport = "Stopped"
  local transport_color = colors.muted
  if status.is_recording then
    transport = "Recording"
    transport_color = colors.record
  elseif status.is_playing then
    transport = "Playing"
    transport_color = colors.accent
  end

  text(PADDING + 12, y + 86, "Transport", colors.muted)
  text(WIDTH - PADDING - text_width(transport), y + 86, transport, transport_color)
end

local function draw_length_buttons(y)
  local lengths = { 4, 8, 16, 32, 64 }
  local button_w = (WIDTH - (PADDING * 2) - (GAP * (#lengths - 1))) / #lengths

  for i, bars in ipairs(lengths) do
    local x = PADDING + ((button_w + GAP) * (i - 1))
    button(tostring(bars), x, y, button_w, BUTTON_H, function()
      core.set_length(bars)
      return bars .. " bars selected"
    end)
  end
end

local function draw_sws_status(status, y)
  local message = "SWS missing"
  local color = colors.warning
  if status.sws_available then
    message = "SWS " .. tostring(status.sws_version or "available")
    color = colors.accent
  end

  text(PADDING, y, message, color)
end

local function draw()
  local status = core.status()
  rect(0, 0, WIDTH, HEIGHT, colors.bg, true)

  gfx.setfont(1, "Arial", 18)
  text(PADDING, 16, "Loop Composer", colors.text)
  gfx.setfont(1, "Arial", 13)
  draw_sws_status(status, 42)

  draw_status(status, 68)

  section_title("Block length", PADDING, 194)
  draw_length_buttons(224)

  section_title("Loopstation", PADDING, 278)
  button("Start", PADDING, 308, 94, BUTTON_H, function()
    core.start_loopstation_mode()
    return "Loopstation started"
  end, colors.accent_dark)
  button("Queue Rec", PADDING + 102, 308, 94, BUTTON_H, function()
    core.queue_loopstation_recording()
    return "Recording queued"
  end, colors.record)
  button("Stop Rec", PADDING + 204, 308, 94, BUTTON_H, function()
    core.stop_loopstation_recording()
    return "Recording stop requested"
  end)
  button("Retry", PADDING + 306, 308, 94, BUTTON_H, function()
    core.replace_and_queue_loopstation_recording()
    return "Last take replaced"
  end)

  section_title("Block tools", PADDING, 364)
  button("Set", PADDING, 394, 74, BUTTON_H, function()
    core.set_current_block_from_cursor()
    return "Block set from edit cursor"
  end)
  button("Prev", PADDING + 82, 394, 74, BUTTON_H, function()
    core.navigate(-1)
    return "Previous block"
  end)
  button("Next", PADDING + 164, 394, 74, BUTTON_H, function()
    core.navigate(1)
    return "Next block"
  end)
  button("Create", PADDING + 246, 394, 74, BUTTON_H, function()
    core.create_next_block()
    return "Next block created"
  end)
  button("Zoom", PADDING + 328, 394, 74, BUTTON_H, function()
    local ok, message = core.focus_current_block()
    if ok then
      return "Focused current block with SWS"
    end
    return message
  end, status.sws_available and colors.accent_dark or colors.panel_alt)

  button("Record block", PADDING, 444, 140, BUTTON_H, function()
    core.start_loop_recording()
    return "Recording current block"
  end, colors.record)
  button("Apply loop", PADDING + 148, 444, 120, BUTTON_H, function()
    core.apply_current_loop()
    return "Loop block applied"
  end)

  if last_message ~= "" then
    text(PADDING, HEIGHT - 18, last_message, colors.muted)
  end

  mouse_was_down = (gfx.mouse_cap & 1) == 1
end

gfx.init(WINDOW_TITLE, WIDTH, HEIGHT, 0)
gfx.setfont(1, "Arial", 13)

local function loop()
  draw()
  gfx.update()
  if gfx.getchar() >= 0 then
    reaper.defer(loop)
  end
end

loop()
