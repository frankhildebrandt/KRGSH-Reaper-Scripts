-- @description Notepad - Install toolbar
-- @version 1.0.1
-- @author KRGSH
-- @noindex
-- @provides
--   [data] ../../Data/toolbar_icons/notepad.svg

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
  if not file then return nil end
  local data = file:read("*a")
  file:close()
  return data
end

local function write_file(path, data)
  local file = io.open(path, "wb")
  if not file then return false end
  file:write(data)
  file:close()
  return true
end

local function copy_file(source, destination)
  local data = read_file(source)
  if not data then return false end
  return write_file(destination, data)
end

local script_path = ({ reaper.get_action_context() })[2]
local script_dir = path_dir(script_path)
local repo_root = script_dir:gsub("[/\\]Scripts[/\\]Notepad[/\\]?$", "")
local resource_path = reaper.GetResourcePath()
local icon_name = "notepad.svg"
local icon_source = join_path(join_path(join_path(repo_root, "Data"), "toolbar_icons"), icon_name)
local icon_dest_dir = join_path(resource_path, "Data")
local menu_dest_dir = join_path(resource_path, "MenuSets")
local menu_dest_path = join_path(menu_dest_dir, "Notepad Toolbar.ReaperMenu")

reaper.RecursiveCreateDirectory(icon_dest_dir, 0)
reaper.RecursiveCreateDirectory(menu_dest_dir, 0)

local command_id = reaper.AddRemoveReaScript(true, 0, join_path(script_dir, "Notepad.lua"), true)
local copied = copy_file(icon_source, join_path(icon_dest_dir, icon_name))
local menu_written = false

if command_id and command_id ~= 0 then
  local menu = {
    "[Floating toolbar 1]",
    "title=Notepad",
    "item_1=" .. tostring(command_id) .. " Notepad",
    "icon_1=" .. icon_name,
  }
  menu_written = write_file(menu_dest_path, table.concat(menu, "\n") .. "\n")
end

local message
if command_id and command_id ~= 0 and copied and menu_written then
  message = "Created Notepad toolbar menu set:\n\n" .. menu_dest_path ..
    "\n\nImport it via Options > Customize menus/toolbars > Import."
else
  message = "Could not fully create the Notepad toolbar menu set."
  if not command_id or command_id == 0 then
    message = message .. "\n\nMissing action: Notepad.lua"
  end
  if not copied then
    message = message .. "\n\nMissing icon: " .. icon_source
  end
  if not menu_written then
    message = message .. "\n\nCould not write: " .. menu_dest_path
  end
end

reaper.ShowMessageBox(message, "Notepad", 0)
