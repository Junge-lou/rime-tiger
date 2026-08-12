package.path = "./lua/?.lua;" .. package.path

local capture_input = require("tiger_capture_input")

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
  end
end

local function assert_classification(keycode, ascii_mode, has_query, select_keys, shifted, expected_action, expected_char)
  local action, char = capture_input.classify(keycode, ascii_mode, has_query, select_keys, shifted)
  assert_equal(action, expected_action, "classification action")
  assert_equal(char, expected_char, "classification char")
end

local KP_MULTIPLY = 0xffaa
local KP_ADD = 0xffab
local KP_SEPARATOR = 0xffac
local KP_SUBTRACT = 0xffad
local KP_DECIMAL = 0xffae
local KP_DIVIDE = 0xffaf
local KP_EQUAL = 0xffbd
local KP_0 = 0xffb0
local KP_2 = 0xffb2
local KP_7 = 0xffb7

assert_equal(capture_input.keycode_to_char(string.byte("a")), "a", "ASCII key conversion")
assert_equal(capture_input.keycode_to_char(KP_0), "0", "keypad zero conversion")
assert_equal(capture_input.keycode_to_char(KP_7), "7", "keypad digit conversion")
assert_equal(capture_input.keycode_to_char(KP_MULTIPLY), "*", "keypad multiply conversion")
assert_equal(capture_input.keycode_to_char(KP_ADD), "+", "keypad add conversion")
assert_equal(capture_input.keycode_to_char(KP_SEPARATOR), ",", "keypad separator conversion")
assert_equal(capture_input.keycode_to_char(KP_SUBTRACT), "-", "keypad subtract conversion")
assert_equal(capture_input.keycode_to_char(KP_DECIMAL), ".", "keypad decimal conversion")
assert_equal(capture_input.keycode_to_char(KP_DIVIDE), "/", "keypad divide conversion")
assert_equal(capture_input.keycode_to_char(KP_EQUAL), "=", "keypad equal conversion")
assert_equal(capture_input.keycode_to_char(0xa0), nil, "unsupported printable conversion")

assert(capture_input.is_printable_keysym(string.byte("~")))
assert(capture_input.is_printable_keysym(0xa0))
assert(capture_input.is_printable_keysym(0x01000100))
assert(not capture_input.is_printable_keysym(0xffbe))

assert(capture_input.is_modifier_key(0xffe1))
assert(capture_input.is_modifier_key(0xffee))
assert(not capture_input.is_modifier_key(0xffef))
assert(capture_input.is_shift_key(0xffe1))
assert(capture_input.is_shift_key(0xffe2))
assert(not capture_input.is_shift_key(0xffe3))

local select_keys = "1234567890"

assert_classification(string.byte("a"), false, false, select_keys, false, "query", "a")
assert_classification(string.byte("A"), false, false, select_keys, false, "literal", "A")
assert_classification(string.byte("a"), false, false, select_keys, true, "literal", "A")
assert_classification(string.byte("4"), false, false, select_keys, false, "literal", "4")
assert_classification(string.byte(" "), false, false, select_keys, false, "literal", " ")
assert_classification(string.byte("?"), false, false, select_keys, false, "literal", "?")
assert_classification(KP_ADD, false, false, select_keys, false, "literal", "+")

assert_classification(string.byte("2"), false, true, select_keys, false, "select", "2")
assert_classification(KP_2, false, true, select_keys, false, "select", "2")
assert_classification(string.byte(" "), false, true, select_keys, false, "select", " ")
assert_classification(string.byte(";"), false, true, select_keys, false, "select", ";")
assert_classification(string.byte("'"), false, true, select_keys, false, "select", "'")
assert_classification(string.byte("b"), false, true, select_keys, false, "query", "b")
assert_classification(string.byte("B"), false, true, select_keys, false, "consume", "B")
assert_classification(string.byte("b"), false, true, select_keys, true, "consume", "B")
assert_classification(KP_ADD, false, true, select_keys, false, "consume", "+")

assert_classification(string.byte("a"), true, false, select_keys, false, "literal", "a")
assert_classification(string.byte("a"), true, true, select_keys, false, "literal", "a")
assert_classification(string.byte("a"), true, false, select_keys, true, "literal", "A")
assert_classification(KP_MULTIPLY, true, false, select_keys, false, "literal", "*")
assert_classification(KP_ADD, true, false, select_keys, false, "literal", "+")
assert_classification(KP_SEPARATOR, true, false, select_keys, false, "literal", ",")
assert_classification(KP_SUBTRACT, true, false, select_keys, false, "literal", "-")
assert_classification(KP_DECIMAL, true, false, select_keys, false, "literal", ".")
assert_classification(KP_DIVIDE, true, false, select_keys, false, "literal", "/")
assert_classification(KP_EQUAL, true, false, select_keys, false, "literal", "=")

assert_classification(0xa0, false, false, select_keys, false, "consume", nil)
assert_classification(0x01000100, true, false, select_keys, false, "consume", nil)
assert_classification(0xffbe, false, false, select_keys, false, nil, nil)

assert_equal(capture_input.selection_index(7, string.byte("1"), 5, select_keys), 5, "main-row selection index")
assert_equal(capture_input.selection_index(7, KP_2, 5, select_keys), 6, "keypad selection index")
assert_equal(capture_input.selection_index(7, string.byte(";"), 5, select_keys), 6, "semicolon selection index")
assert_equal(capture_input.selection_index(7, string.byte("'"), 5, select_keys), 7, "apostrophe selection index")
assert_equal(capture_input.selection_index(7, string.byte(" "), 5, select_keys), nil, "Space keeps current selection")
assert_equal(capture_input.selection_index(7, string.byte("6"), 5, select_keys), nil, "selection outside page")
assert_equal(capture_input.selection_index(7, string.byte("x"), 5, "xyz"), 5, "custom selection keys")

assert_equal(capture_input.literal_char("", ",", false, false, false), "，", "Chinese half-shape comma")
assert_equal(capture_input.literal_char("", "/", false, false, false), "、", "Chinese half-shape slash")
assert_equal(capture_input.literal_char("", "@", false, false, false), "@", "unmapped half-shape punctuation")
assert_equal(capture_input.literal_char("", " ", false, false, false), " ", "half-shape space")
assert_equal(capture_input.literal_char("", "/", false, false, true), "／", "Chinese full-shape slash")
assert_equal(capture_input.literal_char("", "@", false, false, true), "＠", "Chinese full-shape at sign")
assert_equal(capture_input.literal_char("", " ", false, false, true), "　", "Chinese full-shape space")

assert_equal(capture_input.literal_char("", "'", false, false, false), "‘", "opening single quote")
assert_equal(capture_input.literal_char("‘word", "'", false, false, false), "’", "closing single quote")
assert_equal(capture_input.literal_char("‘word’", "'", false, false, false), "‘", "next opening single quote")
assert_equal(capture_input.literal_char("", '"', false, false, true), "“", "opening double quote")
assert_equal(capture_input.literal_char("“word", '"', false, false, true), "”", "closing double quote")

assert_equal(capture_input.literal_char("", ",", true, false, true), ",", "English punctuation remains ASCII")
assert_equal(capture_input.literal_char("", "'", true, false, false), "'", "English quote remains ASCII")
assert_equal(capture_input.literal_char("", "/", false, true, true), "/", "ascii_punct remains ASCII")
assert_equal(capture_input.literal_char("", '"', false, true, false), '"', "ascii_punct quote remains ASCII")

print("tiger capture input tests passed")
