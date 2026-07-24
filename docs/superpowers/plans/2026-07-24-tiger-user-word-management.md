# Tiger User Word Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable complete, independently persisted add/disable/reorder behavior in both `tiger` and `tigress`, including the new `target-code + \\ + Space` add trigger.

**Architecture:** Move the existing Tigress implementation into a shared Tiger-family module with built-in profiles selected by `schema_id` and a state cache keyed by profile. Put the shared components in `tiger_base.schema.yaml`, keep the old module name as a compatibility wrapper, and isolate backslash parsing in a pure helper.

**Tech Stack:** Lua 5.5, Rime Lua APIs, Rime YAML schemas, Lua and Node repository tests.

---

### Task 1: Backslash Trigger Parser

**Files:**
- Create: `lua/tiger_add_trigger.lua`
- Create: `tests/tiger_user_words_test.lua`

- [ ] **Step 1: Write failing parser tests**

Create a Lua test that requires `tiger_add_trigger` and asserts `can_append` accepts `abcd` and `abcd\`, rejects empty/leading-backslash/completed suffix inputs, and `target_code` converts `abcd\\` to `abcd` while rejecting malformed and embedded-backslash inputs.

```lua
package.path = "./lua/?.lua;" .. package.path
local trigger = require("tiger_add_trigger")

assert(trigger.can_append("abcd"))
assert(trigger.can_append("abcd\\"))
assert(not trigger.can_append(""))
assert(not trigger.can_append("\\djs"))
assert(not trigger.can_append("abcd\\\\"))
assert(trigger.target_code("abcd\\\\") == "abcd")
assert(trigger.target_code("abcd\\") == nil)
assert(trigger.target_code("\\djs\\\\") == nil)
assert(trigger.target_code("ab\\cd\\\\") == nil)
```

- [ ] **Step 2: Verify RED**

Run: `lua tests/tiger_user_words_test.lua`

Expected: module-not-found failure for `tiger_add_trigger`.

- [ ] **Step 3: Implement the pure parser**

Create a module with literal `BACKSLASH = "\\"`, `SUFFIX = "\\\\"`, a normal-code predicate `^[a-z;']+$`, `can_append(input)`, and `target_code(input)`. Use plain string slicing, not regex matching for the suffix.

- [ ] **Step 4: Verify GREEN and syntax**

Run:

```bash
lua tests/tiger_user_words_test.lua
luac -p lua/tiger_add_trigger.lua
```

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/tiger_add_trigger.lua
git add -f tests/tiger_user_words_test.lua
git commit -m "test: define tiger add trigger syntax"
```

### Task 2: Shared Schema Profiles and State Isolation

**Files:**
- Create: `lua/tiger_user_words.lua`
- Modify: `lua/tigress_user_words.lua`
- Modify: `tests/tiger_user_words_test.lua`

- [ ] **Step 1: Add failing profile and compatibility tests**

Mock `rime_api.get_user_data_dir`, `log.error`, schema objects, context notifiers, and temporary user-data storage. Assert:

```lua
local words = require("tiger_user_words")
local tiger_env = new_init_env("tiger")
local tigress_env = new_init_env("tigress")
words.processor.init(tiger_env)
words.processor.init(tigress_env)

assert(tiger_env.state.config.extended_dict == "tiger.user.dict.yaml")
assert(tigress_env.state.config.extended_dict == "tigress.user.dict.yaml")
assert(tiger_env.state ~= tigress_env.state)
assert(require("tigress_user_words") == words)

local unknown_env = new_init_env("unknown")
words.processor.init(unknown_env)
assert(unknown_env.state == nil)
```

Also assert that initializing a second `tiger` environment reuses Tiger state but never Tigress state.

- [ ] **Step 2: Verify RED**

Run: `lua tests/tiger_user_words_test.lua`

Expected: module-not-found failure for `tiger_user_words`.

- [ ] **Step 3: Create the shared implementation**

Copy the existing behavior into `lua/tiger_user_words.lua`, then replace the single global config with fixed `PROFILES.tiger` and `PROFILES.tigress` tables. Each profile defines dictionary name, user dictionary path, legacy migration sources, source dictionaries, and weight constants.

Use `env.engine.schema.schema_id` to select a profile. Replace `shared_state` with `shared_states[schema_id]`. Store the selected profile on `state.config`, pass it through dictionary parsing/persistence helpers, and make processor/filter initialization a logged no-op for unknown schemas.

Generate missing user dictionary headers from the selected profile instead of hard-coded Tigress names. Preserve the existing marker strings so old Tigress records remain readable.

- [ ] **Step 4: Replace the old module with a compatibility wrapper**

`lua/tigress_user_words.lua` becomes:

```lua
return require("tiger_user_words")
```

- [ ] **Step 5: Verify GREEN and syntax**

Run:

```bash
lua tests/tiger_user_words_test.lua
luac -p lua/tiger_user_words.lua
luac -p lua/tigress_user_words.lua
```

Expected: exit 0, with separate temporary Tiger and Tigress user dictionary files created by the test.

- [ ] **Step 6: Commit**

```bash
git add lua/tiger_user_words.lua lua/tigress_user_words.lua
git add -f tests/tiger_user_words_test.lua
git commit -m "refactor: share user word management across tiger schemas"
```

### Task 3: Complete Shortcut Behavior in Both Profiles

**Files:**
- Modify: `lua/tiger_user_words.lua`
- Modify: `tests/tiger_user_words_test.lua`

- [ ] **Step 1: Add failing processor tests**

Build a mock composition/menu/candidate/key-event fixture and run the same assertions for `tiger` and `tigress`:

```lua
assert(words.processor.func(plain_key(0x5c), env) == 1)
assert(context.input == "abcd\\")
assert(words.processor.func(plain_key(0x5c), env) == 1)
assert(context.input == "abcd\\\\")
assert(words.processor.func(plain_key(0x20), env) == 1)
assert(env.capture.code == "abcd")
assert(env.capture.operation == "add")
```

Add cases proving leading `\djs` passes through, `Ctrl+;` enters add capture, `Ctrl+'` enters disable capture with selected text, and Ctrl-arrow reaches reorder handling in each profile.

- [ ] **Step 2: Verify RED**

Run: `lua tests/tiger_user_words_test.lua`

Expected: failure because the plain backslash flow is not implemented.

- [ ] **Step 3: Implement fallback routing and status**

Require `tiger_add_trigger`, add `KEY.BACKSLASH`, and allow `enter_capture` to accept an explicit target code. Before Ctrl shortcut handling, append eligible plain backslashes with `context:push_input("\\")`; on plain Space with a complete suffix, enter add capture using the extracted code.

In the filter, yield a neutral status candidate with comment `空格进入加词` when a complete suffix is present. Rename Tigress-specific candidate types and log prefixes to Tiger-family names without changing persistence markers.

- [ ] **Step 4: Verify GREEN and syntax**

Run:

```bash
lua tests/tiger_user_words_test.lua
luac -p lua/tiger_user_words.lua
```

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/tiger_user_words.lua tests/tiger_user_words_test.lua
git commit -m "feat: support complete user word shortcuts in tiger schemas"
```

### Task 4: Shared Base Schema Integration

**Files:**
- Modify: `tiger_base.schema.yaml`
- Modify: `tigress.schema.yaml`
- Modify: `配置说明/示例.schema.yaml`
- Modify: `tests/config_static_test.lua`

- [ ] **Step 1: Add failing schema tests**

Assert the base schema contains `tiger_user_words` processor before `space_proc3` and `symbol_proc`, and its filter before `core2022_filter`. Assert `tigress.schema.yaml` no longer contains a separate `engine` override or the old component name. Assert the example schema documents the same common placement without a single-schema warning.

- [ ] **Step 2: Verify RED**

Run: `lua tests/config_static_test.lua`

Expected: processor/filter ordering failure.

- [ ] **Step 3: Integrate through the base schema**

Insert:

```yaml
- lua_processor@*tiger_user_words*processor
```

before `space_proc3`, and:

```yaml
- lua_filter@*tiger_user_words*filter
```

before `core2022_filter`. Remove the now-redundant `engine` block from `tigress.schema.yaml`. Update the example schema placement and comments.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
lua tests/config_static_test.lua
lua tests/tiger_user_words_test.lua
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add tiger_base.schema.yaml tigress.schema.yaml 配置说明/示例.schema.yaml tests/config_static_test.lua
git commit -m "feat: enable user word management in both tiger schemas"
```

### Task 5: Documentation and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `配置说明/配置说明.txt`
- Modify: `配置说明/示例.custom.yaml`
- Modify: `tests/config_static_test.lua`

- [ ] **Step 1: Add failing documentation tests**

Assert README and configuration guide name both `tiger.user.dict.yaml` and `tigress.user.dict.yaml`, list `Ctrl+;` and `编码 + \\ + Space`, and do not contain the old "不要把加词 Lua 加到 tiger" instruction. Assert example comments no longer describe the feature as Tigress-only.

- [ ] **Step 2: Verify RED**

Run: `lua tests/config_static_test.lua`

Expected: documentation assertion failure.

- [ ] **Step 3: Update all documentation**

Describe full add/disable/reorder support in both schemas, the two add entry methods, separate persistence, and preservation of leading-backslash commands. Remove all single-schema restrictions from README, configuration guide, and examples.

- [ ] **Step 4: Run full verification**

Run:

```bash
lua tests/tiger_user_words_test.lua
lua tests/config_static_test.lua
lua tests/core2022_filter_test.lua
lua tests/option_sync_test.lua
lua tests/rime_skin_editor_test.lua
node --test tests/preview_model_test.js tests/skin_editor_core_test.js tests/skin_editor_integration_test.js tests/windows_launcher_test.js
luac -p lua/tiger_add_trigger.lua
luac -p lua/tiger_user_words.lua
luac -p lua/tigress_user_words.lua
git diff --check
```

Expected: all Lua scripts pass, Node reports zero failures, syntax checks produce no output, and `git diff --check` exits 0.

- [ ] **Step 5: Commit**

```bash
git add README.md 配置说明/配置说明.txt 配置说明/示例.custom.yaml tests/config_static_test.lua
git commit -m "docs: document user word management for both tiger schemas"
```
