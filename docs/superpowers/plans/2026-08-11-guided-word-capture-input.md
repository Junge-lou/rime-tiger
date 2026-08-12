# Guided Word Capture Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Tiger capture Chinese candidates and lowercase literal English safely by following the normal Rime Chinese/English state.

**Architecture:** Add a pure Lua input-classification helper and keep persistence in `tiger_user_words.lua`. Move the user-word processor before `ascii_composer`, isolate captures by engine context token, implement normal bare-Shift behavior during capture, and restore entry-time `ascii_mode` on every exit.

**Tech Stack:** librime-lua, Lua 5.5 unit tests, Rime YAML schemas.

---

### Task 1: Pure Capture Input Classification

**Files:**
- Create: `lua/tiger_capture_input.lua`
- Create: `tests/tiger_capture_input_test.lua`

- [ ] **Step 1: Write the failing classification tests**

Create assertions for Chinese query/selection, English literals, shifted uppercase,
numeric-keypad input, unsupported printable consumption, and punctuation:

```lua
package.path = "./lua/?.lua;" .. package.path
local input = require("tiger_capture_input")

assert(input.classify(0x61, false, false, "12345", false) == "query")
assert(input.classify(0x20, false, true, "12345", false) == "select")
assert(input.classify(0x61, true, false, "12345", false) == "literal")
assert(input.classify(0x61, false, false, "12345", true) == "literal")
assert(input.keycode_to_char(0xffb4) == "4")
assert(input.classify(0x0101f600, false, true, "12345", false) == "consume")
assert(input.literal_char("", ",", false, false, false) == "，")
assert(input.literal_char("", ",", true, false, false) == ",")
```

- [ ] **Step 2: Run the test and verify RED**

Run: `lua tests/tiger_capture_input_test.lua`

Expected: failure because `tiger_capture_input` does not exist.

- [ ] **Step 3: Implement the pure helper**

Implement and export these concrete operations:

```lua
function M.keycode_to_char(keycode)
  -- Printable ASCII plus KP_0..KP_9, decimal, add, subtract, multiply,
  -- divide, separator, and equal.
end

function M.classify(keycode, ascii_mode, has_query, select_keys, shifted)
  -- Return query, select, literal, consume, or nil.
end

function M.selection_index(selected_index, keycode, page_size, select_keys)
  -- Resolve the configured selection key within the current page.
end

function M.literal_char(existing_text, char, ascii_mode, ascii_punct, full_shape)
  -- Preserve ASCII in English/ascii-punctuation mode and otherwise apply
  -- Tiger's Chinese half/full-shape punctuation mapping.
end
```

- [ ] **Step 4: Run the helper test and verify GREEN**

Run: `lua tests/tiger_capture_input_test.lua`

Expected: `tiger capture input tests passed`.

- [ ] **Step 5: Commit the helper**

```bash
git add lua/tiger_capture_input.lua tests/tiger_capture_input_test.lua
git commit -m "feat: add guided capture input classifier"
```

### Task 2: Engine-Isolated Capture Sessions

**Files:**
- Modify: `lua/tiger_user_words.lua:12-1106`
- Modify: `tests/tiger_user_words_test.lua:89-340`

- [ ] **Step 1: Write failing runtime tests**

Extend the context mock with properties and options, then assert the public
processor behavior:

```lua
function context:get_property(name) return self.properties[name] or "" end
function context:set_property(name, value) self.properties[name] = value end
function context:get_option(name) return self.options[name] or false end
function context:set_option(name, value) self.options[name] = value end

-- Captures in two engine contexts remain independent.
-- Bare Shift press/release toggles ascii_mode during capture.
-- Lowercase input in ascii_mode appends literal text.
-- Shift+letter appends uppercase and does not toggle ascii_mode.
-- Save/cancel restore the entry-time ascii_mode.
-- Unsupported printable input is accepted without changing text/query.
-- Empty saves and failed database writes preserve capture and set message.
```

- [ ] **Step 2: Run the runtime test and verify RED**

Run: `lua tests/tiger_user_words_test.lua`

Expected: an assertion failure on the first engine-isolation or lowercase
literal-input assertion.

- [ ] **Step 3: Replace shared capture state with engine sessions**

Use a context-property token so processor and filter environments for the same
engine resolve the same session:

```lua
local capture_sessions = {}
local capture_token_counter = 0
local CAPTURE_TOKEN_PROPERTY = "tiger_user_words_capture_token"

local function set_capture(engine, capture) end
local function get_capture(engine) end
local function clear_capture(engine) end
```

Create captures with `code`, `text`, `query`, `message`,
`original_ascii_mode`, `shift_key`, and `shift_used`. Restore
`original_ascii_mode` before clearing a saved, cancelled, or finalized
capture.

- [ ] **Step 4: Route capture keys through the helper**

Require `tiger_capture_input`, then implement the capture branch in this order:

```lua
if capture then
  -- Shift press/release: toggle only for a bare Shift gesture.
  -- Enter/KP_Enter, Escape, and Backspace: edit or finish capture.
  -- Shortcut modifiers and unsupported modifier keys: consume safely.
  -- Helper action select: append genuine candidate text.
  -- Helper action query: append the lowercase lookup code.
  -- Helper action literal: append converted literal text.
  -- Helper action consume: return kAccepted without mutation.
end
```

Keep `persist_weight`, `persist_disable`, migration, and reorder functions
unchanged. On empty saves set `capture.message = "请先选择或输入要加入的词"`.
On persistence failure set `capture.message = "保存失败，请重试"`.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
lua tests/tiger_capture_input_test.lua
lua tests/tiger_user_words_test.lua
```

Expected: both print their success messages and exit zero.

- [ ] **Step 6: Commit runtime integration**

```bash
git add lua/tiger_user_words.lua tests/tiger_user_words_test.lua
git commit -m "feat: support English text in guided word capture"
```

### Task 3: Schema Wiring, Documentation, And Regression Verification

**Files:**
- Modify: `tiger_base.schema.yaml:73-89`
- Modify: `tests/config_static_test.lua:60-180`
- Modify: `README.md:62-82`

- [ ] **Step 1: Write the failing processor-order test**

Add a static assertion that the user-word processor precedes
`ascii_composer`:

```lua
local base = read("tiger_base.schema.yaml")
local user_words = assert(base:find("lua_processor@%*tiger_user_words%*processor"))
local ascii_composer = assert(base:find("%- ascii_composer"))
assert(user_words < ascii_composer, "capture processor must precede ascii_composer")
```

- [ ] **Step 2: Run the static test and verify RED**

Run: `lua tests/config_static_test.lua`

Expected: failure with `capture processor must precede ascii_composer`.

- [ ] **Step 3: Move the processor and document interaction**

Place `lua_processor@*tiger_user_words*processor` immediately before
`ascii_composer`. Update README examples to state that bare Shift uses normal
English direct input during capture and that ending capture restores the
previous Chinese/English state.

- [ ] **Step 4: Run the complete local regression suite**

Run:

```bash
lua tests/tiger_capture_input_test.lua
lua tests/tiger_user_words_test.lua
lua tests/config_static_test.lua
for test in tests/*_test.lua; do lua "$test"; done
for test in tests/*_test.js; do node "$test"; done
python3 -m unittest discover -s tests -p 'test_*.py'
git diff --check
```

Expected: all Lua, JavaScript, and Python tests exit zero, followed by a clean
whitespace check.

- [ ] **Step 5: Commit schema and documentation**

```bash
git add tiger_base.schema.yaml tests/config_static_test.lua README.md
git commit -m "docs: explain guided English word capture"
```
