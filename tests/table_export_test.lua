package.path = "./lua/?.lua;" .. package.path

local temp_dir = os.tmpname()
os.remove(temp_dir)
assert(os.execute("mkdir -p " .. temp_dir))

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  assert(file:write(content))
  assert(file:close())
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = assert(file:read("*a"))
  assert(file:close())
  return content
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then
    return false
  end
  file:close()
  return true
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label, tostring(expected), tostring(actual)), 2)
  end
end

local function assert_contains(actual, expected, label)
  if not actual or not string.find(actual, expected, 1, true) then
    error(string.format("%s: expected %q in %q", label, expected, tostring(actual)), 2)
  end
end

local function assert_false(value, label)
  if value then
    error(label .. ": expected false", 2)
  end
end

local dictionary_header = [[
---
name: %s
sort: by_weight
...
%s
malformed-only
]]
write_file(temp_dir .. "/tiger.extended.dict.yaml", string.format(dictionary_header, "tiger.extended", "虎词\tb\t10"))
write_file(temp_dir .. "/tigress.extended.dict.yaml", string.format(dictionary_header, "tigress.extended", "狮词\td\t10"))

rime_api = {
  get_user_data_dir = function()
    return temp_dir
  end,
}
kAccepted = 1
kNoop = 2

local snapshot_calls = {}
local snapshot_error
local snapshots = {
  tiger = { { text = "用户虎", code = "c", added = true, weight = 20 } },
  tigress = { { text = "用户狮", code = "e", added = true, weight = 20 } },
}
local words = {
  export_snapshot = function(schema_id)
    snapshot_calls[#snapshot_calls + 1] = schema_id
    if snapshot_error then
      return nil, snapshot_error
    end
    return snapshots[schema_id]
  end,
}
package.loaded.tiger_user_words = words

Candidate = function(candidate_type, start, finish, text, comment)
  return {
    type = candidate_type,
    start = start,
    _end = finish,
    text = text,
    comment = comment,
  }
end

local function scalar(value)
  return { type = "kScalar", value = value }
end

local function item(object)
  return {
    get_obj = function()
      return object
    end,
  }
end

local function list(values)
  return {
    type = "kList",
    size = #values,
    get_at = function(_, index)
      return item(values[index + 1])
    end,
  }
end

local function config(dictionary, keys, entries)
  return {
    get_string = function(_, path)
      assert_equal(path, "translator/dictionary", "dictionary config path")
      return dictionary
    end,
    get_map = function(_, path)
      assert_equal(path, "punctuator/symbols", "symbols config path")
      if not keys then
        return nil
      end
      return {
        keys = function()
          return keys
        end,
        get = function(_, key)
          local object = entries[key]
          if object == "throw" then
            return { get_obj = function() error("malformed object") end }
          end
          return {
            get_obj = function()
              return object
            end,
          }
        end,
      }
    end,
  }
end

local default_keys = { "\\a" }
local default_entries = { ["\\a"] = scalar("符号") }

local function new_env(schema_id, dictionary, selected_index, custom_config)
  local segment = {
    start = 0,
    _end = 5,
    selected_index = selected_index or 0,
  }
  local context = {
    input = "\\dcck",
    refresh_count = 0,
    clear_count = 0,
    properties = {},
  }
  context.composition = {
    back = function()
      return segment
    end,
  }
  function context:refresh_non_confirmed_composition()
    self.refresh_count = self.refresh_count + 1
  end
  function context:clear()
    self.input = ""
    self.clear_count = self.clear_count + 1
  end
  function context:get_property(name)
    return self.properties[name] or ""
  end
  function context:set_property(name, value)
    self.properties[name] = value
  end
  function context:clear_property(name)
    self.properties[name] = nil
  end
  local env = {
    engine = {
      context = context,
      schema = {
        schema_id = schema_id,
        config = custom_config or config(dictionary, default_keys, default_entries),
      },
    },
    segment = segment,
  }
  env._context = context
  return env
end

local function use_distinct_context_wrappers(env)
  local context = env._context
  local schema = env.engine.schema
  local function new_wrapper()
    return setmetatable({}, {
      __index = function(_, name)
        local value = context[name]
        if type(value) == "function" then
          return function(_, ...)
            return value(context, ...)
          end
        end
        return value
      end,
      __newindex = function(_, name, value)
        context[name] = value
      end,
    })
  end
  env.engine = setmetatable({ schema = schema }, {
    __index = function(_, name)
      if name == "context" then
        return new_wrapper()
      end
    end,
  })
  return env
end

local function key(keycode, modifiers)
  modifiers = modifiers or {}
  return {
    keycode = keycode,
    release = function() return modifiers.release or false end,
    ctrl = function() return modifiers.ctrl or false end,
    alt = function() return modifiers.alt or false end,
    shift = function() return modifiers.shift or false end,
    caps = function() return modifiers.caps or false end,
  }
end

local adapter = require("table_export")

local function translated(env, input)
  local candidates = {}
  yield = function(candidate)
    candidates[#candidates + 1] = candidate
  end
  adapter.translator(input or env.engine.context.input, env.segment, env)
  return candidates
end

local function press(env, keycode, modifiers)
  return adapter.processor.func(key(keycode, modifiers), env)
end

local function reset_outputs()
  os.remove(temp_dir .. "/tiger_export.txt")
  os.remove(temp_dir .. "/tiger_export.txt.tmp")
  os.remove(temp_dir .. "/tiger_export.txt.bak")
  os.remove(temp_dir .. "/tigress_export.txt")
  os.remove(temp_dir .. "/tigress_export.txt.tmp")
  os.remove(temp_dir .. "/tigress_export.txt.bak")
end

local function test_contract_and_symbol_extraction()
  assert_equal(adapter.command, "\\dcck", "command constant")
  assert_equal(type(adapter.translator), "function", "callable translator")
  assert_equal(type(adapter.processor), "table", "named processor")
  assert_equal(type(adapter.processor.func), "function", "processor func")

  local entries = {
    A = scalar("大写"),
    ["\\"] = list({ scalar("先"), { type = "kMap", value = "伪装值" }, scalar("后") }),
    a = scalar("小写"),
    bad = { type = "kScalar", value = 42 },
    unsupported = { type = "kMap", other = true },
  }
  local extracted = adapter.extract_symbols(config("unused", { "a", "unsupported", "bad", "\\", "A" }, entries))
  assert_equal(#extracted, 4, "valid symbol count")
  assert_equal(extracted[1].code, "A", "bytewise first key")
  assert_equal(extracted[1].text, "大写", "scalar value")
  assert_equal(extracted[1].order, 1, "scalar order")
  assert_equal(extracted[2].code, "\\", "bytewise second key")
  assert_equal(extracted[2].text, "先", "first list value")
  assert_equal(extracted[2].order, 2, "first list order")
  assert_equal(extracted[3].text, "后", "later valid list value")
  assert_equal(extracted[3].order, 4, "malformed list item keeps index gap")
  assert_equal(extracted[4].code, "a", "bytewise third valid key")
  assert_equal(extracted[4].order, 5, "map/list traversal order")
  assert_equal(#adapter.extract_symbols(config("unused", nil, nil)), 0, "missing symbols map")
end

local function test_symbol_extraction_requires_exact_config_object_types()
  assert_equal(rawget(_G, "kScalar"), nil, "runtime has no kScalar global")
  assert_equal(rawget(_G, "kList"), nil, "runtime has no kList global")
  local deceptive = {
    ["\\list"] = list({
      scalar("有效一"),
      { type = "kList", value = "列表伪装标量", size = 0, get_at = function() end },
      { type = "kMap", value = "映射伪装标量" },
      { type = "kUnknown", value = "未知伪装标量" },
      scalar("有效二"),
    }),
    ["\\map"] = { type = "kMap", value = "顶层映射伪装标量" },
    ["\\unknown"] = {
      type = "kUnknown",
      value = "顶层未知伪装标量",
      size = 1,
      get_at = function()
        return item(scalar("未知列表伪装值"))
      end,
    },
  }
  local extracted = adapter.extract_symbols(config(
    "unused",
    { "\\unknown", "\\map", "\\list" },
    deceptive
  ))
  assert_equal(#extracted, 2, "only exact scalar children are extracted")
  assert_equal(extracted[1].text, "有效一", "first scalar list child")
  assert_equal(extracted[1].code, "\\list", "valid list key")
  assert_equal(extracted[1].order, 1, "first list candidate order")
  assert_equal(extracted[2].text, "有效二", "last scalar list child")
  assert_equal(extracted[2].order, 5, "non-scalar children retain candidate order gaps")
end

local function assert_symbol_error(custom_config, expected, label)
  local symbols, err = adapter.extract_symbols(custom_config)
  assert_equal(symbols, nil, label .. " symbols")
  assert_contains(err, expected, label .. " error")
end

local function map_config(map)
  return {
    get_map = function(_, path)
      assert_equal(path, "punctuator/symbols", "structural symbols config path")
      return map
    end,
  }
end

local function test_symbol_api_failures_are_reported()
  assert_symbol_error({
    get_map = function()
      error("get_map exploded")
    end,
  }, "get_map", "throwing get_map")

  assert_symbol_error(map_config({
    keys = function()
      error("keys exploded")
    end,
    get = function() end,
  }), "keys", "throwing keys")

  assert_symbol_error(map_config({
    keys = function() return "not an array" end,
    get = function() end,
  }), "array", "non-array keys")

  assert_symbol_error(map_config({
    keys = function() return { "\\a" } end,
    get = function()
      error("get exploded")
    end,
  }), "map:get", "throwing get")

  assert_symbol_error(map_config({
    keys = function() return { "\\a" } end,
    get = function() return nil end,
  }), "missing item", "missing returned item")

  assert_symbol_error(config("unused", { "\\a" }, { ["\\a"] = "throw" }), "get_obj", "throwing item get_obj")

  local function one_list(object)
    return map_config({
      keys = function() return { "\\a" } end,
      get = function() return item(object) end,
    })
  end
  assert_symbol_error(one_list({ type = "kList", size = "one", get_at = function() end }), "size", "invalid list size")
  assert_symbol_error(one_list({ type = "kList", size = 1 }), "get_at", "missing list get_at")
  assert_symbol_error(one_list({
    type = "kList",
    size = 1,
    get_at = function() error("get_at exploded") end,
  }), "get_at", "throwing list get_at")
  assert_symbol_error(one_list({
    type = "kList",
    size = 1,
    get_at = function() return nil end,
  }), "missing child", "missing list child")
  assert_symbol_error(one_list({
    type = "kList",
    size = 1,
    get_at = function() return {} end,
  }), "child get_obj", "missing child get_obj")
  assert_symbol_error(one_list({
    type = "kList",
    size = 1,
    get_at = function()
      return { get_obj = function() error("child exploded") end }
    end,
  }), "child get_obj", "throwing child get_obj")
end

local function test_initial_confirmation_candidates()
  local env = new_env("tiger", "tiger.extended")
  local candidates = translated(env)
  assert_equal(#candidates, 2, "initial candidate count")
  assert_equal(candidates[1].type, "table_export", "isolated candidate type")
  assert_equal(candidates[1].text, "确认导出当前方案", "confirm text")
  assert_equal(candidates[2].text, "取消", "cancel text")
end

local function test_tiger_confirmed_export_and_success_status()
  reset_outputs()
  local env = new_env("tiger", "tiger.extended")
  assert_equal(press(env, 0x20), kAccepted, "Space confirms selected first row")
  assert_equal(read_file(temp_dir .. "/tiger_export.txt"), "符号\t\\a\n虎词\tb\n用户虎\tc\n", "exact tiger bytes")
  assert_false(file_exists(temp_dir .. "/tigress_export.txt"), "tiger does not write tigress output")
  assert_equal(env.engine.context.input, "\\dcck", "success keeps command input")
  assert_equal(env.engine.context.refresh_count, 1, "success refreshes composition")
  local candidates = translated(env)
  assert_equal(#candidates, 1, "success status candidate count")
  assert_contains(candidates[1].text, "导出成功", "success status")
  assert_contains(candidates[1].text, "3", "exported count status")
  assert_contains(candidates[1].text, "1", "skipped count status")
  assert_contains(candidates[1].text .. candidates[1].comment, temp_dir .. "/tiger_export.txt", "full output path status")
end

local function test_tigress_confirmed_export()
  reset_outputs()
  local env = new_env("tigress", "tigress.extended")
  assert_equal(press(env, 0xff0d), kAccepted, "Return confirms selected first row")
  assert_equal(read_file(temp_dir .. "/tigress_export.txt"), "符号\t\\a\n狮词\td\n用户狮\te\n", "exact tigress bytes")
  assert_false(file_exists(temp_dir .. "/tiger_export.txt"), "tigress does not write tiger output")
end

local function test_selection_and_cancellation_semantics()
  reset_outputs()
  local calls = #snapshot_calls
  local selected_cancel = new_env("tiger", "tiger.extended", 1)
  assert_equal(press(selected_cancel, 0x20), kAccepted, "Space selects cancellation row")
  assert_equal(selected_cancel.engine.context.input, "", "selected cancellation clears command")
  assert_equal(#snapshot_calls, calls, "selected cancellation does not snapshot")

  local digit_confirm = new_env("tiger", "tiger.extended", 1)
  assert_equal(press(digit_confirm, 0x31), kAccepted, "1 confirms first row")
  assert_equal(#snapshot_calls, calls + 1, "digit one exports regardless of selected row")

  local digit_cancel = new_env("tiger", "tiger.extended", 0)
  assert_equal(press(digit_cancel, 0x32), kAccepted, "2 cancels second row")
  assert_equal(#snapshot_calls, calls + 1, "digit two does not export")
  assert_equal(digit_cancel.engine.context.input, "", "digit cancellation clears command")

  local escape = new_env("tiger", "tiger.extended", 0)
  assert_equal(press(escape, 0xff1b), kAccepted, "Escape cancels")
  assert_equal(#snapshot_calls, calls + 1, "Escape does not export")
  assert_equal(escape.engine.context.input, "", "Escape clears command")
end

local function test_extra_command_candidate_selections_are_consumed()
  local calls = #snapshot_calls
  for _, keycode in ipairs({ 0x20, 0xff0d, 0x33 }) do
    local env = new_env("tiger", "tiger.extended", 2)
    assert_equal(press(env, keycode), kAccepted, "extra candidate selection is consumed")
    assert_equal(env.engine.context.input, "\\dcck", "extra candidate text is not committed")
    assert_equal(env.engine.context.clear_count, 0, "extra selection keeps reserved command")
  end
  assert_equal(#snapshot_calls, calls, "extra candidate selections do not export")
end

local function assert_export_failure(env, expected, label)
  local result, err = adapter._test_export(env)
  assert_equal(result, nil, label .. " result")
  assert_contains(err, expected, label .. " error")
end

local function test_profile_config_source_and_snapshot_failures()
  reset_outputs()
  assert_export_failure(new_env("PY_c", "tiger.extended"), "不支持", "unsupported schema")
  assert_export_failure(new_env("tiger", "wrong.extended"), "不匹配", "dictionary mismatch")

  local tiger_path = temp_dir .. "/tiger.extended.dict.yaml"
  local saved = read_file(tiger_path)
  os.remove(tiger_path)
  assert_export_failure(new_env("tiger", "tiger.extended"), "tiger.extended.dict.yaml", "missing source")
  write_file(tiger_path, saved)

  local destination = temp_dir .. "/tiger_export.txt"
  local temporary = destination .. ".tmp"
  local previous_bytes = "previous\0output\n"
  write_file(destination, previous_bytes)
  snapshot_error = "快照模拟失败"
  assert_export_failure(new_env("tiger", "tiger.extended"), "快照模拟失败", "snapshot failure")
  snapshot_error = nil
  assert_equal(read_file(destination), previous_bytes, "snapshot failure preserves destination bytes")
  assert_false(file_exists(temporary), "snapshot failure creates no temporary output")
end

local function test_failure_status_and_unrelated_input_or_key()
  local unsupported = new_env("PY_c", "tiger.extended")
  assert_equal(press(unsupported, 0x20), kAccepted, "failed export is handled")
  local status = translated(unsupported)
  assert_equal(#status, 1, "failure status count")
  assert_contains(status[1].text, "导出失败", "failure notice")
  assert_contains(status[1].text, "不支持", "failure reason")

  local unrelated_input = new_env("tiger", "tiger.extended")
  unrelated_input.engine.context.input = "abc"
  local calls = #snapshot_calls
  assert_equal(press(unrelated_input, 0x20), kNoop, "unrelated input no-op")
  assert_equal(#translated(unrelated_input), 0, "unrelated input no candidates")
  assert_equal(#snapshot_calls, calls, "unrelated input does not snapshot")

  local unrelated_key = new_env("tiger", "tiger.extended")
  assert_equal(press(unrelated_key, 0x78), kNoop, "unrelated key no-op")
  assert_equal(press(unrelated_key, 0x20, { ctrl = true }), kNoop, "modified key no-op")
  assert_equal(#snapshot_calls, calls, "unrelated keys do not snapshot")
end

local function test_symbol_api_failure_preserves_output_and_yields_status()
  reset_outputs()
  local destination = temp_dir .. "/tiger_export.txt"
  write_file(destination, "previous output\n")
  local broken_config = config("tiger.extended", { "\\a" }, { ["\\a"] = "throw" })
  local env = new_env("tiger", "tiger.extended", 0, broken_config)
  assert_equal(press(env, 0x20), kAccepted, "symbol failure is handled")
  assert_equal(read_file(destination), "previous output\n", "symbol failure preserves destination")
  assert_false(file_exists(destination .. ".tmp"), "symbol failure creates no temporary output")
  local status = translated(env)
  assert_equal(#status, 1, "symbol failure status count")
  assert_contains(status[1].text, "导出失败", "symbol failure notice")
  assert_contains(status[1].text, "get_obj", "symbol failure detail")
end

local function with_mocked_open(replacement, callback)
  local original = io.open
  io.open = replacement(original)
  local ok, err = pcall(callback)
  io.open = original
  if not ok then
    error(err, 0)
  end
end

local function assert_preserved_after_failure(mode, expected_error)
  reset_outputs()
  local destination = temp_dir .. "/tiger_export.txt"
  local temporary = destination .. ".tmp"
  write_file(destination, "previous output\n")

  with_mocked_open(function(original)
    return function(path, open_mode)
      if path == temporary and open_mode == "wb" then
        if mode == "open" then
          return nil, "simulated temp open failure"
        end
        local handle = {}
        handle.write = function()
          if mode == "write" then
            return nil, "simulated temp write failure"
          end
          return handle
        end
        handle.close = function()
          if mode == "close" then
            return nil, "simulated temp close failure"
          end
          return true
        end
        return handle
      end
      return original(path, open_mode)
    end
  end, function()
    assert_export_failure(new_env("tiger", "tiger.extended"), expected_error, mode .. " failure")
  end)

  assert_equal(read_file(destination), "previous output\n", mode .. " preserves destination")
  assert_false(file_exists(temporary), mode .. " cleans temporary")
end

local function test_atomic_open_write_and_close_failures()
  assert_preserved_after_failure("open", "打开临时文件")
  assert_preserved_after_failure("write", "写入临时文件")
  assert_preserved_after_failure("close", "关闭临时文件")
end

local function test_atomic_rename_failure_restores_previous_destination()
  reset_outputs()
  local destination = temp_dir .. "/tiger_export.txt"
  local temporary = destination .. ".tmp"
  local backup = destination .. ".bak"
  write_file(destination, "previous output\n")
  local original_rename = os.rename
  os.rename = function(from, to)
    if from == temporary and to == destination then
      return nil, "simulated rename failure"
    end
    return original_rename(from, to)
  end
  local ok, err = pcall(function()
    assert_export_failure(new_env("tiger", "tiger.extended"), "替换导出文件", "rename failure")
  end)
  os.rename = original_rename
  if not ok then
    error(err, 0)
  end
  assert_equal(read_file(destination), "previous output\n", "rename failure restores destination")
  assert_false(file_exists(temporary), "rename failure cleans temporary")
  assert_false(file_exists(backup), "rename failure cleans backup after restore")
end

local function test_windows_style_fallback_replaces_existing_destination()
  reset_outputs()
  local destination = temp_dir .. "/tiger_export.txt"
  local temporary = destination .. ".tmp"
  local backup = destination .. ".bak"
  write_file(destination, "previous output\n")
  local original_rename = os.rename
  local install_attempts = 0
  os.rename = function(from, to)
    if from == temporary and to == destination then
      install_attempts = install_attempts + 1
      if install_attempts == 1 then
        return nil, "simulated Windows destination-exists failure"
      end
    end
    return original_rename(from, to)
  end
  local ok, result, err = pcall(adapter._test_export, new_env("tiger", "tiger.extended"))
  os.rename = original_rename
  if not ok then
    error(result, 0)
  end
  assert(result, err)
  assert_equal(install_attempts, 2, "fallback retries installation after backup")
  assert_equal(read_file(destination), "符号\t\\a\n虎词\tb\n用户虎\tc\n", "fallback installs complete output")
  assert_false(file_exists(temporary), "fallback success consumes temporary")
  assert_false(file_exists(backup), "fallback success cleans backup")
end

local function test_context_status_isolation_and_status_dismissal()
  reset_outputs()
  local first = new_env("tiger", "tiger.extended")
  local second = new_env("tiger", "tiger.extended")
  assert_equal(press(first, 0x20), kAccepted, "first context exports")
  assert_equal(#translated(first), 1, "first context has result")
  local second_candidates = translated(second)
  assert_equal(#second_candidates, 2, "second context remains at confirmation")
  assert_equal(second_candidates[1].text, "确认导出当前方案", "second context confirmation")
  assert_equal(press(first, 0x20), kAccepted, "status selection is consumed")
  assert_equal(first.engine.context.input, "", "status selection clears command")
end

local function test_context_properties_bridge_distinct_userdata_wrappers()
  reset_outputs()
  local first = use_distinct_context_wrappers(new_env("tiger", "tiger.extended"))
  local first_wrapper = first.engine.context
  local second_wrapper = first.engine.context
  assert_false(first_wrapper == second_wrapper, "engine returns distinct context wrappers")
  assert_equal(press(first, 0x20), kAccepted, "export through first wrapper")
  local first_status = translated(first)
  assert_equal(#first_status, 1, "translator reads processor status through another wrapper")
  assert_contains(first_status[1].text, "导出成功", "shared property status")

  local isolated = use_distinct_context_wrappers(new_env("tiger", "tiger.extended"))
  assert_equal(#translated(isolated), 2, "separate property store remains isolated")

  first.engine.context.input = "other"
  assert_equal(#translated(first), 0, "leaving command clears properties through fresh wrapper")
  first.engine.context.input = "\\dcck"
  assert_equal(#translated(first), 2, "returning through another wrapper starts fresh")
end

local function test_leaving_command_discards_stale_status()
  reset_outputs()
  local env = new_env("tiger", "tiger.extended")
  assert_equal(press(env, 0x20), kAccepted, "export produces status")
  assert_equal(#translated(env), 1, "status is initially visible")
  env.engine.context.input = "other"
  assert_equal(#translated(env), 0, "unrelated input yields nothing")
  env.engine.context.input = "\\dcck"
  local candidates = translated(env)
  assert_equal(#candidates, 2, "returning to command starts fresh confirmation")
  assert_equal(candidates[1].text, "确认导出当前方案", "fresh confirmation after leaving command")
end

local tests = {
  test_contract_and_symbol_extraction,
  test_symbol_extraction_requires_exact_config_object_types,
  test_symbol_api_failures_are_reported,
  test_initial_confirmation_candidates,
  test_tiger_confirmed_export_and_success_status,
  test_tigress_confirmed_export,
  test_selection_and_cancellation_semantics,
  test_extra_command_candidate_selections_are_consumed,
  test_profile_config_source_and_snapshot_failures,
  test_failure_status_and_unrelated_input_or_key,
  test_symbol_api_failure_preserves_output_and_yields_status,
  test_atomic_open_write_and_close_failures,
  test_atomic_rename_failure_restores_previous_destination,
  test_windows_style_fallback_replaces_existing_destination,
  test_context_status_isolation_and_status_dismissal,
  test_context_properties_bridge_distinct_userdata_wrappers,
  test_leaving_command_discards_stale_status,
}

for _, test in ipairs(tests) do
  test()
end

os.execute("rm -rf " .. temp_dir)
print(string.format("table_export tests passed: %d", #tests))
