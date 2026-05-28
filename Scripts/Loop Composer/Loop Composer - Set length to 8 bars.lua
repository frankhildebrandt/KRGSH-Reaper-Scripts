-- @description Loop Composer - Set length to 8 bars
-- @version 1.3.3
-- @author KRGSH
-- @noindex
-- @provides
--   [nomain] Loop Composer Core.lua

local script_path = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
dofile(script_path .. "Loop Composer Core.lua").set_length(8)
