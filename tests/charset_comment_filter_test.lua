package.path = "./lua/?.lua;" .. package.path

local filter = require("charset_comment_filter")

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
  end
end

local function find_upvalue(fn, target)
  local index = 1
  while true do
    local name, value = debug.getupvalue(fn, index)
    if not name then
      return nil
    end
    if name == target then
      return value
    end
    index = index + 1
  end
end

local charset_name = find_upvalue(filter, "charset_name")
assert_equal(type(charset_name), "function", "filter should use direct charset lookup")
assert_equal(charset_name("你"), "[基本]", "basic CJK block")
assert_equal(charset_name("𠀀"), "[扩B]", "extension B block")
assert_equal(charset_name("😀"), "[表情]", "emoji block")
assert_equal(charset_name("你好"), "[基本]", "same-block phrase")
assert_equal(charset_name("你A"), nil, "mixed-block phrase")

local function run_filter(text, enabled)
  local cand = {
    text = text,
    comment = "原注释",
    get_genuine = function(self)
      return self
    end,
  }
  local input = {
    iter = function()
      local yielded = false
      return function()
        if yielded then
          return nil
        end
        yielded = true
        return cand
      end
    end,
  }
  local env = {
    engine = {
      context = {
        get_option = function()
          return enabled
        end,
      },
    },
  }
  local output
  yield = function(value)
    output = value
  end
  filter(input, env)
  return output
end

assert_equal(run_filter("你", true).comment, "原注释 [基本]", "enabled annotation")
assert_equal(run_filter("你", false).comment, "原注释", "disabled annotation")

print("charset_comment_filter tests passed")
