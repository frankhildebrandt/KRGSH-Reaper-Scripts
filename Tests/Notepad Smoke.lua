local script_dir = (... and (...):match("^(.*[/\\])")) or "Scripts/Notepad/"

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local env = {
  KRGSH_NOTEPAD_TEST = true,
  math = math,
  string = string,
  table = table,
  tostring = tostring,
  tonumber = tonumber,
  ipairs = ipairs,
  pairs = pairs,
  type = type,
}
env._G = env
setmetatable(env, { __index = _G })

local chunk, err = loadfile(script_dir .. "Notepad.lua", "t", env)
if not chunk then
  error(err)
end

local helpers = chunk()
local source_file = io.open(script_dir .. "Notepad.lua", "rb")
local source = source_file:read("*a")
source_file:close()

assert_equal(source:match("ImGui_PushFont%([^,\n]+,[^,\n]+%)") == nil, true, "PushFont always passes size")
assert_equal(source:match("ImGui_CreateFont%([^%)]+,%s*%d+%)") == nil, true, "CreateFont does not pass removed size")
assert_equal(source:match("ImGui_ChildFlags_Borders") ~= nil, true, "current child border flag is used")

local markdown = "# Titel\n\n- eins|zwei\n- 50% fertig\n\n```lua\nprint('hi')\n```\n\n[Link](https://example.com)"
local state = helpers.load_state_from_table({
  list = "1|Projekt%7CNotiz\n2|Idee",
  active_id = "2",
  next_id = "3",
  bodies = {
    ["1"] = markdown,
    ["2"] = "## Zweite Notiz\n\n> quote",
  },
})

assert_equal(state.list, "1|Projekt%7CNotiz\n2|Idee", "note list preserves escaped pipe")
assert_equal(state.bodies["1"], markdown, "markdown body preserved")
assert_equal(state.active_id, "2", "active note preserved")
assert_equal(state.next_id, "3", "next id preserved")

helpers.add_note("Neue Notiz", "Text")
state = helpers.serialize_notes()
assert_equal(state.active_id, "3", "new note is active")
assert_equal(state.bodies["3"], "Text", "new note body")

helpers.duplicate_active_note()
state = helpers.serialize_notes()
assert_equal(state.active_id, "4", "duplicate is active")
assert_equal(state.bodies["4"], "Text", "duplicate body")

helpers.delete_note("4")
state = helpers.serialize_notes()
assert_equal(state.active_id, "3", "delete active selects neighbor")

state = helpers.load_state_from_table({})
assert_equal(state.list, "1|Project Notes", "default note created")
assert_equal(state.bodies["1"], "# Project Notes\n\n", "default markdown body")

local blocks = helpers.markdown_blocks(markdown)
assert_equal(blocks[1].type, "heading", "heading parsed")
assert_equal(blocks[3].type, "bullet", "bullet parsed")
assert_equal(blocks[7].type, "code", "code parsed")
assert_equal(helpers.strip_inline_markdown("**Bold** and [site](https://example.com)"), "Bold and site <https://example.com>", "inline markdown stripped")

print("Notepad smoke tests passed")
