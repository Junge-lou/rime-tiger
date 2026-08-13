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
      local failure = database_write_failures[name]
      if type(failure) == "function" and failure(key, value) then
        return false
      end
      if failure == true then
        return false
      end
      data[key] = value
      return true
    end,
    query = function(_, prefix)
      if prefix ~= "" and db_query_modes[name] == "nil_code" then
        return nil
      end
      if prefix ~= "" and db_query_modes[name] == "throw_code" then
        error("mock code query failure")
      end
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
  local source = { callback = nil }
  function source:connect(callback)
      self.callback = callback
      return { disconnect = function() end }
  end
  return source
end

Component = {
  Processor = function(engine, _, component_name)
    assert(component_name == "speller")
    return {
      process_key_event = function(_, key_event)
        local accepted_keys = engine.context.native_speller_keys or "abcdefghijklmnopqrstuvwxyz"
        local char = key_event.keycode >= 0x20 and key_event.keycode <= 0x7e
          and string.char(key_event.keycode) or ""
        if not accepted_keys:find(char, 1, true) then
          return 2
        end
        engine.context.native_speller_call_count =
          (engine.context.native_speller_call_count or 0) + 1
        engine.context:push_input(char)
        return 1
      end,
    }
  end,
}

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
    commit_notifier = notifier(),
  }
  function context:get_property(name)
    return properties[name] or ""
  end
  function context:set_property(name, value)
    properties[name] = value
    self.property_write_count = (self.property_write_count or 0) + 1
  end
  function context:get_option(name)
    return options[name] or false
  end
  function context:set_option(name, value)
    options[name] = value
    self.option_write_count = (self.option_write_count or 0) + 1
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

local writes_before_idle_commit = tiger_env.engine.context.property_write_count or 0
tiger_env.engine.context.commit_notifier.callback()
assert((tiger_env.engine.context.property_write_count or 0) == writes_before_idle_commit,
  "ordinary commits must not rewrite an empty management property")
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
  context.native_segments = nil
  context.composition = {
    empty = function()
      if context.native_segments then
        return #context.native_segments == 0
      end
      return context.input == ""
    end,
    back = function()
      if context.native_segments then
        return context.native_segments[#context.native_segments]
      end
      segment._end = #context.input
      return segment
    end,
    toSegmentation = function()
      return {
        get_segments = function()
          return context.native_segments or { segment }
        end,
      }
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
  function segment:get_selected_candidate()
    return candidates[self.selected_index + 1]
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

local function start_capture(env)
  assert(words.processor.func(plain_key(0x5c), env) == 1)
  assert(words.processor.func(plain_key(0x5c), env) == 1)
  assert(words.processor.func(plain_key(0x20), env) == 1)
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

ShadowCandidate = function(genuine, candidate_type, text, comment)
  local cand = Candidate(candidate_type, genuine.start or 0, genuine._end or 0, text, comment)
  function cand:get_genuine()
    return genuine
  end
  return cand
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

local function find_snapshot_record(snapshot, code, text)
  for _, record in ipairs(snapshot) do
    if record.code == code and record.text == text then
      return record
    end
  end
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

  start_capture(engine_a)
  local output_a = filter_output(filter_a)
  local output_b = filter_output(filter_b)
  assert(#output_a == 1 and output_a[1].type == "tiger_user_status")
  assert(#output_b == 0, "capture leaked between same-schema engines")
  assert(engine_a.state.capture == nil)

  start_capture(engine_b)
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

  start_capture(tiger_capture)
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
  start_capture(add_env)
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
  assert(words.processor.func(key(0xffff, { shift = true }), disable_env) == 1)
  assert(disable_env.state.blocked[disable_code][disable_text])
  assert(words.processor.func(ctrl_key(0x3b), disable_env) == 2)
  assert(words.processor.func(ctrl_key(0x27), disable_env) == 2)
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

do
  local env = new_runtime_env("tiger", "manage", { "隐藏项", "调序项" })
  words.processor.init(env)
  words.filter.init(env)

  env.segment.selected_index = 1
  assert(words.processor.func(ctrl_key(0xff52), env) == 1)
  env.segment.selected_index = 0
  assert(words.processor.func(key(0xffff, { ctrl = true }), env) == 1)

  assert(words.processor.func(key(0x4d, { ctrl = true, shift = true }), env) == 1)
  local managed = filter_output(env, candidate_input({ "调序项" }))
  assert(#managed == 2)
  local managed_by_text = {}
  for _, cand in ipairs(managed) do
    managed_by_text[cand.text] = cand
  end
  assert(managed_by_text["隐藏项"].comment:find("Delete 恢复", 1, true))
  assert(managed_by_text["调序项"].comment:find("手动调序", 1, true))

  assert(words.processor.func(key(0xffff, { shift = true }), env) == 1)
  assert(not env.state.blocked.manage["隐藏项"])

  assert(words.processor.func(ctrl_key(0x30), env) == 1)
  assert(not env.state.weights.manage["调序项"])

  assert(words.processor.func(plain_key(0xff1b), env) == 2)
  assert(env.engine.context:get_property("tiger_user_words_management_code") == "")

  assert(words.processor.func(key(0x4d, { ctrl = true, shift = true }), env) == 1)
  env.engine.context.commit_notifier.callback()
  assert(env.engine.context:get_property("tiger_user_words_management_code") == "")

  env.engine.context.input = "fresh"
  assert(words.processor.func(key(0xffff, { ctrl = true }), env) == 1)
  assert(env.state.blocked.fresh["隐藏项"])
end

do
  local migrated = new_runtime_env("tiger", "lgcy", { "LegacyTiger" })
  words.processor.init(migrated)
  words.filter.init(migrated)
  assert(words.processor.func(key(0x4d, { ctrl = true, shift = true }), migrated) == 1)
  local output = filter_output(migrated, candidate_input({ "LegacyTiger" }))
  assert(#output == 1)
  assert(not output[1].comment:find("手动调序", 1, true))
end

do
  local failure_env = new_runtime_env("tiger", "failure", { "隐藏失败", "调序失败" })
  words.processor.init(failure_env)
  words.filter.init(failure_env)
  failure_env.segment.selected_index = 1
  assert(words.processor.func(ctrl_key(0xff52), failure_env) == 1)
  failure_env.segment.selected_index = 0
  assert(words.processor.func(key(0xffff, { shift = true }), failure_env) == 1)
  assert(words.processor.func(key(0x4d, { ctrl = true, shift = true }), failure_env) == 1)

  database_write_failures.tiger_user_words_tiger = true
  assert(words.processor.func(key(0xffff, { ctrl = true }), failure_env) == 1)
  assert(failure_env.state.blocked.failure["隐藏失败"])
  assert(failure_env.segment.prompt:find("恢复失败", 1, true))
  assert(words.processor.func(ctrl_key(0x30), failure_env) == 1)
  assert(failure_env.state.ordered.failure["调序失败"])
  assert(failure_env.segment.prompt:find("重置失败", 1, true))
  database_write_failures.tiger_user_words_tiger = nil
end

do
  local clean_env = new_runtime_env("tiger", "clean", { "无需重置" })
  words.processor.init(clean_env)
  words.filter.init(clean_env)
  assert(words.processor.func(key(0x4d, { ctrl = true, shift = true }), clean_env) == 1)
  assert(words.processor.func(ctrl_key(0x30), clean_env) == 1)
  assert(clean_env.segment.prompt:find("无需重置", 1, true))
  assert(not clean_env.segment.prompt:find("写入", 1, true))
end

do
  local converted = new_runtime_env("tiger", "convert", {
    { display = "恢复词", genuine = "恢復詞" },
  })
  words.processor.init(converted)
  words.filter.init(converted)
  assert(words.processor.func(key(0xffff, { shift = true }), converted) == 1)
  assert(words.processor.func(key(0x4d, { ctrl = true, shift = true }), converted) == 1)
  local managed = filter_output(converted, candidate_input({
    { display = "恢复词", genuine = "恢復詞" },
  }))
  assert(managed[1]:get_genuine().text == "恢復詞")
  function converted.engine.context:get_selected_candidate()
    return managed[1]
  end
  assert(words.processor.func(key(0xffff, { ctrl = true }), converted) == 1)
  assert(not converted.state.blocked.convert["恢復詞"])
end

do
  local add_only = new_runtime_env("tiger", "only", {})
  add_only.engine.context:set_option("ascii_mode", true)
  words.processor.init(add_only)
  start_capture(add_only)
  assert(words.processor.func(plain_key(0x78), add_only) == 1)
  assert(words.processor.func(plain_key(0xff0d), add_only) == 1)

  local delete_only = new_runtime_env("tiger", "only", {})
  words.processor.init(delete_only)
  function delete_only.engine.context:get_selected_candidate()
    local genuine = { type = "tiger_user_word", text = "x", comment = "" }
    return ShadowCandidate(genuine, "simplified", "x", "")
  end
  assert(words.processor.func(key(0xffff, { shift = true }), delete_only) == 1)
  local deleted_only = assert(find_snapshot_record(words.export_snapshot("tiger"), "only", "x"))
  assert(deleted_only.added == false and deleted_only.hidden == false)

  local add_overlap = new_runtime_env("tiger", "overlap", { "官方重叠" })
  words.processor.init(add_overlap)
  start_capture(add_overlap)
  assert(words.processor.func(plain_key(0x61), add_overlap) == 1)
  assert(words.processor.func(plain_key(0x20), add_overlap) == 1)
  assert(words.processor.func(plain_key(0xff0d), add_overlap) == 1)

  local delete_overlap = new_runtime_env("tiger", "overlap", { "官方重叠" })
  words.processor.init(delete_overlap)
  assert(words.processor.func(key(0xffff, { ctrl = true }), delete_overlap) == 1)
  local deleted_overlap = assert(find_snapshot_record(words.export_snapshot("tiger"), "overlap", "官方重叠"))
  assert(deleted_overlap.added == false and deleted_overlap.hidden == true)
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
  start_capture(env)
  local capture = capture_of(env)
  assert(capture.code == "meta" and capture.text == "" and capture.query == "")
  assert(capture.operation == "add" and capture.message == "")
  assert(capture.original_ascii_mode == false)
  assert(capture.shift_key == nil and capture.shift_used == false)
  assert(env.segment.prompt == "〔加词 meta：未取字〕")
  local output = filter_output(env)
  assert(output[1].comment == "")
  assert(not output[1].comment:find("Shift", 1, true))
  assert(not output[1].comment:find("Ctrl+;", 1, true))
  assert(not output[1].comment:find("中文取词", 1, true))
  assert(not output[1].comment:find("英文直录", 1, true))
  assert(words.processor.func(key(0x4d, { ctrl = true, shift = true }), env) == 1)
  assert(capture_of(env) == capture)
  assert(env.engine.context:get_property("tiger_user_words_management_code") == "")
  env.engine.context:set_option("ascii_mode", true)
  output = filter_output(env)
  assert(output[1].comment == "")
  words.processor.func(plain_key(0xff1b), env)
end)

runtime_case("bare Shift toggles and Shift letter does not", function()
  local env = new_runtime_env("tiger", "shift", {})
  words.processor.init(env)
  start_capture(env)
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
  start_capture(env)
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
    start_capture(env)
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
  start_capture(env)
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
  start_capture(env)
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

runtime_case("native speller selection continues into the next query", function()
  local env = new_runtime_env("tiger", "native", {})
  words.processor.init(env)
  start_capture(env)
  local capture = capture_of(env)

  assert(words.processor.func(plain_key(0x61), env) == 1)
  assert(env.engine.context.native_speller_call_count == 1,
    "Chinese spelling keys must be handled by the active schema speller")

  local selected = {
    _start = 0,
    _end = 4,
    status = "kSelected",
    get_selected_candidate = function()
      return candidate({ display = "转换字", genuine = "真字" })
    end,
  }
  env.engine.context.input = "abcd"
  env.engine.context.native_segments = { selected }
  env.engine.context.select_notifier.callback()
  assert(capture.text == "真字" and capture.query == "")

  local guessing = {
    _start = 4,
    _end = 5,
    status = "kGuess",
    get_selected_candidate = function() return candidate("下一字") end,
  }
  env.engine.context.input = "abcde"
  env.engine.context.native_segments = { selected, guessing }
  env.engine.context.update_notifier.callback()
  assert(capture.text == "真字" and capture.query == "e",
    "the fifth key must remain in the native speller's next segment")

  env.engine.context.select_notifier.callback()
  assert(capture.text == "真字", "repeated native notifications must not duplicate text")
  assert(env.engine.context.commit_count == nil, "capture must not commit to the application")
end)

runtime_case("native speller decides the schema alphabet", function()
  local env = new_runtime_env("tiger", "alphabet", {})
  env.engine.context.native_speller_keys = ";"
  words.processor.init(env)
  start_capture(env)

  assert(words.processor.func(plain_key(0x3b), env) == 1)
  assert(env.engine.context.native_speller_call_count == 1)
  assert(capture_of(env).query == ";")
end)

runtime_case("native speller first key sees real candidates", function()
  local env = new_runtime_env("tiger", "firstkey", {})
  words.processor.init(env)
  words.filter.init(env)
  start_capture(env)
  local capture = capture_of(env)
  capture.native_started = true
  capture.query = ""
  env.engine.context.input = "a"

  local output = filter_output(env, candidate_input({ "首键候选" }))
  assert(#output == 1 and output[1].text == "首键候选",
    "the first native speller update must not be replaced by capture status")
end)

runtime_case("native unique selection returns to capture status", function()
  local env = new_runtime_env("tiger", "unique", {})
  words.processor.init(env)
  words.filter.init(env)
  start_capture(env)
  local capture = capture_of(env)
  capture.native_started = true
  capture.native_confirmed_end = 1
  capture.query = ""
  capture.text = "唯一字"
  env.engine.context.input = "a"

  local output = filter_output(env, candidate_input({ "不应显示" }))
  assert(#output == 1 and output[1].type == "tiger_user_status")
  assert(output[1].text:find("唯一字", 1, true))
end)

runtime_case("native speller auto clear resets segment offsets", function()
  local env = new_runtime_env("tiger", "clearoffset", {})
  words.processor.init(env)
  start_capture(env)
  local capture = capture_of(env)
  capture.native_started = true
  capture.native_confirmed_end = 4
  capture.native_input_length = 4
  capture.text = "前字"

  env.engine.context.input = ""
  env.engine.context.native_segments = {}
  env.engine.context.update_notifier.callback()
  assert(capture.native_confirmed_end == 0,
    "native speller clearing its context must reset the segment offset baseline")

  local selected = {
    _start = 0,
    _end = 2,
    status = "kConfirmed",
    get_selected_candidate = function() return candidate("后字") end,
  }
  env.engine.context.input = "ef"
  env.engine.context.native_segments = { selected }
  env.engine.context.select_notifier.callback()
  assert(capture.text == "前字后字")
end)

runtime_case("rejected native first key restores capture context", function()
  local env = new_runtime_env("tiger", "reject", {})
  env.engine.context.native_speller_keys = ";"
  words.processor.init(env)
  words.filter.init(env)
  start_capture(env)

  assert(words.processor.func(plain_key(0x61), env) == 1)
  local capture = capture_of(env)
  assert(capture.native_started == false and capture.query == "")
  assert(env.engine.context.input == "reject")
  assert(filter_output(env)[1].type == "tiger_user_status")
end)

runtime_case("missing native speller never falls back to Lua query", function()
  local env = new_runtime_env("tiger", "nospeller", {})
  words.processor.init(env)
  env.capture_speller = nil
  words.filter.init(env)
  start_capture(env)

  assert(words.processor.func(plain_key(0x61), env) == 1)
  local capture = capture_of(env)
  assert(capture.query == "" and capture.native_started == false)
  assert(capture.message == "当前环境不支持原生取词")
  assert(filter_output(env)[1].comment == capture.message)

  capture.message = ""
  assert(words.processor.func(plain_key(0x3b), env) == 1)
  assert(capture.text == "" and capture.message == "当前环境不支持原生取词")
end)

runtime_case("capture temporarily disables native auto commit", function()
  local env = new_runtime_env("tiger", "autocommit", {})
  env.engine.context:set_option("_auto_commit", true)
  words.processor.init(env)
  start_capture(env)
  assert(env.engine.context:get_option("_auto_commit") == false)
  assert(words.processor.func(plain_key(0xff1b), env) == 1)
  assert(env.engine.context:get_option("_auto_commit") == true)
end)

runtime_case("capture cleanup does not re-notify an unchanged language mode", function()
  local env = new_runtime_env("tiger", "same", {})
  words.processor.init(env)
  start_capture(env)
  local writes_before_cleanup = env.engine.context.option_write_count or 0
  assert(words.processor.func(plain_key(0xff1b), env) == 1)
  assert((env.engine.context.option_write_count or 0) == writes_before_cleanup,
    "restoring an unchanged ascii_mode must not emit an option notification")
end)

runtime_case("missing properties do not create writes during ordinary typing", function()
  local env = new_runtime_env("tiger", "", {})
  function env.engine.context:get_property()
    return nil
  end
  words.processor.init(env)
  local writes_before_key = env.engine.context.property_write_count or 0
  env.engine.context.commit_notifier.callback()
  assert((env.engine.context.property_write_count or 0) == writes_before_key,
    "a missing property must be treated as empty during ordinary commits")
  assert(words.processor.func(plain_key(0x61), env) == 2)
  assert((env.engine.context.property_write_count or 0) == writes_before_key,
    "a missing property must be treated as empty during ordinary typing")
end)

runtime_case("Chinese keypad and punctuation conversion", function()
  local env = new_runtime_env("tiger", "punct", {})
  words.processor.init(env)
  start_capture(env)
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
  start_capture(env)
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
  start_capture(env)
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
  start_capture(env)
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
  start_capture(env)
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
  start_capture(save_env)
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
  start_capture(cancel_env)
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
  start_capture(fini_env)
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
assert(tiger_added.source == "shortcut")
assert(databases[tiger_db_name]["efgh \tTigerAdded"]:find("s=1", 1, true))
assert(find_snapshot_record(tiger_snapshot, "lgcy", "LegacyTiger").source == nil)
assert(tiger_source.hidden == true)
assert(tiger_second.weight == 100000000000)
assert(tiger_second.ordered == true)
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

assert(reloaded_words.restore_hidden("tiger", "tsrc", "TigerSource"))
assert(not reloaded_env.state.blocked.tsrc.TigerSource)
assert(find_snapshot_record(reloaded_words.export_snapshot("tiger"), "tsrc", "TigerSource").hidden == false)

assert(reloaded_words.clear_order("tiger", "mnop", "第二"))
assert(not reloaded_env.state.weights.mnop["第二"])
local cleared_order = assert(find_snapshot_record(reloaded_words.export_snapshot("tiger"), "mnop", "第二"))
assert(cleared_order.ordered == false and cleared_order.weight == 0)

assert(reloaded_words.remove_shortcut("tiger", "efgh", "TigerAdded"))
assert(not reloaded_env.state.added.efgh.TigerAdded)
local removed_shortcut = assert(find_snapshot_record(reloaded_words.export_snapshot("tiger"), "efgh", "TigerAdded"))
assert(removed_shortcut.added == false and removed_shortcut.source == nil and removed_shortcut.weight == 0)
assert(not reloaded_words.remove_shortcut("tiger", "lgcy", "LegacyTiger"))

databases[tiger_db_name]["reset \tHidden"] = "v=1 a=0 h=1 w=0 t=1 s=0 o=0"
databases[tiger_db_name]["reset \tOrdered"] = "v=1 a=0 h=0 w=99 t=2 s=0 o=1"
databases[tiger_db_name]["legacyorder \tOldOrder"] = "v=1 a=0 h=0 w=77 t=3"
databases[tiger_db_name]["marker \tMarkerWord"] = "v=1 a=0 h=0 w=0 t=4 s=0 o=0"
write_file(temp_dir .. "/tiger.user.dict.yaml", table.concat({
  "# Rime dictionary: tiger.user",
  "---",
  "name: tiger.user",
  "...",
  "LegacyTiger\tlgcy\t42",
  "# USER_WORDS_MARKER\tdisabled\tmarker\tMarkerWord\t0",
  "",
}, "\n"))
package.loaded["tiger_user_words"] = nil
local reset_words = require("tiger_user_words")
local reset_env = new_runtime_env("tiger", "reset", { "Hidden", "Ordered" })
reset_words.processor.init(reset_env)
assert(reset_env.state.ordered.legacyorder.OldOrder)
assert(not (reset_env.state.blocked.marker and reset_env.state.blocked.marker.MarkerWord))
assert(reset_words.clear_order("tiger", "legacyorder", "OldOrder"))
assert(reset_words.reset_code("tiger", "reset"))
assert(not reset_env.state.blocked.reset.Hidden)
assert(not reset_env.state.weights.reset.Ordered)
local reset_snapshot = reset_words.export_snapshot("tiger")
assert(find_snapshot_record(reset_snapshot, "reset", "Hidden").hidden == false)
assert(find_snapshot_record(reset_snapshot, "reset", "Ordered").ordered == false)

databases[tiger_db_name]["rollback \tFirst"] = "v=1 a=0 h=1 w=0 t=4 s=0 o=0"
databases[tiger_db_name]["rollback \tSecond"] = "v=1 a=0 h=0 w=88 t=5 s=0 o=1"
package.loaded["tiger_user_words"] = nil
local rollback_words = require("tiger_user_words")
local rollback_env = new_runtime_env("tiger", "rollback", { "First", "Second" })
rollback_words.processor.init(rollback_env)
local failed_once = false
database_write_failures[tiger_db_name] = function(key)
  if key == "rollback \tSecond" and not failed_once then
    failed_once = true
    return true
  end
  return false
end
assert(not rollback_words.reset_code("tiger", "rollback"))
database_write_failures[tiger_db_name] = nil
local rolled_back = rollback_words.export_snapshot("tiger")
assert(find_snapshot_record(rolled_back, "rollback", "First").hidden == true)
assert(find_snapshot_record(rolled_back, "rollback", "Second").ordered == true)
assert(rollback_env.state.blocked.rollback.First)
assert(rollback_env.state.ordered.rollback.Second)

local first_write_count = 0
database_write_failures[tiger_db_name] = function(key)
  if key == "rollback \tFirst" then
    first_write_count = first_write_count + 1
    return first_write_count == 2
  end
  return key == "rollback \tSecond"
end
local reset_ok, reset_status = rollback_words.reset_code("tiger", "rollback")
assert(not reset_ok)
assert(reset_status == "partial")
database_write_failures[tiger_db_name] = nil
local partially_reset = rollback_words.export_snapshot("tiger")
assert(find_snapshot_record(partially_reset, "rollback", "First").hidden == false)
assert(find_snapshot_record(partially_reset, "rollback", "Second").ordered == true)
assert(not rollback_env.state.blocked.rollback.First)
assert(rollback_env.state.ordered.rollback.Second)

db_query_modes[tiger_db_name] = "nil_code"
local query_ok, query_status = rollback_words.reset_code("tiger", "rollback")
assert(not query_ok)
assert(query_status == "failed")
local first_before_failed_delete = databases[tiger_db_name]["rollback \tFirst"]
local query_failure_env = new_runtime_env("tiger", "rollback", { "First" })
rollback_words.processor.init(query_failure_env)
assert(rollback_words.processor.func(key(0xffff, { shift = true }), query_failure_env) == 2)
assert(databases[tiger_db_name]["rollback \tFirst"] == first_before_failed_delete)
db_query_modes[tiger_db_name] = nil

reloaded_words = rollback_words
reloaded_env = rollback_env
writes_before_snapshot = db_update_count

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
