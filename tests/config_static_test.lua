local function read(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

local function assert_contains(text, pattern, label)
  if not text:find(pattern, 1, true) then
    error(label .. ": expected to find " .. pattern, 2)
  end
end

local function assert_not_contains(text, pattern, label)
  if text:find(pattern, 1, true) then
    error(label .. ": did not expect to find " .. pattern, 2)
  end
end

local function assert_file_missing(path, label)
  local file = io.open(path, "r")
  if file then
    file:close()
    error(label .. ": did not expect file to exist: " .. path, 2)
  end
end

local function assert_order(text, first, second, label)
  local a = text:find(first, 1, true)
  local b = text:find(second, 1, true)
  if not a or not b or a >= b then
    error(label .. ": expected " .. first .. " before " .. second, 2)
  end
end

local function assert_occurrences(text, pattern, expected, label)
  local count = 0
  local start = 1
  while true do
    local position = text:find(pattern, start, true)
    if not position then
      break
    end
    count = count + 1
    start = position + #pattern
  end
  if count ~= expected then
    error(label .. ": expected " .. expected .. " occurrences of " .. pattern .. ", got " .. count, 2)
  end
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label, tostring(expected), tostring(actual)), 2)
  end
end

local function processor_entries(text, label)
  local entries = {}
  local in_engine = false
  local in_processors = false
  local found_segmentors = false

  text = text:gsub("\r\n", "\n")
  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    local line = raw_line:gsub("#.*$", "")
    line = line:match("^%s*(.-)%s*$")
    if line == "engine:" then
      in_engine = true
    elseif in_engine and line == "processors:" then
      in_processors = true
    elseif in_processors and line == "segmentors:" then
      found_segmentors = true
      break
    elseif in_processors then
      local entry = line:match("^%-%s*(.-)%s*$")
      if entry then
        entries[#entries + 1] = entry
      end
    end
  end

  if not in_processors or not found_segmentors then
    error(label .. ": expected engine.processors block ending at segmentors", 3)
  end
  return entries
end

local function assert_processor_order(text, first, second, label)
  local first_count, second_count = 0, 0
  local first_index, second_index
  for index, entry in ipairs(processor_entries(text, label)) do
    if entry == first then
      first_count = first_count + 1
      first_index = index
    elseif entry == second then
      second_count = second_count + 1
      second_index = index
    end
  end
  if first_count ~= 1 then
    error(label .. ": expected exactly one processors entry " .. first, 2)
  end
  if second_count ~= 1 then
    error(label .. ": expected exactly one processors entry " .. second, 2)
  end
  if first_index >= second_index then
    error(label .. ": expected " .. first .. " before " .. second, 2)
  end
end

local function legacy_full_name(prefix)
  return prefix .. "_ful" .. "l"
end

local function test_default_schema_list_and_saved_option()
  local text = read("default.custom.yaml")
  assert_contains(text, "- {schema: tiger}", "schema list keeps tiger")
  assert_contains(text, "- {schema: tigress}", "schema list keeps tigress")
  assert_not_contains(text, "- {schema: " .. legacy_full_name("tiger") .. "}", "schema list hides old tiger variant")
  assert_not_contains(text, "- {schema: " .. legacy_full_name("tigress") .. "}", "schema list hides old tigress variant")
  assert_not_contains(text, legacy_full_name("tiger"), "default config must not reference old tiger variant")
  assert_not_contains(text, legacy_full_name("tigress"), "default config must not reference old tigress variant")
  assert_contains(text, "- extended_char", "save_options saves extended_char")
end

local function test_full_internal_files_are_removed()
  local paths = {
    legacy_full_name("tiger") .. ".schema.yaml",
    legacy_full_name("tiger") .. ".custom.yaml",
    legacy_full_name("tiger") .. ".extended.dict.yaml",
    legacy_full_name("tigress") .. ".schema.yaml",
    legacy_full_name("tigress") .. ".custom.yaml",
    legacy_full_name("tigress") .. ".extended.dict.yaml",
  }
  for _, path in ipairs(paths) do
    assert_file_missing(path, "full-named internal files are removed")
  end
end

local function test_schema_dictionaries_use_merged_sources()
  assert_contains(read("tiger.schema.yaml"), "__include: tiger_base.schema:/", "tiger includes base directly")
  assert_contains(read("tigress.schema.yaml"), "__include: tiger_base.schema:/", "tigress includes base directly")
  assert_contains(read("tiger.schema.yaml"), "dictionary: tiger.extended", "tiger uses merged dictionary")
  assert_contains(read("tigress.schema.yaml"), "dictionary: tigress.extended", "tigress uses merged dictionary")
  assert_contains(read("tiger.custom.yaml"), "__include: tiger_base.custom:/patch", "tiger custom includes base directly")
  assert_contains(read("tigress.custom.yaml"), "__include: tiger_base.custom:/patch", "tigress custom includes base directly")
  assert_not_contains(read("tiger.schema.yaml"), legacy_full_name("tiger"), "tiger schema must not reference old tiger variant")
  assert_not_contains(read("tigress.schema.yaml"), legacy_full_name("tigress"), "tigress schema must not reference old tigress variant")
  assert_not_contains(read("tiger.custom.yaml"), legacy_full_name("tiger"), "tiger custom must not reference old tiger variant")
  assert_not_contains(read("tigress.custom.yaml"), legacy_full_name("tigress"), "tigress custom must not reference old tigress variant")
end

local function test_extended_dictionaries_import_full_tables()
  local tiger = read("tiger.extended.dict.yaml")
  local tigress = read("tigress.extended.dict.yaml")
  assert_contains(tiger, "name: tiger.extended", "tiger extended dictionary keeps merged name")
  assert_contains(tiger, "  - tiger\n", "tiger extended imports full tiger table")
  assert_not_contains(tiger, "tiger.common", "tiger extended must not import common table")
  assert_contains(tigress, "name: tigress.extended", "tigress extended dictionary keeps merged name")
  assert_contains(tigress, "  - tigress\n", "tigress extended imports full tigress table")
  assert_contains(tigress, "  - tigress_ci\n", "tigress extended imports full word table")
  assert_contains(tigress, "  - tigress_simp_ci\n", "tigress extended imports full simplified word table")
  assert_not_contains(tigress, "tigress.common", "tigress extended must not import common table")
  assert_not_contains(tigress, "tigress_ci.common", "tigress extended must not import common word table")
end

local function test_base_schema_has_filter_switch_and_binding()
  local text = read("tiger_base.schema.yaml")
  local rime = read("rime.lua")
  local example = read("配置说明/示例.schema.yaml")
  assert_not_contains(text, legacy_full_name("tiger"), "base schema must not mention old tiger variant")
  assert_not_contains(text, legacy_full_name("tigress"), "base schema must not mention old tigress variant")
  assert_contains(text, "- core2022", "base depends on core2022")
  assert_contains(text, "- name: extended_char", "base defines extended_char")
  assert_not_contains(text, "reset: 1\n    states: [ 常用字, \"全字集 Ctrl+H\" ]", "extended_char should not reset every context")
  assert_contains(text, "states: [ 常用字, \"全字集 Ctrl+H\" ]", "extended_char defaults to common mode without reset")
  assert_contains(text, "lua_filter@*core2022_filter", "base includes core2022 filter")
  assert_order(text, "lua_filter@*core2022_filter", "simplifier@simplification", "base filters before simplification")
  assert_contains(rime, "candidate_shadow_filter = require(\"candidate_shadow_filter\")", "rime registers candidate shadow filter")
  assert_contains(text, "lua_filter@*candidate_shadow_filter", "base flattens nested shadow candidates")
  assert_order(text, "lua_filter@*candidate_shadow_filter", "uniquifier", "shadow flattening runs before uniquifier")
  assert_contains(example, "lua_filter@*candidate_shadow_filter", "schema example flattens nested shadow candidates")
  assert_order(example, "lua_filter@*candidate_shadow_filter", "uniquifier", "schema example flattens before uniquifier")
  assert_contains(text, "toggle: extended_char", "base binds extended_char toggle")
end

local function test_smart_candidate_selection_configuration()
  local base = read("tiger_base.schema.yaml")
  local custom = read("tiger_base.custom.yaml")
  local example = read("配置说明/示例.custom.yaml")
  local guide = read("配置说明/配置说明.txt")

  assert_contains(base, "smart_candidate_selection:", "base defines smart candidate selection")
  assert_contains(base, "enabled: true", "smart candidate selection defaults to enabled")
  assert_contains(base, "次选键跳过", "base setting has a Chinese behavior comment")
  assert_contains(custom, "smart_candidate_selection/enabled: false", "base custom exposes the disable override")
  assert_contains(custom, "恢复按候选位置选重", "disable override has a Chinese behavior comment")
  assert_contains(example, "smart_candidate_selection/enabled: true", "custom example documents the setting")
  assert_contains(example, "跳过 emoji/符号联想", "custom example explains enabled behavior")
  assert_contains(guide, "smart_candidate_selection/enabled: false", "guide documents how to disable smart selection")
  assert_contains(guide, "后续候选", "guide explains that smart selection scans beyond the first page")
  assert_contains(guide, "最多检查 512 项", "guide documents the bounded candidate scan")
  assert_contains(guide, "反斜杠符号菜单", "guide preserves explicit symbol menus")
  assert_contains(guide, "重新部署", "guide states how static setting changes take effect")
end

local function test_processor_order_ignores_misleading_substrings()
  local misleading = [[
engine:
  processors:
    - lua_processor@*tiger_user_words*processor_extra
    # lua_processor@*tiger_user_words*processor
    - ascii_composer
  segmentors:
    - abc_segmentor
]]
  local ok = pcall(
    assert_processor_order,
    misleading,
    "lua_processor@*tiger_user_words*processor",
    "ascii_composer",
    "processor order"
  )
  if ok then
    error("processor order must ignore misleading comments and values", 2)
  end
end

local function test_shared_user_word_management_order()
  local base = read("tiger_base.schema.yaml")
  assert_processor_order(base, "lua_processor@*tiger_user_words*processor", "ascii_composer", "user-word processor must run before ascii composer")
  assert_processor_order(base, "lua_processor@*tiger_user_words*processor", "lua_processor@*space_proc3", "user-word processor runs before space processor")
  assert_processor_order(base, "lua_processor@*tiger_user_words*processor", "lua_processor@*symbol_proc", "user-word processor runs before symbol processor")
  assert_contains(base, "lua_filter@*tiger_user_words*filter", "base includes shared user-word filter")
  assert_order(base, "lua_filter@*tiger_user_words*filter", "lua_filter@*core2022_filter", "user words run before charset filter")

  local tigress = read("tigress.schema.yaml")
  assert_not_contains(tigress, "\nengine:", "tigress inherits the shared engine")
  assert_not_contains(tigress, "tigress_user_words", "tigress no longer uses the compatibility component name")

  local example = read("配置说明/示例.schema.yaml")
  assert_contains(example, "lua_processor@*tiger_user_words*processor", "schema example includes shared user-word processor")
  assert_processor_order(example, "lua_processor@*tiger_user_words*processor", "lua_processor@*space_proc3", "schema example keeps processor order")
  assert_contains(example, "lua_filter@*tiger_user_words*filter", "schema example includes shared user-word filter")
  assert_order(example, "lua_filter@*tiger_user_words*filter", "lua_filter@*core2022_filter", "schema example keeps filter order")
  assert_not_contains(example, "单字版不要加", "schema example does not restrict user words to Tigress")
end

local function test_user_word_management_documentation()
  for _, path in ipairs({ "README.md", "配置说明/配置说明.txt" }) do
    local text = read(path)
    assert_contains(text, "tiger.user.dict.yaml", path .. " names the Tiger user dictionary")
    assert_contains(text, "tigress.user.dict.yaml", path .. " names the Tigress user dictionary")
    assert_contains(text, "Ctrl+;", path .. " documents the control shortcut")
    assert_contains(text, "编码 + \\\\ + Space", path .. " documents the backslash fallback")
    assert_not_contains(text, "不要把加词 Lua 加到 tiger", path .. " does not prohibit Tiger user words")
    assert_not_contains(text, "该功能接入 `tigress`", path .. " does not describe the feature as Tigress-only")
  end

  local schema_example = read("配置说明/示例.schema.yaml")
  local custom_example = read("配置说明/示例.custom.yaml")
  for _, example in ipairs({ schema_example, custom_example }) do
    assert_not_contains(example, "tigress_user_words", "examples use the shared component name")
    assert_not_contains(example, "单字版不要加", "examples do not restrict user words to Tigress")
  end
  assert_contains(custom_example, "tiger.user.dict.yaml", "custom example names the Tiger user dictionary")
  assert_contains(custom_example, "tigress.user.dict.yaml", "custom example names the Tigress user dictionary")
end

local function test_table_export_wiring()
  local rime = read("rime.lua")
  local base = read("tiger_base.schema.yaml")
  local hints = read("lua/symbol_hint.lua")

  assert_contains(rime, 'table_export = require("table_export")', "rime registers table export")
  assert_contains(base, "lua_processor@*table_export*processor", "base includes table export processor")
  assert_contains(base, "lua_translator@*table_export*translator", "base includes table export translator")
  assert_contains(hints, '{ code = "dcck", label = "导出词库" }', "symbol hints include table export")
  assert_order(base, "lua_processor@*table_export*processor", "key_binder", "table export processor runs before key binder")
  assert_order(base, "lua_translator@*table_export*translator", "table_translator", "table export translator runs before table translator")
  assert_occurrences(base, "lua_processor@*table_export*processor", 1, "base has one shared table export processor")
  assert_occurrences(base, "lua_translator@*table_export*translator", 1, "base has one shared table export translator")
end

local function test_table_export_hint_is_limited_to_supported_schemas()
  local previous_path = package.path
  package.path = "./lua/?.lua;" .. package.path
  package.loaded.symbol_hint = nil
  package.loaded.table_export = nil
  local symbol_hint = require("symbol_hint")
  local table_export = require("table_export")
  package.path = previous_path

  local function translate(input, schema_id, translators)
    local candidates = {}
    local previous_candidate = Candidate
    local previous_yield = yield
    Candidate = function(candidate_type, start, finish, text, comment)
      return { type = candidate_type, start = start, _end = finish, text = text, comment = comment }
    end
    yield = function(candidate)
      candidates[#candidates + 1] = candidate
    end
    local env
    if schema_id then
      env = { engine = { schema = { schema_id = schema_id } } }
    end
    local ok, err = pcall(function()
      for _, translator in ipairs(translators or { symbol_hint }) do
        translator(input, { start = 0, _end = #input }, env)
      end
    end)
    Candidate = previous_candidate
    yield = previous_yield
    assert(ok, err)
    return candidates
  end

  local function has_text(candidates, expected)
    for _, candidate in ipairs(candidates) do
      if candidate.text == expected then
        return true
      end
    end
    return false
  end

  for _, schema_id in ipairs({ "tiger", "tigress" }) do
    for _, input in ipairs({ "\\d", "\\dc", "\\dcc" }) do
      assert_equal(
        has_text(translate(input, schema_id), "\\dcck 导出词库"),
        true,
        schema_id .. " discovers table export from " .. input
      )
    end
    assert_equal(#translate("\\dcck", schema_id), 0, schema_id .. " exact command hides symbol hint")

    local combined = translate("\\dcck", schema_id, { symbol_hint, table_export.translator })
    assert_equal(#combined, 2, schema_id .. " exact command has only table export actions")
    assert_equal(combined[1].text, "确认导出当前方案", schema_id .. " first table export action")
    assert_equal(combined[2].text, "取消", schema_id .. " second table export action")
  end
  assert_equal(#translate("\\dcck", "PY_c"), 0, "PY_c hides table export hint")
  assert_equal(#translate("\\dcck"), 0, "missing schema hides table export hint")

  local pinyin_symbol = translate("\\fh", "PY_c")
  assert_equal(#pinyin_symbol, 1, "PY_c keeps existing symbol hints")
  assert_equal(pinyin_symbol[1].text, "\\fh 符号", "PY_c existing symbol hint text")
end

local tests = {
  test_default_schema_list_and_saved_option,
  test_full_internal_files_are_removed,
  test_schema_dictionaries_use_merged_sources,
  test_extended_dictionaries_import_full_tables,
  test_base_schema_has_filter_switch_and_binding,
  test_smart_candidate_selection_configuration,
  test_processor_order_ignores_misleading_substrings,
  test_shared_user_word_management_order,
  test_user_word_management_documentation,
  test_table_export_wiring,
  test_table_export_hint_is_limited_to_supported_schemas,
}

for _, test in ipairs(tests) do
  test()
end

print("config static tests passed")
