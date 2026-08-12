# Active Tiger Table Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export the complete effective table for the active `tiger` or `tigress` schema through `\\dcck` as one UTF-8, weightless TSV text file.

**Architecture:** Put dictionary parsing, overlay merging, sorting, unsafe-row filtering, and rendering in a pure Lua core. Keep the custom LevelDB format owned by `tiger_user_words`, and add a thin Rime adapter for schema detection, compiled-symbol extraction, confirmation state, notices, and atomic file replacement.

**Tech Stack:** librime-lua, Lua unit tests, Rime YAML configuration, existing shell/Python/JavaScript regression suite.

---

### Task 1: Pure Dictionary Export Core

**Files:**
- Create: `lua/table_export_core.lua`
- Create: `tests/table_export_core_test.lua`

- [ ] **Step 1: Write the failing parser and merge test**

Create temporary `tiger.extended`, `tiger`, and `tiger.user` dictionaries. Use
different column layouts in a second `tigress` fixture, then specify symbol and
runtime rows explicitly:

```lua
package.path = "./lua/?.lua;" .. package.path
local core = require("table_export_core")

local content, stats = assert(core.build({
  dictionary = "tigress.extended",
  base_dir = temp_dir,
  symbols = {
    { text = "→", code = "\\jt", order = 1 },
    { text = "\t", code = "\\tab", order = 2 },
  },
  user_records = {
    { text = "旧词", code = "aaaa", hidden = true },
    { text = "用户词", code = "aaaa", added = true, weight = 100000000000 },
    { text = "次选", code = "aaaa", weight = 99999999000 },
  },
}))

assert(content == table.concat({
  "用户词\taaaa",
  "次选\taaaa",
  "基础词\taaaa",
  "→\t\\jt",
  "",
}, "\n"))
assert(stats.skipped_unsafe == 1)
```

Add separate assertions that an exact `text + code` duplicate is removed,
the same text with another code survives, direct imports are collected once,
and missing `...` or `columns` produces an error.

- [ ] **Step 2: Run the core test and verify RED**

Run: `lua tests/table_export_core_test.lua`

Expected: failure because `table_export_core` does not exist.

- [ ] **Step 3: Implement restricted Rime dictionary-header parsing**

Create `lua/table_export_core.lua` with a public `build(options)` function and
focused private helpers:

```lua
local M = {}

local function split_tab(line) end
local function parse_header(lines, source) end
local function read_dictionary(path, read_file) end
local function collect_source_set(base_dir, root_name, read_file) end

function M.build(options)
  -- Read root + its direct import_tables, using each file's columns.
  -- Merge symbols and runtime records, filter, sort, and render.
end

return M
```

`parse_header` must recognize top-level `name`, `sort`, `columns`, and
`import_tables`, stop at the first exact `...`, and default absent `columns` to
`text`, `code`, `weight`. It must not recursively follow imports found in an
imported file.

- [ ] **Step 4: Implement effective overlay, ordering, and rendering**

Represent each entry with `text`, `code`, `weight`, `order`, and optional
`runtime_weight`. Apply records by the exact pair key
`code .. "\0" .. text`:

```lua
if record.hidden then
  by_pair[pair] = nil
elseif record.added and not by_pair[pair] then
  by_pair[pair] = new_runtime_entry(record)
end
if by_pair[pair] and record.weight and record.weight ~= 0 then
  by_pair[pair].runtime_weight = record.weight
end
```

Sort by code ascending, then effective weight descending, then stable order.
Reject fields containing `\0`, `\t`, `\r`, or `\n`. Render every accepted row
as `text .. "\t" .. code .. "\n"` without a BOM or YAML header and return
counts for exported, duplicate, malformed, blank-code, and unsafe rows.

- [ ] **Step 5: Run the core test and verify GREEN**

Run: `lua tests/table_export_core_test.lua`

Expected: `table export core tests passed` and exit zero.

- [ ] **Step 6: Commit the pure core**

```bash
git add lua/table_export_core.lua tests/table_export_core_test.lua
git commit -m "feat: add table export core"
```

### Task 2: Read-Only Runtime User Snapshot

**Files:**
- Modify: `lua/tiger_user_words.lua:22-1107`
- Modify: `tests/tiger_user_words_test.lua:1-340`

- [ ] **Step 1: Write the failing snapshot assertions**

After the existing add, disable, and reorder operations, assert the new public
API exposes isolated copies of LevelDB records:

```lua
local tiger_snapshot = assert(words.export_snapshot("tiger"))
local tigress_snapshot = assert(words.export_snapshot("tigress"))

assert(find_record(tiger_snapshot, "efgh", "TigerAdded").added)
assert(find_record(tiger_snapshot, "tsrc", "TigerSource").hidden)
assert(find_record(tiger_snapshot, "mnop", "第二").weight == 100000000000)
assert(find_record(tigress_snapshot, "efgh", "TigressAdded").added)
assert(not find_record(tigress_snapshot, "efgh", "TigerAdded"))
assert(words.export_snapshot("unknown") == nil)
```

Mutate one returned record and assert a second snapshot still contains the
stored value, proving callers cannot mutate internal state.

- [ ] **Step 2: Run the user-word test and verify RED**

Run: `lua tests/tiger_user_words_test.lua`

Expected: failure because `export_snapshot` is nil.

- [ ] **Step 3: Expose the read-only snapshot API**

Add a public function which uses the existing profile and `Store:list_all()`:

```lua
local function export_snapshot(schema_id)
  local profile = PROFILES[schema_id]
  if not profile then return nil end
  local store = acquire_db(profile.db_name)
  if not store then return nil, "用户词数据库不可用" end
  local output = {}
  for _, item in ipairs(store:list_all() or {}) do
    table.insert(output, {
      code = item.code,
      text = item.text,
      added = item.record.added,
      hidden = item.record.hidden,
      weight = item.record.weight,
    })
  end
  return output
end
```

Return it alongside the existing `processor` and `filter`. Do not expose the
store or shared state objects and do not write during snapshot creation.

- [ ] **Step 4: Run the user-word test and verify GREEN**

Run: `lua tests/tiger_user_words_test.lua`

Expected: `tiger_user_words tests passed` and exit zero.

- [ ] **Step 5: Commit the snapshot API**

```bash
git add lua/tiger_user_words.lua tests/tiger_user_words_test.lua
git commit -m "feat: expose user table export snapshot"
```

### Task 3: Rime Export Command Adapter

**Files:**
- Create: `lua/table_export.lua`
- Create: `tests/table_export_test.lua`

- [ ] **Step 1: Write failing command and symbol tests**

Build Rime mocks for schema config, `ConfigMap`, `ConfigList`, context,
composition, candidates, `yield`, and user data paths. Assert:

```lua
local exporter = require("table_export")

assert(exporter.command == "\\dcck")
assert(exporter.extract_symbols(config)[1].code == "\\jt")

exporter.translator("\\dcck", segment, tiger_env)
assert(yielded[1].text == "确认导出当前方案")
assert(yielded[2].text == "取消")

assert(exporter.processor.func(space_key, tiger_env) == 1)
assert(read_file(temp_dir .. "/tiger_export.txt") == expected_tsv)
assert(not file_exists(temp_dir .. "/tigress_export.txt"))
```

Add cases for `tigress`, selected cancellation, Escape, unsupported `PY_c`,
missing source files, success notices, failure notices, and no work when input
is not `\\dcck`.

- [ ] **Step 2: Run the adapter test and verify RED**

Run: `lua tests/table_export_test.lua`

Expected: failure because `table_export` does not exist.

- [ ] **Step 3: Implement compiled-symbol extraction**

Read `punctuator/symbols` through the librime-lua APIs:

```lua
local function item_values(item)
  local obj = item and item:get_obj()
  if not obj then return {} end
  if obj.type == "kScalar" then return { obj.value } end
  if obj.type ~= "kList" then return {} end
  local values = {}
  for index = 0, obj.size - 1 do
    local value = obj:get_at(index):get_obj()
    if value and value.type == "kScalar" then
      table.insert(values, value.value)
    end
  end
  return values
end
```

Sort `map:keys()` for deterministic code order and preserve each list's index
as candidate order.

- [ ] **Step 4: Implement schema detection and atomic file replacement**

Map supported schema IDs to their required dictionary and output filename:

```lua
local PROFILES = {
  tiger = { dictionary = "tiger.extended", output = "tiger_export.txt" },
  tigress = { dictionary = "tigress.extended", output = "tigress_export.txt" },
}
```

Read the actual `translator/dictionary` string and reject a mismatch. Obtain
the base directory from `rime_api.get_user_data_dir()`, call
`tiger_user_words.export_snapshot(schema_id)`, call the pure core, write
`output .. ".tmp"`, close it, then replace the destination using the existing
`os.rename` with Windows remove-and-retry fallback. Never remove the previous
destination until the temporary file is complete.

- [ ] **Step 5: Implement confirmation and notice state**

Use a weak table keyed by engine context so processor and translator instances
share only their own confirmation/result state. For input `\\dcck`, yield
confirm and cancel candidates. Accept Space, Return, `1`, or `2` according to
the selected row; Escape cancels. After export, keep the same input and yield
one status candidate containing exported count, skipped count, and full path.
Return `kNoop` for every unrelated input or key.

Export the module shape expected by named librime-lua components:

```lua
return {
  command = "\\dcck",
  translator = translator,
  processor = processor,
  extract_symbols = extract_symbols,
  _test_export = run_export,
}
```

- [ ] **Step 6: Run adapter and focused regression tests**

Run:

```bash
lua tests/table_export_core_test.lua
lua tests/table_export_test.lua
lua tests/tiger_user_words_test.lua
```

Expected: all three print success and exit zero.

- [ ] **Step 7: Commit the command adapter**

```bash
git add lua/table_export.lua tests/table_export_test.lua
git commit -m "feat: add active table export command"
```

### Task 4: Register Command, Hint, And Documentation

**Files:**
- Modify: `rime.lua:1-12`
- Modify: `tiger_base.schema.yaml:73-120`
- Modify: `lua/symbol_hint.lua:1-64`
- Modify: `tests/config_static_test.lua`
- Modify: `README.md:29-84`

- [ ] **Step 1: Write failing static wiring assertions**

Extend `tests/config_static_test.lua` with exact checks:

```lua
assert_contains(rime_lua, 'table_export = require("table_export")')
assert_contains(base_schema, "lua_processor@*table_export*processor")
assert_contains(base_schema, "lua_translator@*table_export*translator")
assert_contains(symbol_hint, '{ code = "dcck", label = "导出词库" }')
```

Also assert the export processor appears before `key_binder` and the export
translator appears before `table_translator`.

- [ ] **Step 2: Run the static test and verify RED**

Run: `lua tests/config_static_test.lua`

Expected: failure on the missing table-export registration.

- [ ] **Step 3: Register the module and command hint**

Add `table_export = require("table_export")` to `rime.lua`. Add
`lua_processor@*table_export*processor` to the shared Tiger processor list and
`lua_translator@*table_export*translator` to the translator list. Add
`{ code = "dcck", label = "导出词库" }` to `symbol_hint.lua`.

- [ ] **Step 4: Document usage and boundaries**

Add a README section describing:

```text
输入 \dcck，选择“确认导出当前方案”。
tiger 导出为 tiger_export.txt，tigress 导出为 tigress_export.txt。
文件位于 Rime 用户目录，格式为 UTF-8 无 BOM 的“词<Tab>编码”。
内容包含静态字词、手工用户词、符号命令以及快捷键产生的新增、屏蔽和调序。
字面 Tab 等不能安全表示的控制字符会跳过。
```

- [ ] **Step 5: Run static and focused tests**

Run:

```bash
lua tests/config_static_test.lua
lua tests/table_export_test.lua
```

Expected: both print success and exit zero.

- [ ] **Step 6: Commit wiring and documentation**

```bash
git add rime.lua tiger_base.schema.yaml lua/symbol_hint.lua tests/config_static_test.lua README.md
git commit -m "feat: wire table export command"
```

### Task 5: Real-Data And Full Regression Verification

**Files:**
- Create: `tests/table_export_real_smoke.lua`
- Modify only when verification exposes a defect: `lua/table_export_core.lua`, `lua/table_export.lua`, `lua/tiger_user_words.lua`, or their focused tests.

- [ ] **Step 1: Create the real-data core export smoke check**

Create a manual smoke script that invokes the production core against the real
source sets without writing export files:

```lua
package.path = "./lua/?.lua;" .. package.path
local core = require("table_export_core")

local function validate(dictionary, minimum)
  local content, stats = assert(core.build({
    dictionary = dictionary,
    base_dir = ".",
    symbols = {},
    user_records = {},
  }))
  assert(content:sub(1, 3) ~= "\239\187\191")
  assert(not content:find("name:", 1, true))
  local previous_code = nil
  local count = 0
  for line in content:gmatch("([^\n]+)\n") do
    local text, code = line:match("^([^\t]+)\t([^\t]+)$")
    assert(text and code)
    assert(not previous_code or previous_code <= code)
    previous_code = code
    count = count + 1
  end
  assert(count == stats.exported)
  assert(count > minimum)
  return count
end

local tiger = validate("tiger.extended", 100000)
local tigress = validate("tigress.extended", 200000)
print(string.format("real export smoke passed: tiger=%d tigress=%d", tiger, tigress))
```

- [ ] **Step 2: Run the real-data smoke check**

Run: `lua tests/table_export_real_smoke.lua`

Expected: both exports satisfy the invariants without modifying repository
files.

- [ ] **Step 3: Run the complete regression suite**

Run: `bash scripts/run_tests.sh`

Expected: every Python, Lua, and JavaScript test exits zero.

- [ ] **Step 4: Run repository integrity checks**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; status lists only intentional implementation
changes if a final verification fix has not yet been committed.

- [ ] **Step 5: Commit the smoke check and any verification-only fix**

Stage the manual smoke check plus any corrected implementation/test file from
Tasks 1-4:

```bash
git add tests/table_export_real_smoke.lua lua/table_export_core.lua lua/table_export.lua lua/tiger_user_words.lua tests/table_export_core_test.lua tests/table_export_test.lua tests/tiger_user_words_test.lua
git commit -m "test: verify table export with real dictionaries"
```
