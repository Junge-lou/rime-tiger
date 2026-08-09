package.path = "./lua/?.lua;" .. package.path

local user_data_dir = "/tmp/rime-tiger-input-speed-stat-test"
os.execute("rm -rf " .. user_data_dir)
os.execute("mkdir -p " .. user_data_dir .. "/lua")

local clock_ms = 1000
local epoch = 1780000000
rime_api = {
  get_user_data_dir = function()
    return user_data_dir
  end,
  get_time_ms = function()
    return clock_ms
  end,
  get_distribution_code_name = function()
    return "test-rime"
  end,
  get_distribution_version = function()
    return "test"
  end,
}

local option_state = require("option_state")
local stat = require("input_speed_stat")

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
  end
end

local function assert_close(actual, expected, tolerance, label)
  if math.abs(actual - expected) > tolerance then
    error(string.format("%s: expected %.6f, got %.6f", label, expected, actual), 2)
  end
end

local function assert_contains(text, expected, label)
  if not string.find(text, expected, 1, true) then
    error(string.format("%s: expected %q in %q", label, expected, text), 2)
  end
end

local function assert_not_contains(text, rejected, label)
  if string.find(text, rejected, 1, true) then
    error(string.format("%s: did not expect %q in %q", label, rejected, text), 2)
  end
end

local function write_text(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function read_text(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

local function path_exists(path)
  local file = io.open(path, "r")
  if not file then
    return false
  end
  file:close()
  return true
end

local function enabled_env()
  local options = { input_speed_stat = true }
  local ctx = {
    get_option = function(_, name)
      return options[name] and true or false
    end,
    set_option = function(_, name, value)
      options[name] = value and true or false
    end,
    option_update_notifier = { connect = function() return { disconnect = function() end } end },
  }
  return { engine = { context = ctx, schema = { schema_id = "tiger" } } }
end

local function reset()
  option_state._test_reset()
  stat._test_reset({
    now_ms = function() return clock_ms end,
    os_time = function() return epoch end,
  })
end

local function test_pure_chinese_commits_use_type_sunny_word_rate()
  reset()
  local env = enabled_env()

  stat._test_record_commit("你", env, { input = "ab", hit_count = 2, manual = true })
  stat._test_record_commit("好吗", env, { input = "cde", hit_count = 3, auto = true })
  stat._test_record_commit("abc", env, { input = "abc", hit_count = 3, manual = true })
  stat._test_record_commit("你好!", env, { input = "abcd", hit_count = 4, manual = true })

  local daily = stat._test_state().stats.daily
  assert_equal(daily.commits, 2, "only pure Chinese commits count")
  assert_equal(daily.chars, 3, "pure Chinese character count")
  assert_equal(daily.word_chars, 2, "word characters")
  assert_equal(daily.single_commit_count, 1, "single-character commit count")
  assert_equal(daily.word_commit_count, 1, "word commit count")
  assert_equal(daily.lengths[1], 1, "one-character distribution")
  assert_equal(daily.lengths[2], 1, "two-character distribution")
  assert_close(stat._test_metrics(daily).word_rate, 2 / 3 * 100, 0.001, "TypeSunny word rate")
end

local function test_real_key_events_are_committed_only_after_valid_chinese_output()
  reset()
  local env = enabled_env()

  stat._test_key(string.byte("a"), env)
  stat._test_key(string.byte("b"), env)
  stat._test_update_input("ab", env)
  stat._test_key(0xff08, env)
  stat._test_update_input("", env)
  stat._test_key(string.byte("c"), env)
  stat._test_update_input("ac", env)
  stat._test_key(0x20, env)
  stat._test_record_commit("你", env)

  local daily = stat._test_state().stats.daily
  assert_equal(daily.hit_count, 3, "encoding key count")
  assert_equal(daily.backspace_count, 1, "backspace count")
  assert_equal(daily.final_code_length, 2, "final code length excludes space")
  assert_equal(daily.manual_commit_count, 1, "manual commit count")
  assert_equal(daily.space_commit_count, 1, "physical space commit count")
  assert_equal(daily.auto_commit_count, 0, "auto commit count")
  assert_equal(daily.code_lengths[2], 1, "code length distribution")
end

local function test_return_and_digit_commits_are_neither_space_nor_auto_commit()
  reset()
  local env = enabled_env()

  stat._test_key(string.byte("a"), env)
  stat._test_update_input("a", env)
  stat._test_key(0xff0d, env)
  stat._test_record_commit("你", env)

  stat._test_key(string.byte("b"), env)
  stat._test_update_input("b", env)
  stat._test_key(string.byte("2"), env)
  stat._test_record_commit("好", env)

  local daily = stat._test_state().stats.daily
  assert_equal(daily.manual_commit_count, 2, "return and digit remain manual confirmations")
  assert_equal(daily.space_commit_count, 0, "return and digit do not count as spaces")
  assert_equal(daily.auto_commit_count, 0, "return and digit do not count as auto commits")
end

local function test_space_without_active_composition_does_not_leak_to_next_commit()
  reset()
  local env = enabled_env()

  stat._test_key(0x20, env)
  stat._test_key(string.byte("a"), env)
  stat._test_update_input("a", env)
  stat._test_record_commit("你", env)

  local daily = stat._test_state().stats.daily
  assert_equal(daily.space_commit_count, 0, "empty-composition space is ignored")
  assert_equal(daily.manual_commit_count, 0, "next commit is not marked manual")
  assert_equal(daily.auto_commit_count, 1, "next commit remains auto commit")
end

local function test_backspace_without_active_composition_does_not_leak_to_next_commit()
  reset()
  local env = enabled_env()

  stat._test_key(0xff08, env)
  stat._test_key(string.byte("a"), env)
  stat._test_update_input("a", env)
  stat._test_record_commit("你", env)

  local daily = stat._test_state().stats.daily
  assert_equal(daily.backspace_count, 0, "empty-composition backspace is ignored")
  assert_equal(daily.hit_count, 1, "next commit keeps only its encoding key")
end

local function test_non_encoding_keys_after_composition_is_erased_do_not_leak()
  reset()
  local env = enabled_env()

  stat._test_key(string.byte("a"), env)
  stat._test_update_input("a", env)
  stat._test_key(0xff08, env)
  stat._test_update_input("", env)
  stat._test_key(0x20, env)
  stat._test_key(0xff08, env)
  stat._test_key(string.byte("b"), env)
  stat._test_update_input("b", env)
  stat._test_record_commit("你", env)

  local daily = stat._test_state().stats.daily
  assert_equal(daily.backspace_count, 1, "only the backspace that erased active composition counts")
  assert_equal(daily.space_commit_count, 0, "space pressed after composition is erased is ignored")
  assert_equal(daily.manual_commit_count, 0, "erased-composition space does not mark the next commit manual")
  assert_equal(daily.auto_commit_count, 1, "next commit remains auto commit")
  assert_equal(daily.hit_count, 2, "encoding keys before and after correction both count")
end

local function test_enabled_state_is_cached_between_key_events()
  reset()
  local env = enabled_env()
  local ctx = env.engine.context
  local get_calls = 0
  local original_get = ctx.get_option
  ctx.get_option = function(self, name)
    get_calls = get_calls + 1
    return original_get(self, name)
  end

  stat.init(env)
  get_calls = 0
  stat._test_key(string.byte("a"), env)
  stat._test_key(string.byte("b"), env)
  assert_equal(get_calls, 0, "cached enabled state should avoid per-key option reads")
end

local function test_invalid_commits_discard_keys_and_auto_commit_is_distinct()
  reset()
  local env = enabled_env()

  stat._test_key(string.byte("a"), env)
  stat._test_update_input("a1", env)
  stat._test_record_commit("你1", env)

  stat._test_key(string.byte("b"), env)
  stat._test_update_input("b", env)
  stat._test_record_commit("好", env)

  local daily = stat._test_state().stats.daily
  assert_equal(daily.commits, 1, "invalid commit is discarded")
  assert_equal(daily.hit_count, 1, "invalid keys do not leak")
  assert_equal(daily.backspace_count, 0, "invalid corrections do not leak")
  assert_equal(daily.manual_commit_count, 0, "auto commit count")
  assert_equal(daily.auto_commit_count, 1, "auto commit is distinct")
end

local function test_session_cutoff_minimum_and_peak_window()
  reset()
  local env = enabled_env()

  stat._test_record_commit("你", env, { input = "a", hit_count = 1 })
  clock_ms = 1500
  stat._test_record_commit("好", env, { input = "b", hit_count = 1 })
  clock_ms = 7000
  stat._test_record_commit("吗", env, { input = "c", hit_count = 1 })

  local daily = stat._test_state().stats.daily
  assert_close(daily.seconds, 0, 0.001, "short session is excluded")
end

local function test_period_report_settles_active_segment_and_updates_peak()
  clock_ms = 1000
  reset()
  local env = enabled_env()

  for _, time_ms in ipairs({ 1000, 5000, 9000, 13000 }) do
    clock_ms = time_ms
    stat._test_record_commit("你", env, { input = "a", hit_count = 1 })
  end

  local brief = stat._test_brief(env)
  local daily = stat._test_state().stats.daily
  assert_close(daily.seconds, 12, 0.001, "report settles current segment time")
  assert_equal(math.floor(daily.peak.speed + 0.5), 20, "peak uses completed twelve-second segment")
  assert_contains(brief, "均速 20 · 峰速 20", "settled report speed")
  assert_contains(brief, "击键 0.33", "settled report hit rate")

  local seconds_after_first_report = daily.seconds
  local second_brief = stat._test_brief(env)
  assert_close(daily.seconds, seconds_after_first_report, 0.001,
    "repeated report does not settle the same segment twice")
  assert_contains(second_brief, "均速 20 · 峰速 20", "repeated report remains stable")
end

local function test_peak_accumulates_completed_segments_to_ten_seconds()
  clock_ms = 1000
  reset()
  local env = enabled_env()

  for _, time_ms in ipairs({ 1000, 5000, 11000, 15000, 21000, 23000 }) do
    clock_ms = time_ms
    stat._test_record_commit("你", env, { input = "a", hit_count = 1 })
  end

  local brief = stat._test_brief(env)
  local daily = stat._test_state().stats.daily
  assert_close(daily.speed_seconds, 10, 0.001, "three valid segments total ten seconds")
  assert_equal(math.floor(daily.peak.speed + 0.5), 36, "peak accumulates recent completed segments")
  assert_close(daily.peak.hit, 0.6, 0.001, "peak keeps matching hit rate")
  assert_close(daily.peak.code_length, 1, 0.001, "peak keeps matching code length")
  assert_contains(brief, "均速 36 · 峰速 36", "multi-segment peak is shown")
end

local function test_session_is_split_before_date_rollover()
  epoch = os.time({ year = 2026, month = 8, day = 8, hour = 23, min = 59, sec = 59 })
  clock_ms = 2000
  reset()
  local env = enabled_env()

  stat._test_record_commit("昨", env, {
    input = "a", hit_count = 1, input_start_ms = 1000,
  })

  epoch = os.time({ year = 2026, month = 8, day = 9, hour = 0, min = 0, sec = 1 })
  clock_ms = 4000
  stat._test_record_commit("今", env, {
    input = "b", hit_count = 1, input_start_ms = 3000,
  })

  local brief = stat._test_brief(env)
  local stats = stat._test_state().stats
  assert_equal(stats.daily.metric_chars, 1, "new day contains only new-day characters")
  assert_close(stats.daily.speed_seconds, 1, 0.001, "new day contains only new-day duration")
  assert_equal(stats.daily.speed_chars, 1, "new day contains only new-day speed characters")
  assert_contains(brief, "均速 60", "new-day average excludes previous-day segment")
  assert_close(stats.weekly.speed_seconds, 2, 0.001, "same week keeps both split segments")
  assert_equal(stats.weekly.speed_chars, 2, "same week keeps both segments' characters")
end

local function test_weekly_peak_can_span_days_in_the_same_week()
  epoch = os.time({ year = 2026, month = 8, day = 8, hour = 23, min = 59, sec = 40 })
  clock_ms = 1000
  reset()
  local env = enabled_env()

  for index, time_ms in ipairs({ 1000, 5000, 9000 }) do
    clock_ms = time_ms
    stat._test_record_commit(({ "昨", "夜", "晚" })[index], env,
      { input = "a", hit_count = 1 })
  end
  stat._test_brief(env)

  epoch = os.time({ year = 2026, month = 8, day = 9, hour = 0, min = 0, sec = 10 })
  clock_ms = 11000
  stat._test_record_commit("今", env, { input = "c", hit_count = 1 })
  clock_ms = 16000
  stat._test_record_commit("晨", env, { input = "d", hit_count = 1 })
  stat._test_details(env)

  local weekly = stat._test_state().stats.weekly
  assert_close(weekly.speed_seconds, 13, 0.001, "weekly speed includes both days")
  assert_equal(math.floor(weekly.peak.speed + 0.5), 23,
    "weekly peak accumulates segments across the day boundary")
  assert_equal(stat._test_state().stats.daily.peak.speed, 0,
    "daily peak does not include the previous day's segment")
end

local function test_peak_tail_survives_statistics_reload()
  epoch = os.time({ year = 2026, month = 8, day = 9, hour = 12 })
  clock_ms = 1000
  reset()
  local env = enabled_env()
  os.remove(stat._test_stats_file(env))
  os.remove(user_data_dir .. "/lua/input_speed_stat_tiger.lua")
  os.remove(user_data_dir .. "/lua/input_speed_stat_tigress.lua")
  stat.init(env)

  for _, time_ms in ipairs({ 1000, 4000, 7000 }) do
    clock_ms = time_ms
    stat._test_record_commit("你", env, { input = "a", hit_count = 1 })
  end
  stat._test_brief(env)
  stat.fini()

  reset()
  local reloaded_env = enabled_env()
  stat.init(reloaded_env)
  for _, time_ms in ipairs({ 8000, 12000 }) do
    clock_ms = time_ms
    stat._test_record_commit("好", reloaded_env, { input = "b", hit_count = 1 })
  end
  stat._test_brief(reloaded_env)

  local daily = stat._test_state().stats.daily
  assert_close(daily.speed_seconds, 10, 0.001, "reloaded daily duration keeps both segments")
  assert_equal(math.floor(daily.peak.speed + 0.5), 30,
    "reloaded peak combines the persisted six-second tail with the new segment")
  stat.fini()
end

local function test_failed_save_write_preserves_previous_file_and_dirty_state()
  reset()
  local env = enabled_env()
  local path = stat._test_stats_file(env)
  local previous = "return { previous = true }\n"
  write_text(path, previous)
  os.remove(path .. ".tmp")
  stat._test_record_commit("你", env, { input = "a", hit_count = 1 })

  local original_open = io.open
  io.open = function(open_path, mode)
    if mode == "w" then
      local partial = assert(original_open(open_path, mode))
      return {
        write = function()
          partial:write("partial")
          return nil, "simulated write failure"
        end,
        close = function()
          return partial:close()
        end,
      }
    end
    return original_open(open_path, mode)
  end
  local call_ok, saved = pcall(stat.save, false)
  io.open = original_open

  assert_equal(call_ok, true, "save handles write failure")
  assert_equal(read_text(path), previous, "failed write preserves previous statistics file")
  assert_equal(stat._test_state().dirty, true, "failed write remains dirty for retry")
  assert_equal(saved, false, "failed write reports failure")
  os.remove(path .. ".tmp")
end

local function test_failed_save_replace_preserves_previous_file_and_dirty_state()
  reset()
  local env = enabled_env()
  local path = stat._test_stats_file(env)
  local previous = "return { previous = true }\n"
  write_text(path, previous)
  os.remove(path .. ".tmp")
  stat._test_record_commit("你", env, { input = "a", hit_count = 1 })

  local original_rename = os.rename
  os.rename = function()
    return nil, "simulated replace failure"
  end
  local call_ok, saved = pcall(stat.save, false)
  os.rename = original_rename

  assert_equal(call_ok, true, "save handles replace failure")
  assert_equal(read_text(path), previous, "failed replace preserves previous statistics file")
  assert_equal(stat._test_state().dirty, true, "failed replace remains dirty for retry")
  assert_equal(saved, false, "failed replace reports failure")
  os.remove(path .. ".tmp")
end

local function test_backup_is_recovered_after_save_rollback_failure()
  reset()
  local env = enabled_env()
  local path = stat._test_stats_file(env)
  os.remove(path)
  os.remove(path .. ".tmp")
  os.remove(path .. ".bak")
  stat._test_record_commit("你", env, { input = "a", hit_count = 1 })
  assert_equal(stat.save(false), true, "baseline statistics save")
  stat._test_record_commit("好", env, { input = "b", hit_count = 1 })

  local original_rename = os.rename
  local rename_calls = 0
  os.rename = function(from_path, to_path)
    rename_calls = rename_calls + 1
    if rename_calls == 2 then
      return original_rename(from_path, to_path)
    end
    return nil, "simulated rename failure"
  end
  local call_ok, saved = pcall(stat.save, false)
  os.rename = original_rename

  assert_equal(call_ok, true, "save handles rollback failure")
  assert_equal(saved, false, "rollback failure reports save failure")
  assert_equal(path_exists(path), false, "failed rollback leaves the normal path unavailable")
  assert_equal(path_exists(path .. ".bak"), true, "failed rollback retains the last valid backup")

  reset()
  local recovered_env = enabled_env()
  stat.init(recovered_env)
  assert_equal(stat._test_state().stats.daily.metric_commits, 1,
    "initialization recovers the last valid statistics")
  assert_equal(path_exists(path), true, "recovery restores the normal statistics path")
  assert_equal(path_exists(path .. ".bak"), false, "recovery consumes the backup file")
  stat.fini()
end

local function test_compact_and_detailed_reports_use_requested_terms()
  reset()
  local env = enabled_env()
  local daily = stat._test_state().stats.daily
  daily.commits = 95
  daily.chars = 133
  daily.seconds = 105
  daily.speed_chars = 133
  daily.speed_seconds = 105
  daily.speed_hit_count = 340
  daily.metric_chars = 133
  daily.metric_commits = 95
  daily.hit_count = 340
  daily.final_code_length = 340
  daily.manual_commit_count = 84
  daily.space_commit_count = 83
  daily.auto_commit_count = 11
  daily.word_chars = 74
  daily.backspace_count = 7
  daily.peak.speed = 108
  daily.lengths = { [1] = 59, [2] = 33, [3] = 2, [4] = 0, [5] = 1 }
  daily.code_lengths = { [1] = 19, [2] = 27, [3] = 8, [4] = 35, [5] = 6 }

  local brief = stat._test_brief(env)
  assert_contains(brief, "上屏 95 次", "brief commits")
  assert_contains(brief, "字数 133", "brief chars")
  assert_contains(brief, "击键 3.24", "brief hit rate")
  assert_contains(brief, "码长 2.56", "brief code length")
  assert_contains(brief, "打词率 55.6%", "brief word rate")
  assert_contains(brief, "空格 83 次 · 顶屏 11 次", "brief commit mode counts")
  assert_contains(brief, "回改 7 次 · 回改率 2.1%", "brief corrections")
  assert_not_contains(brief, "键/秒", "brief does not invent key unit")
  assert_not_contains(brief, "平均编码", "brief uses code length")
  assert_not_contains(brief, "词组连打", "brief uses word rate")

  local rows = stat._test_details(env)
  assert_equal(#rows, 4, "four detailed periods")
  assert_contains(rows[1].text, "今日统计", "daily detail")
  assert_contains(rows[2].text, "本周统计", "weekly detail")
  assert_contains(rows[3].text, "本月统计", "monthly detail")
  assert_contains(rows[4].text, "本年统计", "yearly detail")
  assert_contains(rows[1].text, "字词分布", "word distribution")
  assert_contains(rows[1].text, "编码分布", "code distribution")
  assert_contains(rows[1].text, "[+]", "long word distribution")
  assert_contains(rows[1].text, "[其他]", "other code distribution")
  assert_contains(rows[1].text, "空格 83 次 · 顶屏 11 次", "detailed commit mode counts")
end


local function test_mixed_legacy_totals_do_not_dilute_new_efficiency_metrics()
  clock_ms = 1000
  reset()
  local env = enabled_env()
  local date = os.date("*t", epoch)
  local current_path = stat._test_stats_file(env)
  write_text(current_path, string.format([[return {
    stats = {
      daily = {
        commits = 2, chars = 100, seconds = 200,
        hit_count = 4, final_code_length = 4,
        manual_commit_count = 1, auto_commit_count = 1,
        word_chars = 0, lengths = { [1] = 2 }, code_lengths = { [2] = 2 },
        peak = { speed = 0, hit = 0, code_length = 0 },
      },
      last_update = { year = %d, month = %d, day = %d, wday = %d },
    },
  }]], date.year, date.month, date.day, date.wday))
  stat.init(env)

  stat._test_record_commit("你", env, { input = "ab", hit_count = 2, input_start_ms = 1000 })
  clock_ms = 3000
  stat._test_record_commit("好", env, { input = "cd", hit_count = 2 })

  local brief = stat._test_brief(env)
  assert_contains(brief, "字数 4", "dashboard excludes incompatible legacy chars")
  assert_contains(brief, "均速 60", "legacy seconds do not lower new average speed")
  assert_contains(brief, "击键 2.00", "legacy seconds do not lower new hit rate")
  stat.fini()
end

local function test_legacy_schema_file_does_not_invent_speed_cohort()
  clock_ms = 1000
  reset()
  local env = enabled_env()
  local date = os.date("*t", epoch)
  os.remove(stat._test_stats_file(env))
  os.remove(user_data_dir .. "/lua/input_speed_stat_tigress.lua")
  write_text(user_data_dir .. "/lua/input_speed_stat_tiger.lua", string.format([[return {
    stats = {
      daily = {
        commits = 2, chars = 3, seconds = 2,
        hit_count = 4, final_code_length = 4,
        manual_commit_count = 1, auto_commit_count = 1,
        word_chars = 2, lengths = { [1] = 1, [2] = 1 },
        code_lengths = { [2] = 2 },
      },
      last_update = { year = %d, month = %d, day = %d, wday = %d },
    },
  }]], date.year, date.month, date.day, date.wday))

  stat.init(env)
  local brief = stat._test_brief(env)
  assert_contains(brief, "上屏 2 次 · 字数 3", "legacy counts are recovered")
  assert_contains(brief, "均速 0", "legacy duration is not assigned to an unknown character cohort")
  assert_contains(brief, "击键 0.00", "legacy hits are not assigned to an unknown duration cohort")
  assert_contains(brief, "码长 1.33", "compatible legacy code length is recovered")
  stat.fini()
end

local function test_shared_file_and_legacy_data_normalization()
  reset()
  local tiger_env = enabled_env()
  local tigress_env = enabled_env()
  tigress_env.engine.schema.schema_id = "tigress"
  os.remove(stat._test_stats_file(tiger_env))
  os.remove(user_data_dir .. "/lua/input_speed_stat_tiger.lua")
  os.remove(user_data_dir .. "/lua/input_speed_stat_tigress.lua")
  assert_equal(stat._test_stats_file(tiger_env), stat._test_stats_file(tigress_env),
    "tiger and tigress share the statistics file")

  local legacy_date = os.date("*t", epoch)
  local legacy_path = user_data_dir .. "/lua/input_speed_stat_tiger.lua"
  write_text(legacy_path, string.format([[return {
    stats = {
      daily = { chars = 5, seconds = 2 },
      monthly = { chars = 5, seconds = 2 },
      yearly = { chars = 5, seconds = 2 },
      total = { chars = 5, seconds = 2 },
      last_update = { year = %d, month = %d, day = %d, wday = %d },
    },
  }]], legacy_date.year, legacy_date.month, legacy_date.day, legacy_date.wday))
  stat.init(tiger_env)
  local migrated = stat._test_state().stats
  assert_equal(migrated.daily.chars, 5, "legacy daily chars")
  assert_equal(migrated.weekly.chars, 0, "legacy weekly starts empty")
  assert_equal(migrated.total.chars, 5, "legacy total chars")
  stat.fini()

  reset()
  local current_env = enabled_env()
  local current_path = stat._test_stats_file(current_env)
  write_text(current_path, string.format([[return {
    stats = {
      daily = {
        chars = -2, seconds = -1, hit_count = "bad",
        lengths = { [-1] = -4, [2] = "3" },
        peak = { speed = -1 },
      },
      last_update = { year = %d, month = %d, day = %d, wday = %d },
    },
  }]], legacy_date.year, legacy_date.month, legacy_date.day, legacy_date.wday))
  stat.init(current_env)
  local normalized = stat._test_state().stats.daily
  assert_equal(normalized.chars, 0, "negative chars normalize to zero")
  assert_equal(normalized.seconds, 0, "negative seconds normalize to zero")
  assert_equal(normalized.hit_count, 0, "invalid hit count normalizes to zero")
  assert_equal(normalized.lengths[2], 3, "numeric distribution survives normalization")
  assert_equal(normalized.peak.speed, 0, "negative peak normalizes to zero")
  stat.fini()
end

local function test_day_week_month_and_year_rollovers()
  epoch = os.time({ year = 2026, month = 1, day = 31, hour = 12 })
  clock_ms = 1000
  reset()
  local env = enabled_env()
  stat._test_record_commit("你", env, { input = "a", hit_count = 1 })

  epoch = os.time({ year = 2026, month = 2, day = 1, hour = 12 })
  stat._test_record_commit("好", env, { input = "b", hit_count = 1 })
  local stats = stat._test_state().stats
  assert_equal(stats.daily.chars, 1, "day rollover")
  assert_equal(stats.weekly.chars, 2, "same Monday-based week")
  assert_equal(stats.monthly.chars, 1, "month rollover")
  assert_equal(stats.yearly.chars, 2, "year remains unchanged")
  assert_equal(stats.total.chars, 2, "total survives day rollover")

  epoch = os.time({ year = 2026, month = 2, day = 2, hour = 12 })
  stat._test_record_commit("吗", env, { input = "c", hit_count = 1 })
  assert_equal(stats.weekly.chars, 1, "Monday week rollover")

  epoch = os.time({ year = 2027, month = 1, day = 1, hour = 12 })
  stat._test_record_commit("呢", env, { input = "d", hit_count = 1 })
  assert_equal(stats.yearly.chars, 1, "year rollover")
  assert_equal(stats.total.chars, 4, "total survives year rollover")
end

test_pure_chinese_commits_use_type_sunny_word_rate()
test_real_key_events_are_committed_only_after_valid_chinese_output()
test_return_and_digit_commits_are_neither_space_nor_auto_commit()
test_space_without_active_composition_does_not_leak_to_next_commit()
test_backspace_without_active_composition_does_not_leak_to_next_commit()
test_non_encoding_keys_after_composition_is_erased_do_not_leak()
test_enabled_state_is_cached_between_key_events()
test_invalid_commits_discard_keys_and_auto_commit_is_distinct()
test_session_cutoff_minimum_and_peak_window()
test_period_report_settles_active_segment_and_updates_peak()
test_peak_accumulates_completed_segments_to_ten_seconds()
test_session_is_split_before_date_rollover()
test_weekly_peak_can_span_days_in_the_same_week()
test_peak_tail_survives_statistics_reload()
test_failed_save_replace_preserves_previous_file_and_dirty_state()
test_failed_save_write_preserves_previous_file_and_dirty_state()
test_backup_is_recovered_after_save_rollback_failure()
test_compact_and_detailed_reports_use_requested_terms()
test_mixed_legacy_totals_do_not_dilute_new_efficiency_metrics()
test_legacy_schema_file_does_not_invent_speed_cohort()
test_shared_file_and_legacy_data_normalization()
test_day_week_month_and_year_rollovers()
print("input_speed_stat tests passed")
