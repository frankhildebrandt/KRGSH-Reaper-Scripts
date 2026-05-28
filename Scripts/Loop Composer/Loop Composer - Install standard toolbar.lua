-- @description Loop Composer - Install standard toolbar
-- @version 1.4.2
-- @author KRGSH
-- @noindex
-- @provides
--   [data] ../../Data/toolbar_icons/loop_composer_len_4.svg
--   [data] ../../Data/toolbar_icons/loop_composer_len_8.svg
--   [data] ../../Data/toolbar_icons/loop_composer_len_16.svg
--   [data] ../../Data/toolbar_icons/loop_composer_len_32.svg
--   [data] ../../Data/toolbar_icons/loop_composer_len_64.svg
--   [data] ../../Data/toolbar_icons/loop_composer_record.svg
--   [data] ../../Data/toolbar_icons/loop_composer_loopstation.svg
--   [data] ../../Data/toolbar_icons/loop_composer_queue_record.svg
--   [data] ../../Data/toolbar_icons/loop_composer_stop_record.svg
--   [data] ../../Data/toolbar_icons/loop_composer_replace_queue.svg
--   [data] ../../Data/toolbar_icons/loop_composer_view.svg
--   [data] ../../Data/toolbar_icons/loop_composer_prev.svg
--   [data] ../../Data/toolbar_icons/loop_composer_next.svg
--   [data] ../../Data/toolbar_icons/loop_composer_create_next.svg
--   [data] ../../Data/toolbar_icons/loop_composer_set_block.svg

local function path_dir(path)
  return path:match("^(.*[/\\])") or ""
end

local function join_path(base, name)
  local sep = package.config:sub(1, 1)
  if base:sub(-1) == "/" or base:sub(-1) == "\\" then
    return base .. name
  end
  return base .. sep .. name
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end

local function write_file(path, data)
  local file = io.open(path, "wb")
  if not file then
    return false
  end
  file:write(data)
  file:close()
  return true
end

local function copy_file(source, destination)
  local data = read_file(source)
  if not data then
    return false
  end
  return write_file(destination, data)
end

local script_dir

local function command_id_for_script(script_file)
  local command_id = reaper.AddRemoveReaScript(true, 0, join_path(script_dir, script_file), true)
  if not command_id or command_id == 0 then
    return nil
  end
  return command_id
end

local script_path = ({ reaper.get_action_context() })[2]
script_dir = path_dir(script_path)
local repo_root = script_dir:gsub("[/\\]Scripts[/\\]Loop Composer[/\\]?$", "")
local resource_path = reaper.GetResourcePath()
local icon_source_dir = join_path(join_path(repo_root, "Data"), "toolbar_icons")
local icon_dest_dir = join_path(resource_path, "Data")
local menu_dest_dir = join_path(resource_path, "MenuSets")
local menu_dest_path = join_path(menu_dest_dir, "Loop Composer Toolbar.ReaperMenu")

reaper.RecursiveCreateDirectory(icon_dest_dir, 0)
reaper.RecursiveCreateDirectory(menu_dest_dir, 0)

local actions = {
  { "Loop Composer - Set length to 4 bars.lua", "loop_composer_len_4.svg", "4 bars" },
  { "Loop Composer - Set length to 8 bars.lua", "loop_composer_len_8.svg", "8 bars" },
  { "Loop Composer - Set length to 16 bars.lua", "loop_composer_len_16.svg", "16 bars" },
  { "Loop Composer - Set length to 32 bars.lua", "loop_composer_len_32.svg", "32 bars" },
  { "Loop Composer - Set length to 64 bars.lua", "loop_composer_len_64.svg", "64 bars" },
  { "", "", "" },
  { "Loop Composer - Start loopstation mode.lua", "loop_composer_loopstation.svg", "Loopstation" },
  { "Loop Composer - Queue loopstation recording.lua", "loop_composer_queue_record.svg", "Queue rec" },
  { "Loop Composer - Stop loopstation recording.lua", "loop_composer_stop_record.svg", "Stop rec" },
  { "Loop Composer - Replace and queue loopstation recording.lua", "loop_composer_replace_queue.svg", "Retry rec" },
  { "Loop Composer - Start loop recording.lua", "loop_composer_record.svg", "Record block" },
  { "Loop Composer - Open view.lua", "loop_composer_view.svg", "View" },
  { "", "", "" },
  { "Loop Composer - Set current loop block from edit cursor.lua", "loop_composer_set_block.svg", "Set block" },
  { "Loop Composer - Go to previous loop block.lua", "loop_composer_prev.svg", "Prev block" },
  { "Loop Composer - Go to next loop block.lua", "loop_composer_next.svg", "Next block" },
  { "Loop Composer - Create next loop block from current.lua", "loop_composer_create_next.svg", "Create next" },
}

local missing = {}
local menu = {
  "[Floating toolbar 1]",
  "title=Loop Composer",
}

local item_index = 1
for _, action in ipairs(actions) do
  local script_file, icon, label = action[1], action[2], action[3]
  if script_file == "" then
    menu[#menu + 1] = "item_" .. item_index .. "=--"
    item_index = item_index + 1
  else
    local command_id = command_id_for_script(script_file)
    if command_id then
      copy_file(join_path(icon_source_dir, icon), join_path(icon_dest_dir, icon))
      menu[#menu + 1] = "item_" .. item_index .. "=" .. command_id .. " " .. label
      menu[#menu + 1] = "icon_" .. item_index .. "=" .. icon
      item_index = item_index + 1
    else
      missing[#missing + 1] = script_file
    end
  end
end

write_file(menu_dest_path, table.concat(menu, "\n") .. "\n")

local message = "Created Loop Composer toolbar menu set:\n\n" .. menu_dest_path ..
  "\n\nImport it via Options > Customize menus/toolbars > Import."

if #missing > 0 then
  message = message .. "\n\nMissing actions, install/reload these scripts first:\n- " .. table.concat(missing, "\n- ")
end

reaper.ShowMessageBox(message, "Loop Composer", 0)
