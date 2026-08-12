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
write_file(temp_dir .. "/tiger.user.dict.yaml", "# Rime dictionary: tiger.user\n---\nname: tiger.user\n...\nLegacyTiger\tlgcy\t42\n！\ta\t0\n")
write_file(temp_dir .. "/tigress.user.dict.yaml", "# Rime dictionary: tigress.user\n---\nname: tigress.user\n...\nLegacyTigress\tlgcy\t43\n")

local databases = {}
local db_update_count = 0
local db_query_modes = {}
local database_write_failures = {}
local function db_accessor(data, prefix)
  local keys = {}
  for key, _ in pairs(data) do
    if key:sub(1, #prefix) == prefix then
      table.insert(keys, key)
    end
  end
  table.sort(keys)
  return {
    iter = function()
      local index = 0
      return function()
        index = index + 1
        local key = keys[index]
        return key, key and data[key] or nil
      end
    end,
  }
end

LevelDb = function(name)
  local data = databases[name] or {}
  databases[name] = data
  return {
    loaded = function() return true end,
    open = function() end,
    close = function() end,
    update = function(_, key, value)
      db_update_count = db_update_count + 1
      if database_write_failures[name] then
        return false
      end
      data[key] = value
      return true
    end,
    query = function(_, prefix)
      if prefix == "" and db_query_modes[name] == "nil" then
        return nil
      end
      if prefix == "" and db_query_modes[name] == "throw" then
        error("mock query failure")
      end
      if prefix == "" and db_query_modes[name] == "throw_iterator" then
        return { iter = function() error("mock iterator failure") end }
      end
      if prefix == "" and db_query_modes[name] == "empty" then
        return db_accessor({}, "")
      end
      return db_accessor(data, prefix or "")
    end,
  }
end

local function notifier()
  return {
    connect = function(_, _)
      return { disconnect = function() end }
    end,
  }
end

local function new_init_env(schema_id)
  local properties = {}
  local options = {
    ascii_mode = false,
    ascii_punct = false,
    full_shape = false,
  }
  local context = {
    update_notifier = notifier(),
    select_notifier = notifier(),
  }
  function context:get_property(name)
    return properties[name] or ""
  end
  function context:set_property(name, value)
    properties[name] = value
  end
  function context:get_option(name)
    return options[name] or false
  end
  function context:set_option(name, value)
    options[name] = value
  end
  return {
    engine = {
      schema = {
        schema_id = schema_id,
        page_size = 5,
      },
      context = context,
    },
  }
end

local words = require("tiger_user_words")
local function capture_of(env)
  return words._test.get_capture(env.engine)
end
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
  if type(text) == "table" then
    local cand = { type = "mock", text = text.display, comment = "" }
    function cand:get_genuine()
      return { text = text.genuine }
    end
    return cand
  end
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
  local context = env.engine.context
  context.input = input
  context.refresh_count = 0
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
    super = function() return modifiers.super or false end,
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

local function candidate_input(texts)
  local candidates = {}
  for _, text in ipairs(texts) do
    table.insert(candidates, candidate(text))
  end
  return {
    iter = function()
      local index = 0
      return function()
        index = index + 1
        return candidates[index]
      end
    end,
  }
end

local function filter_output(env, input)
  local output = {}
  yield = function(cand)
    table.insert(output, cand)
  end
  words.filter.func(input or empty_input(), env)
  return output
end

do
  local engine_a = new_runtime_env("tiger", "isola", {})
  local engine_b = new_runtime_env("tiger", "isolb", {})
  words.processor.init(engine_a)
  words.processor.init(engine_b)

  local filter_a = { engine = engine_a.engine }
  local filter_b = { engine = engine_b.engine }
  words.filter.init(filter_a)
  words.filter.init(filter_b)

  assert(words.processor.func(ctrl_key(0x3b), engine_a) == 1)
  local output_a = filter_output(filter_a)
  local output_b = filter_output(filter_b)
  assert(#output_a == 1 and output_a[1].type == "tiger_user_status")
  assert(#output_b == 0, "capture leaked between same-schema engines")
  assert(engine_a.state.capture == nil)

  assert(words.processor.func(ctrl_key(0x3b), engine_b) == 1)
  assert(words.processor.func(plain_key(0xff1b), engine_a) == 1)
  output_b = filter_output(filter_b)
  assert(#output_b == 1 and output_b[1].text:find("isolb", 1, true))
  assert(words.processor.func(plain_key(0xff1b), engine_b) == 1)
end

do
  local tiger_capture = new_runtime_env("tiger", "tigeriso", {})
  local tigress_capture = new_runtime_env("tigress", "tigressiso", {})
  words.processor.init(tiger_capture)
  words.processor.init(tigress_capture)
  words.filter.init(tiger_capture)
  words.filter.init(tigress_capture)

  assert(words.processor.func(ctrl_key(0x3b), tiger_capture) == 1)
  assert(#filter_output(tiger_capture) == 1)
  assert(#filter_output(tigress_capture) == 0, "capture leaked across schemas")
  assert(words.processor.func(plain_key(0xff1b), tiger_capture) == 1)
end

do
  local quick_symbol_env = new_runtime_env("tiger", "a", { "来", "！" })
  words.processor.init(quick_symbol_env)
  words.filter.init(quick_symbol_env)
  local output = filter_output(quick_symbol_env, candidate_input({ "来", "！" }))
  assert(output[1].text == "来", "zero-weight quick symbol should keep dictionary order")
  assert(output[2].text == "！")
  output = filter_output(quick_symbol_env, candidate_input({ "来" }))
  assert(output[1].text == "来", "missing zero-weight quick symbol should append after dictionary candidates")
  assert(output[2].text == "！")
  quick_symbol_env.state.added.a = nil
  quick_symbol_env.state.weights.a = nil
end

for _, schema_id in ipairs({ "tiger", "tigress" }) do
  local fallback_env = new_runtime_env(schema_id, "abcd", { "甲", "乙" })
  words.processor.init(fallback_env)
  assert(words.processor.func(plain_key(0x5c), fallback_env) == 1)
  assert(fallback_env.engine.context.input == "abcd\\")
  assert(words.processor.func(plain_key(0x5c), fallback_env) == 1)
  assert(fallback_env.engine.context.input == "abcd\\\\")
  assert(words.processor.func(plain_key(0x20), fallback_env) == 1)
  assert(capture_of(fallback_env).code == "abcd")
  assert(capture_of(fallback_env).operation == "add")

  local command_env = new_runtime_env(schema_id, "\\djs", {})
  words.processor.init(command_env)
  assert(words.processor.func(plain_key(0x5c), command_env) == 2)
  assert(command_env.engine.context.input == "\\djs")

  local added_text = schema_id == "tiger" and "TigerAdded" or "TigressAdded"
  local add_env = new_runtime_env(schema_id, "efgh", { added_text })
  words.processor.init(add_env)
  assert(words.processor.func(ctrl_key(0x3b), add_env) == 1)
  assert(capture_of(add_env).code == "efgh")
  assert(capture_of(add_env).operation == "add")
  assert(words.processor.func(plain_key(0x61), add_env) == 1)
  assert(words.processor.func(plain_key(0x20), add_env) == 1)
  assert(capture_of(add_env).text == added_text)
  assert(words.processor.func(plain_key(0xff0d), add_env) == 1)
  assert(capture_of(add_env) == nil)
  local user_dict = read_file(temp_dir .. "/" .. schema_id .. ".user.dict.yaml")
  assert(not user_dict:find(added_text .. "\tefgh\t", 1, true))

  local disable_code = schema_id == "tiger" and "tsrc" or "qwer"
  local disable_text = schema_id == "tiger" and "TigerSource" or "TigressSource"
  local disable_env = new_runtime_env(schema_id, disable_code, { disable_text })
  words.processor.init(disable_env)
  assert(words.processor.func(ctrl_key(0x27), disable_env) == 1)
  assert(capture_of(disable_env).code == disable_code)
  assert(capture_of(disable_env).text == disable_text)
  assert(capture_of(disable_env).operation == "disable")
  assert(words.processor.func(plain_key(0xff0d), disable_env) == 1)
  assert(disable_env.state.blocked[disable_code][disable_text])
  local source_dict = read_file(temp_dir .. "/" .. schema_id .. ".dict.yaml")
  assert(not source_dict:find("# " .. disable_text, 1, true))

  local reorder_env = new_runtime_env(schema_id, "mnop", { "第一", "第二" }, 1)
  words.processor.init(reorder_env)
  assert(words.processor.func(ctrl_key(0xff52), reorder_env) == 1)
  assert(reorder_env.state.weights.mnop["第二"] == reorder_env.state.config.weight_base)
  assert(reorder_env.state.weights.mnop["第一"] == reorder_env.state.config.weight_base - reorder_env.state.config.weight_step)
  assert(not (reorder_env.state.added.mnop and reorder_env.state.added.mnop["第一"]))

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

local runtime_failures = {}
local function runtime_case(name, func)
  local ok, message = xpcall(func, debug.traceback)
  if not ok then
    table.insert(runtime_failures, name .. ": " .. message)
  end
end

runtime_case("capture metadata without mode-switch hints", function()
  local env = new_runtime_env("tiger", "meta", {})
  words.processor.init(env)
  words.filter.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  local capture = capture_of(env)
  assert(capture.code == "meta" and capture.text == "" and capture.query == "")
  assert(capture.operation == "add" and capture.message == "")
  assert(capture.original_ascii_mode == false)
  assert(capture.shift_key == nil and capture.shift_used == false)
  local output = filter_output(env)
  assert(output[1].comment == "Enter确认  Esc取消  Backspace删除")
  assert(not output[1].comment:find("Shift", 1, true))
  assert(not output[1].comment:find("Ctrl+;", 1, true))
  assert(not output[1].comment:find("中文取词", 1, true))
  assert(not output[1].comment:find("英文直录", 1, true))
  env.engine.context:set_option("ascii_mode", true)
  output = filter_output(env)
  assert(output[1].comment == "Enter确认  Esc取消  Backspace删除")
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("bare Shift toggles and Shift letter does not", function()
  local env = new_runtime_env("tiger", "shift", {})
  words.processor.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  local capture = capture_of(env)
  assert(words.processor.func(key(0xffe1, { shift = true }), env) == 1)
  assert(capture.shift_key == 0xffe1 and capture.shift_used == false)
  assert(words.processor.func(key(0xffe1, { release = true }), env) == 1)
  assert(env.engine.context:get_option("ascii_mode") == true)

  assert(words.processor.func(key(0xffe2, { shift = true }), env) == 1)
  assert(words.processor.func(key(0x61, { shift = true }), env) == 1)
  assert(words.processor.func(key(0x61, { shift = true, release = true }), env) == 1)
  assert(words.processor.func(key(0xffe2, { release = true }), env) == 1)
  assert(capture.text == "A")
  assert(env.engine.context:get_option("ascii_mode") == true)
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("modified Shift gestures do not arm or toggle", function()
  local env = new_runtime_env("tiger", "modshift", {})
  words.processor.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  local capture = capture_of(env)

  for _, modifiers in ipairs({
    { ctrl = true },
    { alt = true },
    { super = true },
  }) do
    local pressed = {
      ctrl = modifiers.ctrl,
      alt = modifiers.alt,
      super = modifiers.super,
      shift = true,
    }
    local released = {
      ctrl = modifiers.ctrl,
      alt = modifiers.alt,
      super = modifiers.super,
      release = true,
    }
    assert(words.processor.func(key(0xffe1, pressed), env) == 1)
    assert(capture.shift_key == nil and capture.shift_used == false)
    assert(words.processor.func(key(0xffe1, released), env) == 1)
    assert(env.engine.context:get_option("ascii_mode") == false)
    assert(capture.shift_key == nil and capture.shift_used == false)
  end

  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("dual Shift gestures never toggle", function()
  local function assert_dual_shift(first, second, release_first, release_second)
    local env = new_runtime_env("tiger", "dualshift", {})
    words.processor.init(env)
    assert(words.processor.func(ctrl_key(0x3b), env) == 1)
    local capture = capture_of(env)

    assert(words.processor.func(key(first, { shift = true }), env) == 1)
    assert(capture.shift_key == first and capture.shift_used == false)
    assert(words.processor.func(key(second, { shift = true }), env) == 1)
    assert(capture.shift_key == first and capture.shift_used == true)
    assert(words.processor.func(key(release_first, { release = true }), env) == 1)
    assert(env.engine.context:get_option("ascii_mode") == false)
    assert(words.processor.func(key(release_second, { release = true }), env) == 1)
    assert(env.engine.context:get_option("ascii_mode") == false)
    assert(capture.shift_key == nil and capture.shift_used == false)
    words.processor.func(plain_key(0xff1b), env)
  end

  assert_dual_shift(0xffe1, 0xffe2, 0xffe2, 0xffe1)
  assert_dual_shift(0xffe2, 0xffe1, 0xffe2, 0xffe1)
end)

runtime_case("English lowercase spaces punctuation and keypad literals", function()
  local env = new_runtime_env("tiger", "english", {})
  env.engine.context:set_option("ascii_mode", true)
  words.processor.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  for _, keycode in ipairs({ 0x68, 0x69, 0x20, 0x74, 0x68, 0x65, 0x72, 0x65, 0x2c, 0xffb2, 0xffab }) do
    assert(words.processor.func(plain_key(keycode), env) == 1)
  end
  local capture = capture_of(env)
  assert(capture.query == "")
  assert(capture.text == "hi there,2+")
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("Chinese literal and genuine candidate flow", function()
  local env = new_runtime_env("tiger", "mixed", {
    { display = "转换显示", genuine = "真实候选" },
    "第二候选",
  })
  words.processor.init(env)
  words.filter.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  assert(words.processor.func(key(0x78, { shift = true }), env) == 1)
  assert(words.processor.func(plain_key(0x34), env) == 1)
  assert(words.processor.func(plain_key(0x61), env) == 1)
  local query_output = filter_output(env, candidate_input({ "查询一", "查询二" }))
  assert(#query_output == 2)
  assert(query_output[1].type ~= "tiger_user_status")
  assert(words.processor.func(plain_key(0x20), env) == 1)
  local capture = capture_of(env)
  assert(capture.text == "X4真实候选" and capture.query == "")

  assert(words.processor.func(plain_key(0x62), env) == 1)
  assert(words.processor.func(plain_key(0x32), env) == 1)
  assert(capture.text == "X4真实候选第二候选" and capture.query == "")
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("Chinese keypad and punctuation conversion", function()
  local env = new_runtime_env("tiger", "punct", {})
  words.processor.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  for _, keycode in ipairs({ 0xffb7, 0xffae, 0xffac, 0xffaf }) do
    assert(words.processor.func(plain_key(keycode), env) == 1)
  end
  env.engine.context:set_option("full_shape", true)
  assert(words.processor.func(plain_key(0x40), env) == 1)
  env.engine.context:set_option("ascii_punct", true)
  assert(words.processor.func(plain_key(0x2c), env) == 1)
  assert(capture_of(env).text == "7。，、＠,")
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("unsafe and unsupported input is consumed", function()
  local env = new_runtime_env("tiger", "consume", {})
  words.processor.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  local capture = capture_of(env)
  for _, event in ipairs({
    key(0x62, { ctrl = true }),
    key(0x62, { alt = true }),
    key(0x62, { super = true }),
    key(0x3b, { ctrl = true }),
    key(0xa0),
    key(0xff0d, { shift = true }),
    key(0xff08, { ctrl = true }),
    key(0x62, { release = true }),
  }) do
    assert(words.processor.func(event, env) == 1)
  end
  assert(capture.text == "" and capture.query == "")
  assert(capture_of(env) == capture)
  assert(env.engine.context:get_option("ascii_mode") == false)
  for _, keycode in ipairs({ 0xff09, 0xffff, 0xffbe }) do
    assert(words.processor.func(plain_key(keycode), env) == 1)
    assert(capture.text == "" and capture.query == "")
  end
  assert(words.processor.func(plain_key(0xff51), env) == 2)
  assert(words.processor.func(key(0xff51, { shift = true }), env) == 1)
  assert(words.processor.func(key(0xff56, { shift = true }), env) == 1)
  assert(capture.text == "" and capture.query == "")
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("Unicode backspace prefers query", function()
  local env = new_runtime_env("tiger", "erase", { "中文" })
  words.processor.init(env)
  assert(words.processor.func(ctrl_key(0x3b), env) == 1)
  words.processor.func(plain_key(0x61), env)
  words.processor.func(plain_key(0x20), env)
  local capture = capture_of(env)
  assert(capture.text == "中文")
  words.processor.func(plain_key(0xff08), env)
  assert(capture.text == "中")
  words.processor.func(plain_key(0x61), env)
  words.processor.func(plain_key(0x62), env)
  words.processor.func(plain_key(0xff08), env)
  assert(capture.query == "a" and capture.text == "中")
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("empty save preserves capture with transient message", function()
  local env = new_runtime_env("tiger", "empty", {})
  words.processor.init(env)
  words.filter.init(env)
  words.processor.func(ctrl_key(0x3b), env)
  local capture = capture_of(env)
  assert(words.processor.func(plain_key(0xff0d), env) == 1)
  assert(capture_of(env) == capture)
  assert(capture.message == "请先选择或输入要加入的词")
  assert(filter_output(env)[1].comment == capture.message)
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("persistence failure preserves capture and text", function()
  local env = new_runtime_env("tiger", "retry", {})
  env.engine.context:set_option("ascii_mode", true)
  words.processor.init(env)
  words.processor.func(ctrl_key(0x3b), env)
  words.processor.func(plain_key(0x78), env)
  local capture = capture_of(env)
  database_write_failures.tiger_user_words_tiger = true
  assert(words.processor.func(plain_key(0xff8d), env) == 1)
  database_write_failures.tiger_user_words_tiger = nil
  assert(capture_of(env) == capture and capture.text == "x")
  assert(capture.message == "保存失败，请重试")
  assert(env.engine.context:get_option("ascii_mode") == true)
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("ascii mode restores after save cancel and fini", function()
  local save_env = new_runtime_env("tiger", "saved", {})
  words.processor.init(save_env)
  words.processor.func(ctrl_key(0x3b), save_env)
  words.processor.func(key(0xffe1, { shift = true }), save_env)
  words.processor.func(key(0xffe1, { release = true }), save_env)
  words.processor.func(plain_key(0x78), save_env)
  assert(words.processor.func(plain_key(0xff8d), save_env) == 1)
  assert(capture_of(save_env) == nil)
  assert(save_env.engine.context:get_option("ascii_mode") == false)
  assert(save_env.engine.context.input == "saved")

  local cancel_env = new_runtime_env("tiger", "cancel", {})
  cancel_env.engine.context:set_option("ascii_mode", true)
  words.processor.init(cancel_env)
  words.processor.func(ctrl_key(0x3b), cancel_env)
  words.processor.func(key(0xffe1, { shift = true }), cancel_env)
  words.processor.func(key(0xffe1, { release = true }), cancel_env)
  assert(cancel_env.engine.context:get_option("ascii_mode") == false)
  words.processor.func(plain_key(0x37), cancel_env)
  assert(words.processor.func(plain_key(0xff1b), cancel_env) == 1)
  assert(capture_of(cancel_env) == nil)
  assert(cancel_env.engine.context:get_option("ascii_mode") == true)
  assert(databases.tiger_user_words_tiger["cancel \t7"] == nil)

  local fini_env = new_runtime_env("tiger", "final", {})
  words.processor.init(fini_env)
  words.processor.func(ctrl_key(0x3b), fini_env)
  words.processor.func(key(0xffe1, { shift = true }), fini_env)
  words.processor.func(key(0xffe1, { release = true }), fini_env)
  words.processor.func(plain_key(0x78), fini_env)
  words.processor.fini(fini_env)
  assert(capture_of(fini_env) == nil)
  assert(fini_env.engine.context:get_option("ascii_mode") == false)
  assert(databases.tiger_user_words_tiger["final \tx"] == nil)
end)

assert(#runtime_failures == 0, table.concat(runtime_failures, "\n\n"))

local tiger_user = read_file(temp_dir .. "/tiger.user.dict.yaml")
local tigress_user = read_file(temp_dir .. "/tigress.user.dict.yaml")
assert(not tiger_user:find("TigerAdded", 1, true))
assert(not tigress_user:find("TigressAdded", 1, true))
assert(not tigress_user:find("TigerAdded", 1, true))
assert(databases["tiger_user_words_tiger"]["efgh \tTigerAdded"])
assert(databases["tiger_user_words_tigress"]["efgh \tTigressAdded"])
assert(databases["tiger_user_words_tiger"]["lgcy \tLegacyTiger"])
assert(databases["tiger_user_words_tigress"]["lgcy \tLegacyTigress"])

package.loaded["tiger_user_words"] = nil
package.loaded["tigress_user_words"] = nil
local reloaded_words = require("tiger_user_words")
local reloaded_env = new_runtime_env("tiger", "mnop", { "第一", "第二" })
reloaded_words.processor.init(reloaded_env)
assert(reloaded_env.state.added.efgh.TigerAdded)
assert(reloaded_env.state.blocked.tsrc.TigerSource)
assert(reloaded_env.state.weights.mnop["第二"] == reloaded_env.state.config.weight_base)
assert(reloaded_env.state.weights.mnop["第一"] == reloaded_env.state.config.weight_base - reloaded_env.state.config.weight_step)

local reloaded_quick_symbol_env = new_runtime_env("tiger", "a", { "来", "！" })
reloaded_words.filter.init(reloaded_quick_symbol_env)
assert(reloaded_quick_symbol_env.state.weights.a["！"] == 0)
local reloaded_quick_symbol_output = filter_output(reloaded_quick_symbol_env, candidate_input({ "来", "！" }))
assert(reloaded_quick_symbol_output[1].text == "来", "reloaded zero-weight quick symbol should keep dictionary order")
assert(reloaded_quick_symbol_output[2].text == "！")

local function find_snapshot_record(snapshot, code, text)
  for _, record in ipairs(snapshot) do
    if record.code == code and record.text == text then
      return record
    end
  end
end

local tiger_db_name = "tiger_user_words_tiger"
local writes_before_snapshot = db_update_count
local librime_metadata = {
  ["\1/db_name"] = tiger_db_name,
  ["\1/db_type"] = "userdb",
  ["\1/rime_version"] = "1.16.0",
  ["\1/user_id"] = "test-installation-id",
}
for key, value in pairs(librime_metadata) do
  databases["tiger_user_words_tiger"][key] = value
  databases["tiger_user_words_tigress"][key] = value
end
local tiger_snapshot = reloaded_words.export_snapshot("tiger")
local tiger_added = assert(find_snapshot_record(tiger_snapshot, "efgh", "TigerAdded"))
local tiger_source = assert(find_snapshot_record(tiger_snapshot, "tsrc", "TigerSource"))
local tiger_second = assert(find_snapshot_record(tiger_snapshot, "mnop", "第二"))
assert(tiger_added.added == true)
assert(tiger_source.hidden == true)
assert(tiger_second.weight == 100000000000)
assert(tiger_added.updated_at == nil)
assert(tiger_added.record == nil)

local tigress_snapshot = reloaded_words.export_snapshot("tigress")
assert(find_snapshot_record(tigress_snapshot, "efgh", "TigressAdded"))
assert(not find_snapshot_record(tigress_snapshot, "efgh", "TigerAdded"))

tiger_added.text = "Mutated"
tiger_added.added = false
local isolated_snapshot = reloaded_words.export_snapshot("tiger")
local isolated_added = assert(find_snapshot_record(isolated_snapshot, "efgh", "TigerAdded"))
assert(isolated_added.text == "TigerAdded")
assert(isolated_added.added == true)
assert(db_update_count == writes_before_snapshot)

assert(reloaded_words.export_snapshot("unknown") == nil)

local saved_level_db = LevelDb
LevelDb = nil
local unavailable_snapshot, unavailable_error = reloaded_words.export_snapshot("tiger")
assert(unavailable_snapshot == nil)
assert(unavailable_error == "用户词数据库不可用")
LevelDb = saved_level_db

db_query_modes[tiger_db_name] = "nil"
local nil_query_snapshot, nil_query_error = reloaded_words.export_snapshot("tiger")
assert(nil_query_snapshot == nil)
assert(nil_query_error == "用户词数据库不可用")
assert(db_update_count == writes_before_snapshot)

db_query_modes[tiger_db_name] = "throw"
local thrown_query_snapshot, thrown_query_error = reloaded_words.export_snapshot("tiger")
assert(thrown_query_snapshot == nil)
assert(thrown_query_error == "用户词数据库不可用")
assert(db_update_count == writes_before_snapshot)

db_query_modes[tiger_db_name] = "throw_iterator"
local thrown_iterator_snapshot, thrown_iterator_error = reloaded_words.export_snapshot("tiger")
assert(thrown_iterator_snapshot == nil)
assert(thrown_iterator_error == "用户词数据库不可用")
assert(db_update_count == writes_before_snapshot)

db_query_modes[tiger_db_name] = "empty"
local empty_snapshot, empty_error = reloaded_words.export_snapshot("tiger")
assert(type(empty_snapshot) == "table")
assert(#empty_snapshot == 0)
assert(empty_error == nil)
assert(db_update_count == writes_before_snapshot)
db_query_modes[tiger_db_name] = nil

local valid_db_value = "v=1 a=1 h=0 w=1 t=1"
local corrupt_records = {
  { label = "missing separator", key = "malformed-key", value = valid_db_value },
  { label = "empty code", key = " \tEmptyCode", value = valid_db_value },
  { label = "empty text", key = "empty \t", value = valid_db_value },
  { label = "malformed value", key = "bad-value \tCorrupt", value = "not-a-record" },
  { label = "incompatible version", key = "bad-version \tCorrupt", value = "v=2 a=1 h=0 w=1 t=1" },
  {
    label = "malformed meta",
    key = "__tiger_user_words_meta__ \tcorrupt",
    value = "not-a-record",
  },
}
for _, fixture in ipairs(corrupt_records) do
  databases[tiger_db_name][fixture.key] = fixture.value
  local corrupt_snapshot, corrupt_error = reloaded_words.export_snapshot("tiger")
  assert(corrupt_snapshot == nil, fixture.label)
  assert(corrupt_error == "用户词数据库不可用", fixture.label)
  assert(db_update_count == writes_before_snapshot, fixture.label)
  databases[tiger_db_name][fixture.key] = nil
end

assert(os.remove(temp_dir .. "/tiger.user.dict.yaml"))
assert(os.remove(temp_dir .. "/tigress.user.dict.yaml"))
assert(os.remove(temp_dir .. "/tiger.dict.yaml"))
assert(os.remove(temp_dir .. "/tigress.dict.yaml"))
assert(os.remove(temp_dir))

print("tiger_user_words tests passed")
