# Smart Candidate Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Tiger's `;` and `'` choice keys skip emoji/symbol associations, with a documented static setting that restores positional selection.

**Architecture:** Extend the existing `lua/symbol_proc.lua` processor because it already runs before `key_binder` and owns unique-candidate punctuation behavior. The processor reads `smart_candidate_selection/enabled` once during initialization, classifies candidates by their first Unicode codepoint using Moran's text-candidate rule, and, when selection is still on the first ordinary page, incrementally scans the candidate stream for the requested text candidate. Existing key bindings remain as the compatibility fallback.

**Tech Stack:** Rime YAML schema/custom patches, librime-lua processor API, Lua 5.5 unit tests, shell test runner.

---

## File Map

- Create `tests/symbol_proc_test.lua`: mocked Rime processor tests for candidate classification, selection, pass-through, and configuration.
- Modify `lua/symbol_proc.lua`: configuration initialization and smart second/third text-candidate selection.
- Modify `tiger_base.schema.yaml`: enabled-by-default shared setting with a Chinese inline comment.
- Modify `tiger_base.custom.yaml`: commented disable override with a Chinese inline comment.
- Modify `配置说明/示例.custom.yaml`: copyable setting example with a Chinese inline comment.
- Modify `配置说明/配置说明.txt`: behavior, disable syntax, redeploy requirement, and explicit symbol-menu compatibility.
- Modify `tests/config_static_test.lua`: static contract tests for configuration and documentation.

### Task 1: Smart selection processor

**Files:**
- Create: `tests/symbol_proc_test.lua`
- Modify: `lua/symbol_proc.lua`

- [ ] **Step 1: Write the failing processor tests**

Create a Lua harness that requires the real module and supplies mocked key events, menus, composition, context, and schema config. The tests must assert these concrete cases:

```lua
local cases = {
  { key = "semicolon", candidates = { "甲", "😀", "乙" }, selected = 2 },
  { key = "apostrophe", candidates = { "甲", "😀", "乙", "✓", "丙" }, selected = 4 },
  { key = "semicolon", candidates = { "甲", "1️⃣", "乙" }, types = { "table", "simplified", "table" }, selected = 2 },
  { key = "semicolon", candidates = { "甲", "2", "乙" }, types = { "table", "table", "table" }, selected = 1 },
}
```

Also assert that an association-only remainder commits the first candidate and returns `kNoop`, while disabled mode, inputs beginning with `\\` or `;`, shifted choice keys, and later pages do not directly select a candidate.

- [ ] **Step 2: Run the processor test and verify RED**

Run:

```bash
lua tests/symbol_proc_test.lua
```

Expected: FAIL because `symbol_proc.init` and smart text-candidate selection do not exist.

- [ ] **Step 3: Implement configuration and candidate classification**

Add initialization that defaults to enabled unless the config returns the explicit boolean `false`:

```lua
local function configured_enabled(env)
  local config = env and env.engine and env.engine.schema and env.engine.schema.config
  if not config or not config.get_bool then
    return true
  end
  local ok, value = pcall(function()
    return config:get_bool("smart_candidate_selection/enabled")
  end)
  return not ok or type(value) ~= "boolean" or value
end

function symbol_proc.init(env)
  env.smart_candidate_selection_enabled = configured_enabled(env)
end
```

Add a focused `is_text_candidate(cand)` helper. It accepts CJK Unified Ideographs and extensions A-J, ASCII letters, and non-`simplified` ASCII digits. Empty text, emoji, punctuation, and simplified keycap digits are rejected.

- [ ] **Step 4: Implement smart key selection**

For unmodified `semicolon` and `apostrophe` events on the first page of ordinary input:

```lua
local rank = repr == "semicolon" and 2 or repr == "apostrophe" and 3 or nil
```

Prepare the configured page size, count only text candidates from page index zero, and call `context:select(index)` when `rank` is reached. If needed, prepare 32 additional candidates at a time and inspect only the newly prepared range, stopping after 512 candidates. If the bounded stream has at least one text candidate but not the requested rank, select the first text candidate, call `context:confirm_current_selection()`, and return `kNoop` so punctuation continues through Rime. Inputs beginning with `\\` or `;`, shifted/modified events, and pages after the first bypass smart handling and retain the existing code path.

- [ ] **Step 5: Run the processor tests and verify GREEN**

Run:

```bash
lua tests/symbol_proc_test.lua
luac -p lua/symbol_proc.lua tests/symbol_proc_test.lua
```

Expected: both commands exit 0 and the test prints `symbol_proc tests passed`.

### Task 2: Static configuration contract

**Files:**
- Modify: `tests/config_static_test.lua`
- Modify: `tiger_base.schema.yaml`
- Modify: `tiger_base.custom.yaml`
- Modify: `配置说明/示例.custom.yaml`

- [ ] **Step 1: Add failing static configuration assertions**

Add `test_smart_candidate_selection_configuration()` asserting:

```lua
assert_contains(base, "smart_candidate_selection:", "base defines smart candidate selection")
assert_contains(base, "enabled: true", "smart selection defaults to enabled")
assert_contains(base, "次选键跳过", "base setting has a Chinese behavior comment")
assert_contains(custom, "smart_candidate_selection/enabled: false", "base custom exposes the disable override")
assert_contains(custom, "恢复按候选位置选重", "disable override has a Chinese comment")
assert_contains(example, "smart_candidate_selection/enabled: true", "custom example documents the setting")
```

Register the function in the test list.

- [ ] **Step 2: Run the static test and verify RED**

Run:

```bash
lua tests/config_static_test.lua
```

Expected: FAIL because the setting is absent from the schema and custom files.

- [ ] **Step 3: Add the commented configuration**

Add to the shared schema:

```yaml
smart_candidate_selection:
  enabled: true # 次选键跳过 emoji 和符号联想；false 恢复按候选位置选重
```

Add a commented user override near the other common behavior settings:

```yaml
  #smart_candidate_selection/enabled: false # 关闭智能次选，恢复按候选位置选重：; 选第 2 项，' 选第 3 项
```

Add the copyable example:

```yaml
  smart_candidate_selection/enabled: true # true 跳过 emoji/符号联想；false 恢复按第 2、3 项选重
```

- [ ] **Step 4: Run static and processor tests**

Run:

```bash
lua tests/config_static_test.lua
lua tests/symbol_proc_test.lua
```

Expected: both pass.

### Task 3: User documentation

**Files:**
- Modify: `tests/config_static_test.lua`
- Modify: `配置说明/配置说明.txt`

- [ ] **Step 1: Add failing documentation assertions**

Extend the static configuration test to require the guide to contain:

```lua
assert_contains(guide, "smart_candidate_selection/enabled: false", "guide documents how to disable smart selection")
assert_contains(guide, "反斜杠符号菜单", "guide preserves explicit symbol menus")
assert_contains(guide, "重新部署", "guide states how static changes take effect")
```

- [ ] **Step 2: Run the static test and verify RED**

Run `lua tests/config_static_test.lua`.

Expected: FAIL on the first missing guide statement.

- [ ] **Step 3: Document the setting**

Add a concise subsection to the configuration guide explaining:

```yaml
patch:
  smart_candidate_selection/enabled: false
```

State that the default `true` makes `;`/`'` skip emoji and symbol associations, `false` restores raw second/third position selection, explicit backslash symbol menus are unaffected, and changing the static setting requires Rime redeployment.

- [ ] **Step 4: Run the documentation contract test**

Run `lua tests/config_static_test.lua`.

Expected: PASS and print `config static tests passed`.

### Task 4: Full verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run syntax and whitespace checks**

```bash
luac -p lua/symbol_proc.lua tests/symbol_proc_test.lua tests/config_static_test.lua
git diff --check
```

Expected: both commands exit 0 without output.

- [ ] **Step 2: Run the complete repository suite**

```bash
./scripts/run_tests.sh
```

Expected: all Python, Lua, and Node tests pass with no failures.

- [ ] **Step 3: Review the scoped diff**

```bash
git diff -- lua/symbol_proc.lua tests/symbol_proc_test.lua tests/config_static_test.lua tiger_base.schema.yaml tiger_base.custom.yaml 配置说明/示例.custom.yaml 配置说明/配置说明.txt
```

Expected: only smart-selection behavior, its tests, the static setting, and documentation are changed. Do not stage or modify unrelated existing worktree changes.
