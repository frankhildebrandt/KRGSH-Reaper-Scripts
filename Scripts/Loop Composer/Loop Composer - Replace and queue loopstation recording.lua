-- @description Loop Composer - Replace and queue loopstation recording
-- @version 1.2.1
-- @author KRGSH
-- @noindex
-- @provides
--   [nomain] Loop Composer Core.lua

local script_path = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
dofile(script_path .. "Loop Composer Core.lua").replace_and_queue_loopstation_recording()
