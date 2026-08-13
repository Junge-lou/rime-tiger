package.path = "./lua/?.lua;" .. package.path

rime_api = {
  regex_match = function(text)
    return text:match("[^0-9A-Za-z%s]") ~= nil
  end,
}

local space_proc = require("space_proc3")

local kAccepted = 1
local kNoop = 2

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
  end
end

local function runtime(input, tags)
  tags = tags or {}
  local state = { clear_count = 0 }
  local segment = {
    start = 0,
    _end = #input,
    has_tag = function(_, tag)
      return tags[tag] or false
    end,
  }
  local context = {
    input = input,
    composition = {
      back = function()
        return segment
      end,
      toSegmentation = function()
        return {
          back = function()
            return segment
          end,
        }
      end,
    },
    has_menu = function()
      return false
    end,
    clear = function()
      state.clear_count = state.clear_count + 1
    end,
  }
  local env = {
    hasecho = false,
    engine = {
      context = context,
      commit_text = function() end,
    },
  }
  return env, state
end

local function space_key()
  return {
    keycode = 0x20,
    repr = function() return "space" end,
    release = function() return false end,
    alt = function() return false end,
    ctrl = function() return false end,
    caps = function() return false end,
  }
end

local function test_space_preserves_pending_digit_separator()
  local env, state = runtime(".", { punct_number = true })
  assert_equal(space_proc.func(space_key(), env), kNoop,
    "space after a numeric separator must continue to punctuator")
  assert_equal(state.clear_count, 0, "pending decimal point must remain in composition")
end

local function test_space_still_clears_ordinary_empty_code()
  local env, state = runtime("zzzz")
  assert_equal(space_proc.func(space_key(), env), kAccepted,
    "space still consumes an ordinary empty code")
  assert_equal(state.clear_count, 1, "ordinary empty code is cleared")
end

test_space_preserves_pending_digit_separator()
test_space_still_clears_ordinary_empty_code()

print("space_proc3 tests passed")
