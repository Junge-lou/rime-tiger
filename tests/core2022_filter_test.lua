package.path = "./lua/?.lua;" .. package.path

local filter = require("core2022_filter")

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
  end
end

local function fake_db(common_chars)
  return {
    lookup = function(_, ch)
      if common_chars[ch] then
        return "ok"
      end
      return ""
    end,
  }
end

local common_db = fake_db({
  ["你"] = true,
  ["好"] = true,
  ["𠀀"] = true,
  ["\238\128\128"] = true, -- U+E000
})

local function test_full_mode_passes_uncommon_cjk()
  assert_equal(filter._test_should_yield("龘", true, common_db), true, "full mode should pass uncommon CJK")
end

local function test_common_mode_rejects_uncommon_cjk()
  assert_equal(filter._test_should_yield("龘", false, common_db), false, "common mode should reject uncommon CJK")
end

local function test_common_mode_passes_common_cjk()
  assert_equal(filter._test_should_yield("你好", false, common_db), true, "common mode should pass common CJK")
end

local function test_non_cjk_passes()
  assert_equal(filter._test_should_yield("abc123，。", false, common_db), true, "non-CJK should pass")
end

local function test_mixed_text_rejects_if_any_cjk_is_uncommon()
  assert_equal(filter._test_should_yield("你好龘!", false, common_db), false, "mixed uncommon CJK should reject")
end

local function test_extension_b_and_private_use_follow_lookup()
  assert_equal(filter._test_should_yield("𠀀", false, common_db), true, "known Extension-B char should pass")
  assert_equal(filter._test_should_yield("𠀁", false, common_db), false, "unknown Extension-B char should reject")
  assert_equal(filter._test_should_yield("\238\128\128", false, common_db), true, "known PUA char should pass")
  assert_equal(filter._test_should_yield("\238\128\129", false, common_db), false, "unknown PUA char should reject")
end

local function test_empty_nil_and_missing_db_fail_open()
  assert_equal(filter._test_should_yield("", false, common_db), true, "empty text should pass")
  assert_equal(filter._test_should_yield(nil, false, common_db), true, "nil text should pass")
  assert_equal(filter._test_should_yield("龘", false, nil), true, "missing db should fail open")
end

local function test_throwing_db_fails_open()
  local db = {
    lookup = function()
      error("lookup failed")
    end,
  }
  assert_equal(filter._test_should_yield("龘", false, db), true, "throwing db should fail open")
end

local function test_lookup_runs_for_each_cjk_character()
  local calls = 0
  local db = {
    lookup = function(_, ch)
      calls = calls + 1
      if ch == "你" then
        return "ok"
      end
      return ""
    end,
  }
  assert_equal(filter._test_should_yield("你你", false, db), true, "first lookup should pass")
  assert_equal(calls, 2, "each character should be looked up")
  assert_equal(filter._test_should_yield("你", false, db), true, "later lookup should pass")
  assert_equal(calls, 3, "later calls should query again")
end

local tests = {
  test_full_mode_passes_uncommon_cjk,
  test_common_mode_rejects_uncommon_cjk,
  test_common_mode_passes_common_cjk,
  test_non_cjk_passes,
  test_mixed_text_rejects_if_any_cjk_is_uncommon,
  test_extension_b_and_private_use_follow_lookup,
  test_empty_nil_and_missing_db_fail_open,
  test_throwing_db_fails_open,
  test_lookup_runs_for_each_cjk_character,
}

for _, test in ipairs(tests) do
  test()
end

print("core2022_filter tests passed")
