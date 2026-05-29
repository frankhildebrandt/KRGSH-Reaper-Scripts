-- @noindex

local script_path = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
local runtime = {
  M = {},
  reaper = reaper,
}

setmetatable(runtime, { __index = _G })

local function load_module(name)
  local path = script_path .. name
  local chunk, err = loadfile(path, "t", runtime)
  if not chunk then
    error("Loop Composer: failed to load " .. name .. ": " .. tostring(err))
  end
  chunk()
end

load_module("Loop Composer Env.lua")
load_module("Loop Composer Tracks.lua")
load_module("Loop Composer Items.lua")
load_module("Loop Composer Midi.lua")
load_module("Loop Composer Recording.lua")
load_module("Loop Composer Transport.lua")

return runtime.M
