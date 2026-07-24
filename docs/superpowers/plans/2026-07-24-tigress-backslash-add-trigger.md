# Tigress Backslash Add Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `target-code + \\ + Space` as a conflict-free Tigress add-word entry method while retaining `Ctrl+;` and all leading-backslash commands.

**Architecture:** A small pure Lua module validates and extracts the two-backslash suffix. `tigress_user_words` runs before generic symbol processors, appends eligible backslashes directly to `context.input`, and routes Space into the existing capture flow with the extracted code. Static and behavior tests cover parsing, processor routing, ordering, documentation, and legacy shortcuts.

**Tech Stack:** Lua 5.5, Rime Lua processor/filter APIs, YAML schema configuration, repository Lua test scripts.

---

### Task 1: Add the trigger parser with failing tests

**Files:**
- Create: `lua/tigress_add_trigger.lua`
- Create: `tests/tigress_user_words_test.lua`

- [ ] **Step 1: Write the failing parser tests**

Create `tests/tigress_user_words_test.lua` with a package path pointing at `lua/`, then require `tigress_add_trigger` and assert:

```lua
package.path = "./lua/?.lua;" .. package.path

local trigger = require("tigress_add_trigger")

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
```

- [ ] **Step 2: Run the parser test and verify RED**

Run: `lua tests/tigress_user_words_test.lua`

Expected: FAIL because module `tigress_add_trigger` does not exist.

- [ ] **Step 3: Implement the pure parser**

Create `lua/tigress_add_trigger.lua`:

```lua
local M = {}

local BACKSLASH = "\\"
local SUFFIX = "\\\\"

local function is_normal_code(code)
  return type(code) == "string" and code:match("^[a-z;']+$") ~= nil
end

function M.can_append(input)
  if is_normal_code(input) then
    return true
  end
  return type(input) == "string"
    and input:sub(-1) == BACKSLASH
    and is_normal_code(input:sub(1, -2))
end

function M.target_code(input)
  if type(input) ~= "string" or input:sub(-#SUFFIX) ~= SUFFIX then
    return nil
  end
  local code = input:sub(1, -#SUFFIX - 1)
  return is_normal_code(code) and code or nil
end

return M
```

- [ ] **Step 4: Run the parser test and verify GREEN**

Run: `lua tests/tigress_user_words_test.lua`

Expected: PASS with exit code 0.

- [ ] **Step 5: Commit the parser and tests**

```bash
git add -f lua/tigress_add_trigger.lua tests/tigress_user_words_test.lua
git commit -m "test: define tigress backslash add trigger"
```

### Task 2: Route the fallback through the existing capture flow

**Files:**
- Modify: `lua/tigress_user_words.lua:41-57`
- Modify: `lua/tigress_user_words.lua:569-583`
- Modify: `lua/tigress_user_words.lua:832-873`
- Modify: `lua/tigress_user_words.lua:881-902`
- Modify: `tests/tigress_user_words_test.lua`

- [ ] **Step 1: Add failing processor behavior tests**

Extend `tests/tigress_user_words_test.lua` with a minimal Rime context, composition, segment, engine, and key-event fixture. Load `tigress_user_words`, call `processor.func`, and assert:

```lua
local user_words = require("tigress_user_words")
local env = new_env("abcd")

assert(user_words.processor.func(key(0x5c), env) == 1)
assert(env.engine.context.input == "abcd\\")
assert(user_words.processor.func(key(0x5c), env) == 1)
assert(env.engine.context.input == "abcd\\\\")
assert(user_words.processor.func(key(0x20), env) == 1)
assert(env.capture.code == "abcd")
assert(env.capture.operation == "add")

local command_env = new_env("\\djs")
assert(user_words.processor.func(key(0x5c), command_env) == 2)

local ctrl_env = new_env("abcd")
assert(user_words.processor.func(key(0x3b, { ctrl = true }), ctrl_env) == 1)
assert(ctrl_env.capture.code == "abcd")
```

The fixture's `context:push_input` appends text, `context:clear` resets input, and composition methods return a stable mock segment. Key methods return the requested modifier flags.

- [ ] **Step 2: Run the behavior test and verify RED**

Run: `lua tests/tigress_user_words_test.lua`

Expected: FAIL because plain backslash is currently a no-op in `tigress_user_words`.

- [ ] **Step 3: Implement processor routing**

In `lua/tigress_user_words.lua`:

```lua
local add_trigger = require("tigress_add_trigger")
```

Add `BACKSLASH = 0x5c` to `KEY`. Extend `enter_capture` with an optional explicit code:

```lua
local function enter_capture(env, operation, default_text, explicit_code)
    local code = explicit_code or current_code(env)
```

Before the existing Ctrl shortcut branch, handle plain backslash and Space:

```lua
local plain_key = not key_event:ctrl() and not key_event:alt()
    and not key_event:shift() and not key_event:release()
local input = env.engine.context.input or ""

if plain_key and keycode == KEY.BACKSLASH and add_trigger.can_append(input) then
    env.engine.context:push_input("\\")
    refresh_context(env.engine.context)
    return kAccepted
end

local trigger_code = plain_key and keycode == KEY.SPACE and add_trigger.target_code(input) or nil
if trigger_code then
    return enter_capture(env, "add", nil, trigger_code) and kAccepted or kNoop
end
```

Before normal candidate filtering, yield a `tigress_user_status` candidate when `add_trigger.target_code(context.input)` succeeds. Its text is `加词 <code>` and its comment is `空格进入加词`.

- [ ] **Step 4: Run behavior tests and verify GREEN**

Run: `lua tests/tigress_user_words_test.lua`

Expected: PASS.

- [ ] **Step 5: Run Lua syntax checks**

Run:

```bash
luac -p lua/tigress_add_trigger.lua
luac -p lua/tigress_user_words.lua
```

Expected: both commands exit 0 with no output.

- [ ] **Step 6: Commit processor behavior**

```bash
git add lua/tigress_add_trigger.lua lua/tigress_user_words.lua
git add -f tests/tigress_user_words_test.lua
git commit -m "feat: add tigress backslash word capture trigger"
```

### Task 3: Put the processor before generic symbol handling

**Files:**
- Modify: `tigress.schema.yaml:33-45`
- Modify: `tests/config_static_test.lua`

- [ ] **Step 1: Add a failing processor-order test**

Extend `test_tigress_filter_order` or add `test_tigress_processor_order` in `tests/config_static_test.lua`:

```lua
assert_order(text, "lua_processor@*tigress_user_words*processor", "lua_processor@*space_proc3", "user words run before empty-code punctuation")
assert_order(text, "lua_processor@*tigress_user_words*processor", "lua_processor@*symbol_proc", "user words run before symbol commit")
```

Also assert the Lua source still contains `keycode == KEY.SEMICOLON` to retain `Ctrl+;`.

- [ ] **Step 2: Run the static test and verify RED**

Run: `lua tests/config_static_test.lua`

Expected: FAIL because `tigress_user_words` currently appears after both generic processors.

- [ ] **Step 3: Reorder the Tigress processor**

In `tigress.schema.yaml`, move:

```yaml
- lua_processor@*tigress_user_words*processor
```

to immediately before `lua_processor@*space_proc3`, leaving all other processor order unchanged.

- [ ] **Step 4: Run static and behavior tests**

Run:

```bash
lua tests/config_static_test.lua
lua tests/tigress_user_words_test.lua
```

Expected: both PASS.

- [ ] **Step 5: Commit schema ordering**

```bash
git add tigress.schema.yaml tests/config_static_test.lua
git commit -m "fix: prioritize tigress add trigger over punctuation"
```

### Task 4: Document both entry methods

**Files:**
- Modify: `README.md:48-65`
- Modify: `配置说明/配置说明.txt:140-155`
- Modify: `tests/config_static_test.lua`

- [ ] **Step 1: Add failing documentation assertions**

In `tests/config_static_test.lua`, assert both documents contain the literal user-facing trigger text:

```lua
assert_contains(read("README.md"), "目标编码 + `\\\\` + `Space`", "README documents fallback add trigger")
assert_contains(read("配置说明/配置说明.txt"), "目标编码 + \\\\ + Space", "configuration guide documents fallback add trigger")
```

- [ ] **Step 2: Run the static test and verify RED**

Run: `lua tests/config_static_test.lua`

Expected: FAIL because the fallback is not documented.

- [ ] **Step 3: Update user documentation**

Add the fallback next to `Ctrl+;` in both documents. State that it is only recognized after a normal target code and does not affect leading-backslash commands.

- [ ] **Step 4: Run the repository verification suite**

Run:

```bash
lua tests/tigress_user_words_test.lua
lua tests/config_static_test.lua
lua tests/core2022_filter_test.lua
lua tests/option_sync_test.lua
lua tests/rime_skin_editor_test.lua
node --test tests/preview_model_test.js tests/skin_editor_core_test.js tests/skin_editor_integration_test.js tests/windows_launcher_test.js
git diff --check
```

Expected: all Lua scripts print their pass messages, Node reports zero failures, and `git diff --check` exits 0.

- [ ] **Step 5: Commit documentation and final tests**

```bash
git add README.md 配置说明/配置说明.txt tests/config_static_test.lua
git commit -m "docs: explain tigress backslash add trigger"
```
