package.path = "./lua/?.lua;" .. package.path

local trigger = require("tiger_add_trigger")

assert(trigger.can_append("abcd"))
assert(trigger.can_append("abcd\\"))
assert(not trigger.can_append(""))
assert(not trigger.can_append("\\djs"))
assert(not trigger.can_append("abcd\\\\"))

assert(trigger.target_code("abcd\\\\") == "abcd")
assert(trigger.target_code("abcd\\") == nil)
assert(trigger.target_code("\\\\") == nil)
assert(trigger.target_code("\\djs\\\\") == nil)
assert(trigger.target_code("ab\\cd\\\\") == nil)

local temp_dir = os.tmpname()
os.remove(temp_dir)
assert(os.execute("mkdir -p " .. temp_dir))

local errors = {}
rime_api = {
  get_user_data_dir = function()
    return temp_dir
  end,
}
log = {
  error = function(message)
    table.insert(errors, message)
  end,
}

local function write_file(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

write_file(temp_dir .. "/tiger.dict.yaml", "TigerSource\ttsrc\t100\n")
write_file(temp_dir .. "/tigress.dict.yaml", "TigressSource\t100\tqwer\n")

local function notifier()
  return {
    connect = function(_, _)
      return { disconnect = function() end }
    end,
  }
end

local function new_init_env(schema_id)
  return {
    engine = {
      schema = {
        schema_id = schema_id,
        page_size = 5,
      },
      context = {
        update_notifier = notifier(),
        select_notifier = notifier(),
      },
    },
  }
end

local words = require("tiger_user_words")
local tiger_env = new_init_env("tiger")
local second_tiger_env = new_init_env("tiger")
local tigress_env = new_init_env("tigress")

words.processor.init(tiger_env)
words.processor.init(second_tiger_env)
words.processor.init(tigress_env)

assert(tiger_env.state.config.extended_dict == "tiger.user.dict.yaml")
assert(tigress_env.state.config.extended_dict == "tigress.user.dict.yaml")
assert(tiger_env.state == second_tiger_env.state)
assert(tiger_env.state ~= tigress_env.state)
assert(io.open(temp_dir .. "/tiger.user.dict.yaml", "r"))
assert(io.open(temp_dir .. "/tigress.user.dict.yaml", "r"))
assert(require("tigress_user_words") == words)

local unknown_env = new_init_env("unknown")
words.processor.init(unknown_env)
assert(unknown_env.state == nil)
assert(#errors == 1)

local function candidate(text)
  return { type = "mock", text = text, comment = "" }
end

local function new_runtime_env(schema_id, input, candidate_texts, selected_index)
  local env = new_init_env(schema_id)
  local candidates = {}
  for _, text in ipairs(candidate_texts or {}) do
    table.insert(candidates, candidate(text))
  end

  local segment = {
    _start = 0,
    _end = #input,
    selected_index = selected_index or 0,
    menu = {
      prepare = function() end,
      get_candidate_at = function(_, index)
        return candidates[index + 1]
      end,
    },
  }
  local context = {
    input = input,
    update_notifier = notifier(),
    select_notifier = notifier(),
    refresh_count = 0,
  }
  context.composition = {
    empty = function()
      return context.input == ""
    end,
    back = function()
      segment._end = #context.input
      return segment
    end,
  }
  function context:push_input(text)
    self.input = self.input .. text
    segment._end = #self.input
  end
  function context:clear()
    self.input = ""
    segment._end = 0
  end
  function context:refresh_non_confirmed_composition()
    self.refresh_count = self.refresh_count + 1
    segment._end = #self.input
  end
  function context:get_selected_candidate()
    return candidates[segment.selected_index + 1]
  end
  env.engine.context = context
  env.segment = segment
  return env
end

local function key(keycode, modifiers)
  modifiers = modifiers or {}
  return {
    keycode = keycode,
    ctrl = function() return modifiers.ctrl or false end,
    alt = function() return modifiers.alt or false end,
    shift = function() return modifiers.shift or false end,
    release = function() return modifiers.release or false end,
  }
end

local function plain_key(keycode)
  return key(keycode)
end

local function ctrl_key(keycode)
  return key(keycode, { ctrl = true })
end

Candidate = function(candidate_type, start, finish, text, comment)
  return {
    type = candidate_type,
    start = start,
    _end = finish,
    text = text,
    comment = comment,
  }
end

local function empty_input()
  return {
    iter = function()
      return function() return nil end
    end,
  }
end

for _, schema_id in ipairs({ "tiger", "tigress" }) do
  local fallback_env = new_runtime_env(schema_id, "abcd", { "甲", "乙" })
  words.processor.init(fallback_env)
  assert(words.processor.func(plain_key(0x5c), fallback_env) == 1)
  assert(fallback_env.engine.context.input == "abcd\\")
  assert(words.processor.func(plain_key(0x5c), fallback_env) == 1)
  assert(fallback_env.engine.context.input == "abcd\\\\")
  assert(words.processor.func(plain_key(0x20), fallback_env) == 1)
  assert(fallback_env.capture.code == "abcd")
  assert(fallback_env.capture.operation == "add")

  local command_env = new_runtime_env(schema_id, "\\djs", {})
  words.processor.init(command_env)
  assert(words.processor.func(plain_key(0x5c), command_env) == 2)
  assert(command_env.engine.context.input == "\\djs")

  local added_text = schema_id == "tiger" and "TigerAdded" or "TigressAdded"
  local add_env = new_runtime_env(schema_id, "efgh", { added_text })
  words.processor.init(add_env)
  assert(words.processor.func(ctrl_key(0x3b), add_env) == 1)
  assert(add_env.capture.code == "efgh")
  assert(add_env.capture.operation == "add")
  assert(words.processor.func(plain_key(0x61), add_env) == 1)
  assert(words.processor.func(plain_key(0x20), add_env) == 1)
  assert(add_env.capture.text == added_text)
  assert(words.processor.func(plain_key(0xff0d), add_env) == 1)
  assert(add_env.capture == nil)
  local user_dict = read_file(temp_dir .. "/" .. schema_id .. ".user.dict.yaml")
  assert(user_dict:find(added_text .. "\tefgh\t", 1, true))

  local disable_code = schema_id == "tiger" and "tsrc" or "qwer"
  local disable_text = schema_id == "tiger" and "TigerSource" or "TigressSource"
  local disable_env = new_runtime_env(schema_id, disable_code, { disable_text })
  words.processor.init(disable_env)
  assert(words.processor.func(ctrl_key(0x27), disable_env) == 1)
  assert(disable_env.capture.code == disable_code)
  assert(disable_env.capture.text == disable_text)
  assert(disable_env.capture.operation == "disable")
  assert(words.processor.func(plain_key(0xff0d), disable_env) == 1)
  assert(disable_env.state.blocked[disable_code][disable_text])
  local source_dict = read_file(temp_dir .. "/" .. schema_id .. ".dict.yaml")
  assert(source_dict:find("# " .. disable_text, 1, true))

  local reorder_env = new_runtime_env(schema_id, "mnop", { "第一", "第二" }, 1)
  words.processor.init(reorder_env)
  assert(words.processor.func(ctrl_key(0xff52), reorder_env) == 1)
  assert(reorder_env.state.weights.mnop["第二"] == reorder_env.state.config.weight_base)
  assert(reorder_env.state.weights.mnop["第一"] == reorder_env.state.config.weight_base - reorder_env.state.config.weight_step)

  local status_env = new_runtime_env(schema_id, "qrst\\\\", {})
  words.processor.init(status_env)
  words.filter.init(status_env)
  local yielded = {}
  yield = function(cand)
    table.insert(yielded, cand)
  end
  words.filter.func(empty_input(), status_env)
  assert(#yielded == 1)
  assert(yielded[1].type == "tiger_user_status")
  assert(yielded[1].comment == "空格进入加词")
end

local tiger_user = read_file(temp_dir .. "/tiger.user.dict.yaml")
local tigress_user = read_file(temp_dir .. "/tigress.user.dict.yaml")
assert(tiger_user:find("TigerAdded", 1, true))
assert(not tiger_user:find("TigressAdded", 1, true))
assert(tigress_user:find("TigressAdded", 1, true))
assert(not tigress_user:find("TigerAdded", 1, true))

assert(os.remove(temp_dir .. "/tiger.user.dict.yaml"))
assert(os.remove(temp_dir .. "/tigress.user.dict.yaml"))
assert(os.remove(temp_dir .. "/tiger.dict.yaml"))
assert(os.remove(temp_dir .. "/tigress.dict.yaml"))
assert(os.remove(temp_dir))

print("tiger_user_words tests passed")
