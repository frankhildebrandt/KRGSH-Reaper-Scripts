-- @description Loop Composer - Set current loop block from edit cursor
-- @version 1.4.3
-- @author KRGSH
-- @noindex
-- @provides
--   [nomain] Loop Composer Core.lua

local script_path = ({ reaper.get_action_context() })[2]:match("^(.*[/\\])")
dofile(script_path .. "Loop Composer Core.lua").set_current_block_from_cursor()
