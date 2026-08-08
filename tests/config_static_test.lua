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
  assert_not_contains(text, legacy_full_name("tiger"), "base schema must not mention old tiger variant")
  assert_not_contains(text, legacy_full_name("tigress"), "base schema must not mention old tigress variant")
  assert_contains(text, "- core2022", "base depends on core2022")
  assert_contains(text, "- name: extended_char", "base defines extended_char")
  assert_not_contains(text, "reset: 1\n    states: [ 常用字, \"全字集 Ctrl+H\" ]", "extended_char should not reset every context")
  assert_contains(text, "states: [ 常用字, \"全字集 Ctrl+H\" ]", "extended_char defaults to common mode without reset")
  assert_contains(text, "lua_filter@*core2022_filter", "base includes core2022 filter")
  assert_order(text, "lua_filter@*core2022_filter", "simplifier@simplification", "base filters before simplification")
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
  assert_contains(guide, "反斜杠符号菜单", "guide preserves explicit symbol menus")
  assert_contains(guide, "重新部署", "guide states how static setting changes take effect")
end

local function test_shared_user_word_management_order()
  local base = read("tiger_base.schema.yaml")
  assert_contains(base, "lua_processor@*tiger_user_words*processor", "base includes shared user-word processor")
  assert_order(base, "lua_processor@*tiger_user_words*processor", "lua_processor@*space_proc3", "user-word processor runs before space processor")
  assert_order(base, "lua_processor@*tiger_user_words*processor", "lua_processor@*symbol_proc", "user-word processor runs before symbol processor")
  assert_contains(base, "lua_filter@*tiger_user_words*filter", "base includes shared user-word filter")
  assert_order(base, "lua_filter@*tiger_user_words*filter", "lua_filter@*core2022_filter", "user words run before charset filter")

  local tigress = read("tigress.schema.yaml")
  assert_not_contains(tigress, "\nengine:", "tigress inherits the shared engine")
  assert_not_contains(tigress, "tigress_user_words", "tigress no longer uses the compatibility component name")

  local example = read("配置说明/示例.schema.yaml")
  assert_contains(example, "lua_processor@*tiger_user_words*processor", "schema example includes shared user-word processor")
  assert_order(example, "lua_processor@*tiger_user_words*processor", "lua_processor@*space_proc3", "schema example keeps processor order")
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

local tests = {
  test_default_schema_list_and_saved_option,
  test_full_internal_files_are_removed,
  test_schema_dictionaries_use_merged_sources,
  test_extended_dictionaries_import_full_tables,
  test_base_schema_has_filter_switch_and_binding,
  test_smart_candidate_selection_configuration,
  test_shared_user_word_management_order,
  test_user_word_management_documentation,
}

for _, test in ipairs(tests) do
  test()
end

print("config static tests passed")
