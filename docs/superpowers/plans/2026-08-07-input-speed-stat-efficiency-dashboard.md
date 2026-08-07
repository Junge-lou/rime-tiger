# Input Statistics Efficiency Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing Rime input statistics module with pure-Chinese filtering, real keystroke metrics, TypeSunny-compatible word rate, code length, correction and commit-mode metrics, weekly aggregation, peak windows, and compact/detailed dashboards.

**Architecture:** Keep `lua/input_speed_stat.lua` as the single runtime component. The processor accumulates provisional physical-key metrics, the update notifier tracks the final composition, and the commit notifier atomically accepts or discards all provisional data after validating pure-Chinese output. Persist normalized period aggregates in the existing shared data file so `tiger` and `tigress` remain combined.

**Tech Stack:** Rime Lua API, Lua 5.5-compatible tests, repository shell test runner.

---

### Task 1: Define Period Data and Pure-Chinese Accounting

**Files:**
- Create: `tests/input_speed_stat_test.lua`
- Modify: `lua/input_speed_stat.lua`

- [ ] **Step 1: Write failing tests for period defaults and pure-Chinese filtering**

Create a Lua test harness that supplies `rime_api.get_time_ms`, a temporary user-data directory, an enabled fake Rime context, and assertions. Test these commits through explicit test hooks:

```lua
stat._test_reset({ now_ms = function() return clock_ms end, os_time = function() return epoch end })
stat._test_record_commit("你", { input = "ab", hit_count = 2, manual = true })
stat._test_record_commit("好吗", { input = "cde", hit_count = 3, auto = true })
stat._test_record_commit("abc", { input = "abc", hit_count = 3, manual = true })
stat._test_record_commit("你好!", { input = "abcd", hit_count = 4, manual = true })

local daily = stat._test_state().stats.daily
assert_equal(daily.commits, 2, "only pure Chinese commits count")
assert_equal(daily.chars, 3, "pure Chinese character count")
assert_equal(daily.word_chars, 2, "word characters")
assert_close(stat._test_metrics(daily).word_rate, 2 / 3 * 100, 0.001, "TypeSunny word rate")
```

Also assert `lengths[1] == 1`, `lengths[2] == 1`, `single_commit_count == 1`, and `word_commit_count == 1`.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `lua tests/input_speed_stat_test.lua`

Expected: failure because `_test_record_commit`, `_test_state`, `_test_metrics`, and the new period fields do not exist.

- [ ] **Step 3: Implement normalized periods and Chinese validation**

Replace `new_period()` with the complete aggregate and add normalization that preserves legacy `chars` and `seconds`:

```lua
local function new_period()
  return {
    commits = 0, chars = 0, seconds = 0,
    hit_count = 0, final_code_length = 0, backspace_count = 0,
    manual_commit_count = 0, auto_commit_count = 0,
    word_chars = 0, single_commit_count = 0, word_commit_count = 0,
    lengths = {}, code_lengths = {},
    peak = { speed = 0, hit = 0, code_length = 0 },
  }
end
```

Add `is_all_chinese(text)`, `normalize_period(value)`, `period_metrics(period)`, and a single `record_valid_commit(text, metrics, env, input_start_ms)` path. Every commit updates daily, weekly, monthly, yearly, and total. Invalid commits clear provisional state and update nothing.

- [ ] **Step 4: Expose narrow test hooks and verify GREEN**

Expose only deterministic helpers needed by the test:

```lua
function M._test_record_commit(text, metrics)
  return record_commit(text, state.env, metrics and metrics.input_start_ms, metrics)
end

function M._test_state()
  return state
end

function M._test_metrics(period)
  return period_metrics(period)
end
```

Run: `lua tests/input_speed_stat_test.lua`

Expected: `input_speed_stat tests passed`.

### Task 2: Capture Real Keys and Commit Modes

**Files:**
- Modify: `tests/input_speed_stat_test.lua`
- Modify: `lua/input_speed_stat.lua`

- [ ] **Step 1: Write failing tests for key, correction, code length, and commit mode accounting**

Add cases that stage `a`, `b`, BackSpace, `c`, then Space before committing `你` with final input `ac`. Assert:

```lua
assert_equal(daily.hit_count, 3, "all typed code keys count")
assert_equal(daily.backspace_count, 1, "real backspace count")
assert_equal(daily.final_code_length, 2, "final code excludes commit key")
assert_equal(daily.manual_commit_count, 1, "space commit")
assert_equal(daily.auto_commit_count, 0, "not auto commit")
assert_equal(daily.code_lengths[2], 1, "two-code distribution")
```

Add an auto-commit case without Space/Return/digit and an invalid mixed commit after staged keys. Assert invalid staged metrics do not leak into the next valid commit.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `lua tests/input_speed_stat_test.lua`

Expected: failure because ordinary processor events are not staged.

- [ ] **Step 3: Add provisional key state and key classification**

Add state fields `pending_hit_count`, `pending_backspace_count`, `pending_manual_commit`, and `pending_input`. Count printable speller code keydowns while statistics are enabled and the command namespace is not active. Count BackSpace separately. Mark Space, Return, and digit selection keys as manual commit keys without adding them to code length.

Keep existing `\tj` processor behavior first; ordinary input accounting must always return `kNoop` so Rime continues processing the key.

Use `update_notifier` as the authoritative final code snapshot. Clear the provisional metrics after every commit, invalid commit, disable, and module finalization.

- [ ] **Step 4: Verify focused key tests GREEN**

Run: `lua tests/input_speed_stat_test.lua`

Expected: all staged-key, auto/manual, invalid-discard, and code-length assertions pass.

### Task 3: Add Weekly Rollovers, Sessions, and Peak Windows

**Files:**
- Modify: `tests/input_speed_stat_test.lua`
- Modify: `lua/input_speed_stat.lua`

- [ ] **Step 1: Write failing date and timing tests**

Use injected millisecond and epoch clocks. Verify:

```lua
-- 5-second gaps split sessions.
-- Sessions shorter than 1 second do not add period seconds.
-- A sequence spanning at least 10 seconds can set peak.speed, peak.hit, and peak.code_length.
-- Monday-based week changes reset weekly but not monthly/yearly/total.
-- Day, month, and year changes reset their respective periods.
```

Construct commits at deterministic timestamps with deterministic hit and final-code totals, then assert exact or tolerance-based period metrics.

- [ ] **Step 2: Run timing tests and verify RED**

Run: `lua tests/input_speed_stat_test.lua`

Expected: failure because weekly periods, the 5000ms cutoff, 1000ms minimum, and 10000ms peak samples are absent.

- [ ] **Step 3: Implement period boundaries and rolling peak samples**

Add a Monday-based `week_key(date)` and reset daily/weekly/monthly/yearly independently. Change `SESSION_TIMEOUT_MS` to `5000` and add `MIN_SESSION_MS = 1000` and `PEAK_WINDOW_MS = 10000`.

Maintain in-memory commit samples containing timestamp, chars, hits, and final code length. Trim samples outside the rolling range; once covered duration reaches 10000ms, calculate:

```lua
speed = chars / seconds * 60
hit = hits / seconds
code_length = final_code_length / chars
```

Update each active period peak only when speed increases. Persist peak values, not raw rolling samples.

- [ ] **Step 4: Run timing tests and verify GREEN**

Run: `lua tests/input_speed_stat_test.lua`

Expected: timing, rollover, and peak assertions pass.

### Task 4: Migrate Existing Data Safely

**Files:**
- Modify: `tests/input_speed_stat_test.lua`
- Modify: `lua/input_speed_stat.lua`

- [ ] **Step 1: Write failing migration and shared-file tests**

Write a legacy file containing only `chars`, `seconds`, `last_update`, and `previous_session`. Initialize once as schema `tiger` and again as `tigress`. Assert the same `input_speed_stat_data.lua` path is used, old counts remain, new fields are zero, and weekly starts empty.

Add malformed negative/non-number fields and assert they normalize to finite non-negative values.

- [ ] **Step 2: Run migration tests and verify RED**

Run: `lua tests/input_speed_stat_test.lua`

Expected: failure on missing weekly and malformed values.

- [ ] **Step 3: Normalize loaded and migrated data**

Route current and legacy period tables through `normalize_period`. Merge legacy periods with `add_period`, including only fields known to exist. Preserve the one shared current path and existing legacy-file discovery. Normalize `previous_session` and `last_update` defensively.

- [ ] **Step 4: Verify migration tests GREEN**

Run: `lua tests/input_speed_stat_test.lua`

Expected: all migration and shared-file assertions pass.

### Task 5: Build Compact and Detailed Reports

**Files:**
- Modify: `tests/input_speed_stat_test.lua`
- Modify: `lua/input_speed_stat.lua`

- [ ] **Step 1: Write failing report-format tests**

Seed a deterministic period and assert the compact report contains these exact labels and excludes rejected terminology:

```lua
assert_contains(brief, "上屏 95 次")
assert_contains(brief, "输入 133 字")
assert_contains(brief, "击键 3.24")
assert_contains(brief, "码长 2.56")
assert_contains(brief, "打词率 55.6%")
assert_contains(brief, "空格 88% · 顶屏 12%")
assert_contains(brief, "回改 7 次 · 回改率 2.1%")
assert_not_contains(brief, "键/秒")
assert_not_contains(brief, "平均编码")
assert_not_contains(brief, "词组连打")
```

Assert detailed output has fixed 1/2/3/4/+ word rows, 1/2/3/4/other code rows, ten-cell bars, and four period candidates ordered today/week/month/year.

- [ ] **Step 2: Run report tests and verify RED**

Run: `lua tests/input_speed_stat_test.lua`

Expected: failure because current summaries only report characters, average speed, and duration.

- [ ] **Step 3: Implement format helpers and dashboard candidates**

Add safe percentage, one/two-decimal number, and ten-cell progress-bar helpers. Keep `\tjs` unchanged. Make `\tjj` emit the compact five-line summary and `\tjx` emit four multiline dashboard candidates for daily, weekly, monthly, and yearly periods.

Use current Rime distribution metadata only at the dashboard footer. Do not label the shared aggregate as one schema.

- [ ] **Step 4: Run report tests and verify GREEN**

Run: `lua tests/input_speed_stat_test.lua`

Expected: all compact and detailed report assertions pass.

### Task 6: Full Verification

**Files:**
- Verify: `lua/input_speed_stat.lua`
- Verify: `tests/input_speed_stat_test.lua`

- [ ] **Step 1: Run syntax and focused tests**

Run:

```bash
luac -p lua/input_speed_stat.lua
lua tests/input_speed_stat_test.lua
```

Expected: syntax succeeds and focused tests print `input_speed_stat tests passed`.

- [ ] **Step 2: Run the repository suite**

Run: `bash scripts/run_tests.sh`

Expected: all Python, Lua, and JavaScript tests pass.

- [ ] **Step 3: Inspect the final diff**

Run:

```bash
git diff --check
git diff -- lua/input_speed_stat.lua tests/input_speed_stat_test.lua
git status --short
```

Expected: no whitespace errors; only the statistics implementation and its new test belong to this feature, while pre-existing unrelated modified files remain untouched.
