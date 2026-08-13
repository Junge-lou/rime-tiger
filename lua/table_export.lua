local core = require("table_export_core")
local user_words = require("tiger_user_words")

local COMMAND = "\\dcck"
local K_ACCEPTED = rawget(_G, "kAccepted") or 1
local K_NOOP = rawget(_G, "kNoop") or 2

local KEY_SPACE = 0x20
local KEY_RETURN = 0xff0d
local KEY_ESCAPE = 0xff1b
local KEY_ONE = 0x31
local KEY_NINE = 0x39

local PROFILES = {
  tiger = {
    dictionary = "tiger.extended",
    output = "tiger_export.txt",
  },
  tigress = {
    dictionary = "tigress.extended",
    output = "tigress_export.txt",
  },
}

local PROPERTY_MODE = "table_export.mode"
local PROPERTY_STATUS_TEXT = "table_export.status_text"
local PROPERTY_STATUS_COMMENT = "table_export.status_comment"

local function bytewise_less(left, right)
  local length = math.min(#left, #right)
  for index = 1, length do
    local left_byte = string.byte(left, index)
    local right_byte = string.byte(right, index)
    if left_byte ~= right_byte then
      return left_byte < right_byte
    end
  end
  return #left < #right
end

local function safe_field(object, name)
  local ok, value = pcall(function()
    return object[name]
  end)
  if ok then
    return value
  end
  return nil
end

local function collect_keys(keys)
  if type(keys) ~= "table" then
    return nil, "ConfigMap:keys did not return an array"
  end
  local result = {}
  for index, key in ipairs(keys) do
    if type(key) ~= "string" then
      return nil, "ConfigMap:keys returned a non-string key at index " .. tostring(index)
    end
    result[#result + 1] = key
  end
  return result
end

local function has_config_type(object, expected_type)
  return safe_field(object, "type") == expected_type
end

local function scalar_value(object)
  if not has_config_type(object, "kScalar") then
    return nil
  end
  local value = safe_field(object, "value")
  if type(value) == "string" then
    return value
  end
  return nil
end

local function extract_symbols(config)
  local symbols = {}
  if not config then
    return symbols
  end

  local get_map = safe_field(config, "get_map")
  if type(get_map) ~= "function" then
    return nil, "config:get_map is unavailable"
  end
  local ok_map, map = pcall(get_map, config, "punctuator/symbols")
  if not ok_map then
    return nil, "config:get_map failed: " .. tostring(map)
  end
  if not map then
    return symbols
  end

  local keys_method = safe_field(map, "keys")
  local get_method = safe_field(map, "get")
  if type(keys_method) ~= "function" or type(get_method) ~= "function" then
    return nil, "ConfigMap keys/get API is unavailable"
  end
  local ok_keys, raw_keys = pcall(keys_method, map)
  if not ok_keys then
    return nil, "ConfigMap:keys failed: " .. tostring(raw_keys)
  end
  local string_keys, keys_err = collect_keys(raw_keys)
  if not string_keys then
    return nil, keys_err
  end
  table.sort(string_keys, bytewise_less)

  local order = 0
  for _, key in ipairs(string_keys) do
    local ok_item, item = pcall(get_method, map, key)
    if not ok_item then
      return nil, "ConfigMap map:get failed for " .. key .. ": " .. tostring(item)
    end
    if not item then
      return nil, "ConfigMap map:get returned missing item for " .. key
    end
    local get_obj = safe_field(item, "get_obj")
    if type(get_obj) ~= "function" then
      return nil, "ConfigItem:get_obj is unavailable for " .. key
    end
    local ok_obj, object = pcall(get_obj, item)
    if not ok_obj then
      return nil, "ConfigItem:get_obj failed for " .. key .. ": " .. tostring(object)
    end
    if not object then
      return nil, "ConfigItem:get_obj returned no object for " .. key
    end

    if has_config_type(object, "kScalar") then
      local value = scalar_value(object)
      if value then
        order = order + 1
        symbols[#symbols + 1] = { text = value, code = key, order = order }
      end
    elseif has_config_type(object, "kList") then
      local size = safe_field(object, "size")
      if type(size) ~= "number" or size < 0 or size % 1 ~= 0 then
        return nil, "ConfigList size is invalid for " .. key
      end
      local get_at = safe_field(object, "get_at")
      if type(get_at) ~= "function" then
        return nil, "ConfigList:get_at is unavailable for " .. key
      end
      for index = 0, size - 1 do
        order = order + 1
        local ok_child, child = pcall(get_at, object, index)
        if not ok_child then
          return nil, string.format("ConfigList:get_at failed for %s[%d]: %s", key, index, tostring(child))
        end
        if not child then
          return nil, string.format("ConfigList:get_at returned missing child for %s[%d]", key, index)
        end
        local child_get_obj = safe_field(child, "get_obj")
        if type(child_get_obj) ~= "function" then
          return nil, string.format("ConfigList child get_obj is unavailable for %s[%d]", key, index)
        end
        local ok_child_obj, child_object = pcall(child_get_obj, child)
        if not ok_child_obj then
          return nil, string.format("ConfigList child get_obj failed for %s[%d]: %s", key, index, tostring(child_object))
        end
        if not child_object then
          return nil, string.format("ConfigList child get_obj returned no object for %s[%d]", key, index)
        end
        local value = scalar_value(child_object)
        if value then
          symbols[#symbols + 1] = { text = value, code = key, order = order }
        end
      end
    end
  end
  return symbols
end

local function path_join(base_dir, filename)
  if string.match(base_dir, "[/\\]$") then
    return base_dir .. filename
  end
  return base_dir .. "/" .. filename
end

local function file_exists(path)
  local ok, file = pcall(io.open, path, "rb")
  if not ok or not file then
    return false
  end
  pcall(file.close, file)
  return true
end

local function safe_rename(from, to)
  local ok, renamed, err = pcall(os.rename, from, to)
  if not ok then
    return nil, renamed
  end
  return renamed, err
end

local function replace_file(temp_path, destination)
  local replaced, direct_err = safe_rename(temp_path, destination)
  if replaced then
    return true
  end
  if not file_exists(destination) then
    os.remove(temp_path)
    return nil, "替换导出文件失败：" .. tostring(direct_err or "无法移动临时文件")
  end

  local backup_path = destination .. ".bak"
  os.remove(backup_path)
  local backed_up, backup_err = safe_rename(destination, backup_path)
  if not backed_up then
    os.remove(temp_path)
    return nil, "替换导出文件失败：" .. tostring(backup_err or direct_err or "无法备份旧文件")
  end

  local installed, install_err = safe_rename(temp_path, destination)
  if installed then
    os.remove(backup_path)
    return true
  end

  local restored, restore_err = safe_rename(backup_path, destination)
  os.remove(temp_path)
  if restored then
    os.remove(backup_path)
    return nil, "替换导出文件失败：" .. tostring(install_err or direct_err or "无法安装临时文件")
  end
  return nil, "替换导出文件失败，旧文件保留在 " .. backup_path .. "："
    .. tostring(restore_err or install_err or direct_err)
end

local function write_atomic(destination, content)
  local temp_path = destination .. ".tmp"
  os.remove(temp_path)
  local open_ok, file, open_err = pcall(io.open, temp_path, "wb")
  if not open_ok or not file then
    os.remove(temp_path)
    return nil, "打开临时文件失败：" .. tostring(open_ok and open_err or file)
  end

  local write_ok, write_result, write_err = pcall(file.write, file, content)
  if not write_ok or not write_result then
    pcall(file.close, file)
    os.remove(temp_path)
    return nil, "写入临时文件失败：" .. tostring(write_ok and write_err or write_result)
  end

  local close_ok, close_result, close_err = pcall(file.close, file)
  if not close_ok or not close_result then
    os.remove(temp_path)
    return nil, "关闭临时文件失败：" .. tostring(close_ok and close_err or close_result)
  end
  return replace_file(temp_path, destination)
end

local function read_compiled_dictionary(config)
  if not config then
    return nil
  end
  local get_string = safe_field(config, "get_string")
  if type(get_string) ~= "function" then
    return nil
  end
  local ok, value = pcall(get_string, config, "translator/dictionary")
  if ok and type(value) == "string" then
    return value
  end
  return nil
end

local function skipped_count(stats)
  local count = 0
  for name, value in pairs(stats or {}) do
    if type(name) == "string" and string.match(name, "^skipped_") and type(value) == "number" then
      count = count + value
    end
  end
  return count
end

local function run_export(env)
  local schema = env and env.engine and env.engine.schema
  local schema_id = schema and schema.schema_id
  local profile = schema_id and PROFILES[schema_id]
  if not profile then
    return nil, "不支持当前方案：" .. tostring(schema_id or "未知")
  end

  local compiled_dictionary = read_compiled_dictionary(schema.config)
  if compiled_dictionary ~= profile.dictionary then
    return nil, string.format(
      "当前方案词典不匹配：应为 %s，实际为 %s",
      profile.dictionary,
      tostring(compiled_dictionary or "未配置")
    )
  end

  local dir_ok, base_dir = pcall(rime_api.get_user_data_dir)
  if not dir_ok or type(base_dir) ~= "string" or base_dir == "" then
    return nil, "无法获取用户目录：" .. tostring(dir_ok and base_dir or base_dir)
  end

  local snapshot_ok, user_records, snapshot_err = pcall(user_words.export_snapshot, schema_id)
  if not snapshot_ok then
    return nil, "导出用户词快照失败：" .. tostring(user_records)
  end
  if type(user_records) ~= "table" then
    return nil, "导出用户词快照失败：" .. tostring(snapshot_err or "无可用快照")
  end

  local symbols, symbols_err = extract_symbols(schema.config)
  if not symbols then
    return nil, "读取符号配置失败：" .. tostring(symbols_err)
  end
  local build_ok, content, stats = pcall(core.build, {
    dictionary = profile.dictionary,
    base_dir = base_dir,
    symbols = symbols,
    user_records = user_records,
  })
  if not build_ok then
    return nil, "生成导出内容失败：" .. tostring(content)
  end
  if type(content) ~= "string" then
    return nil, "生成导出内容失败：" .. tostring(stats or "未知错误")
  end

  local destination = path_join(base_dir, profile.output)
  local written, write_err = write_atomic(destination, content)
  if not written then
    return nil, write_err
  end

  return {
    ok = true,
    schema_id = schema_id,
    dictionary = profile.dictionary,
    path = destination,
    exported = stats.exported or 0,
    skipped = skipped_count(stats),
    stats = stats,
  }
end

local function context_from(env)
  return env and env.engine and env.engine.context
end

local function read_property(context, name)
  local get_property = context and safe_field(context, "get_property")
  if type(get_property) ~= "function" then
    return nil
  end
  local ok, value = pcall(get_property, context, name)
  if ok and type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function write_property(context, name, value)
  local set_property = context and safe_field(context, "set_property")
  if type(set_property) ~= "function" then
    return false
  end
  return pcall(set_property, context, name, value)
end

local function clear_export_state(context)
  local clear_property = context and safe_field(context, "clear_property")
  if type(clear_property) == "function" then
    pcall(clear_property, context, PROPERTY_MODE)
    pcall(clear_property, context, PROPERTY_STATUS_TEXT)
    pcall(clear_property, context, PROPERTY_STATUS_COMMENT)
    return
  end
  write_property(context, PROPERTY_MODE, "")
  write_property(context, PROPERTY_STATUS_TEXT, "")
  write_property(context, PROPERTY_STATUS_COMMENT, "")
end

local function read_export_status(context)
  if read_property(context, PROPERTY_MODE) ~= "status" then
    return nil
  end
  local text = read_property(context, PROPERTY_STATUS_TEXT)
  if not text then
    return nil
  end
  return {
    text = text,
    comment = read_property(context, PROPERTY_STATUS_COMMENT) or "",
  }
end

local function write_export_status(context, text, comment)
  if not write_property(context, PROPERTY_STATUS_TEXT, text)
      or not write_property(context, PROPERTY_STATUS_COMMENT, comment or "")
      or not write_property(context, PROPERTY_MODE, "status") then
    clear_export_state(context)
    return false
  end
  return true
end

local function yield_candidate(seg, candidate_type, text, comment, quality)
  local candidate = Candidate(candidate_type, seg.start, seg._end, text, comment or "")
  candidate.quality = quality or 1200
  yield(candidate)
end

local function translator(input, seg, env)
  local context = context_from(env)
  if input ~= COMMAND then
    if read_property(context, PROPERTY_MODE) then
      clear_export_state(context)
    end
    return
  end
  local state = read_export_status(context)
  if state then
    yield_candidate(seg, "table_export_status", state.text, state.comment, 1200)
    return
  end
  yield_candidate(seg, "table_export", "确认导出当前方案", "生成可导入的码表文件", 1200)
  yield_candidate(seg, "table_export", "取消", "不导出", 1199)
end

local function safe_key_method(key_event, name)
  local method = key_event and safe_field(key_event, name)
  if type(method) ~= "function" then
    return false
  end
  local ok, value = pcall(method, key_event)
  return ok and value and true or false
end

local function selected_index(context)
  if context and context.composition then
    local back = safe_field(context.composition, "back")
    if type(back) == "function" then
      local ok, segment = pcall(back, context.composition)
      if ok and segment and type(segment.selected_index) == "number" then
        return segment.selected_index
      end
    end
  end
  return 0
end

local function clear_context(context)
  local clear = context and safe_field(context, "clear")
  if type(clear) == "function" then
    pcall(clear, context)
  end
end

local function refresh_context(context)
  local refresh = context and safe_field(context, "refresh_non_confirmed_composition")
  if type(refresh) == "function" then
    pcall(refresh, context)
  end
end

local processor = {}

function processor.func(key_event, env)
  local context = context_from(env)
  if not context or context.input ~= COMMAND then
    return K_NOOP
  end
  if safe_key_method(key_event, "release")
      or safe_key_method(key_event, "ctrl")
      or safe_key_method(key_event, "alt")
      or safe_key_method(key_event, "shift")
      or safe_key_method(key_event, "caps")
      or safe_key_method(key_event, "super") then
    return K_NOOP
  end

  local keycode = key_event and key_event.keycode
  local is_digit_selection = type(keycode) == "number" and keycode >= KEY_ONE and keycode <= KEY_NINE
  local is_selection = keycode == KEY_SPACE or keycode == KEY_RETURN
    or is_digit_selection
  if keycode ~= KEY_ESCAPE and not is_selection then
    return K_NOOP
  end

  if read_export_status(context) then
    clear_export_state(context)
    clear_context(context)
    return K_ACCEPTED
  end
  if keycode == KEY_ESCAPE then
    clear_context(context)
    return K_ACCEPTED
  end

  local action_index
  if is_digit_selection then
    action_index = keycode - KEY_ONE
  else
    action_index = selected_index(context)
  end
  if action_index == 1 then
    clear_context(context)
    return K_ACCEPTED
  end
  if action_index ~= 0 then
    return K_ACCEPTED
  end

  local call_ok, result, export_err = pcall(run_export, env)
  if call_ok and result then
    write_export_status(
      context,
      string.format(
        "导出成功：%d 条，跳过 %d 条｜%s",
        result.exported,
        result.skipped,
        result.path
      ),
      result.path
    )
  else
    write_export_status(
      context,
      "导出失败：" .. tostring(call_ok and export_err or result),
      "请检查当前方案和用户目录"
    )
  end
  refresh_context(context)
  return K_ACCEPTED
end

return {
  command = COMMAND,
  translator = translator,
  processor = processor,
  extract_symbols = extract_symbols,
  _test_export = run_export,
}
