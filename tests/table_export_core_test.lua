package.path = "./lua/?.lua;" .. package.path

local core = require("table_export_core")

local temp_dir = "/tmp/rime-tiger-table-export-core-test"
os.execute("rm -rf " .. temp_dir)
assert(os.execute("mkdir -p " .. temp_dir))

local function write_dictionary(name, content)
  local file = assert(io.open(temp_dir .. "/" .. name .. ".dict.yaml", "wb"))
  file:write(content)
  file:close()
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label, tostring(expected), tostring(actual)), 2)
  end
end

local function assert_contains(text, expected, label)
  if not text or not string.find(text, expected, 1, true) then
    error(string.format("%s: expected %q in %q", label, expected, tostring(text)), 2)
  end
end

local function assert_build_error(dictionary, expected, label)
  local content, err = core.build({
    dictionary = dictionary,
    base_dir = temp_dir,
  })
  assert_equal(content, nil, label .. " returns nil")
  assert_contains(err, expected, label)
end

local function test_merges_root_direct_imports_symbols_and_runtime_records()
  write_dictionary("tigress.extended", [[
---
name: tigress.extended
sort: by_weight
columns:
  - text
  - code
  - weight
import_tables:
  - tigress.base
  - tigress.base
  - tigress.direct
...

根词	zzzz	1
]])
  write_dictionary("tigress.base", [[
---
name: tigress.base
sort: by_weight
import_tables:
  - tigress.nested
columns:
  - code
  - text
  - weight
...
aaaa	基础词	10
aaaa	次选	20
bbbb	同文	5
cccc	重复词	4
aaaa	旧词	30
malformed-only
	空码	6
]])
  write_dictionary("tigress.direct", [[
---
name: tigress.direct
sort: by_weight
columns:
  - weight
  - text
  - code
...
25	直接词	aaaa
999	重复词	cccc
3	同文	dddd
]])

  local content, stats = assert(core.build({
    dictionary = "tigress.extended",
    base_dir = temp_dir,
    symbols = {
      { text = "→", code = "\\jt", order = 2 },
      { text = "←", code = "\\jt", order = 1 },
      { text = "\t", code = "\\tab", order = 3 },
      { text = "nul\0text", code = "\\nul-text", order = 4 },
      { text = "cr\rtext", code = "\\cr-text", order = 5 },
      { text = "lf\ntext", code = "\\lf-text", order = 6 },
      { text = "tab code", code = "\\bad\tcode", order = 7 },
      { text = "nul code", code = "\\bad\0code", order = 8 },
      { text = "cr code", code = "\\bad\rcode", order = 9 },
      { text = "lf code", code = "\\bad\ncode", order = 10 },
    },
    user_records = {
      { text = "旧词", code = "aaaa", hidden = true },
      { text = "用户词", code = "aaaa", added = true, weight = 100000000000 },
      { text = "次选", code = "aaaa", weight = 99999999000 },
      { text = "不存在", code = "aaaa", weight = 200000000000 },
    },
  }))

  assert_equal(content, table.concat({
    "←\t\\jt",
    "→\t\\jt",
    "用户词\taaaa",
    "次选\taaaa",
    "直接词\taaaa",
    "基础词\taaaa",
    "同文\tbbbb",
    "重复词\tcccc",
    "同文\tdddd",
    "根词\tzzzz",
    "",
  }, "\n"), "merged export")
  assert_equal(stats.exported, 10, "exported rows")
  assert_equal(stats.skipped_duplicate, 1, "exact pair duplicate")
  assert_equal(stats.skipped_malformed, 1, "malformed row")
  assert_equal(stats.skipped_blank_code, 1, "blank code row")
  assert_equal(stats.skipped_unsafe, 8, "unsafe text and code fields")
end

local function test_equal_weights_keep_stable_source_order()
  write_dictionary("stable.extended", [[
---
name: stable.extended
sort: by_weight
import_tables:
  - stable.first
  - stable.second
...
根先	tie	7
]])
  write_dictionary("stable.first", [[
---
name: stable.first
sort: by_weight
...
导入一	tie	7
]])
  write_dictionary("stable.second", [[
---
name: stable.second
sort: by_weight
...
导入二	tie	7
]])

  local content = assert(core.build({
    dictionary = "stable.extended",
    base_dir = temp_dir,
  }))
  assert_equal(content, "根先\ttie\n导入一\ttie\n导入二\ttie\n", "stable source order")
end

local function test_code_sort_is_bytewise_under_non_c_collation()
  write_dictionary("ascii-order", [[
---
name: ascii-order
sort: by_weight
...
小写	a	1
反斜杠	\slash	1
大写	A	1
]])

  local previous = os.setlocale(nil, "collate")
  local candidates = {
    "en_US.UTF-8",
    "en_US.utf8",
    "zh_CN.UTF-8",
    "zh_CN.utf8",
    "de_DE.UTF-8",
    "de_DE.utf8",
  }
  for _, locale in ipairs(candidates) do
    if os.setlocale(locale, "collate") and not ("A" < "\\" and "\\" < "a") then
      break
    end
  end

  local ok, err = pcall(function()
    local content = assert(core.build({
      dictionary = "ascii-order",
      base_dir = temp_dir,
    }))
    assert_equal(content, "大写\tA\n反斜杠\t\\slash\n小写\ta\n", "bytewise ASCII code order")
  end)
  os.setlocale(previous or "C", "collate")
  if not ok then
    error(err, 0)
  end
end

local function test_absent_columns_use_rime_defaults()
  write_dictionary("tiger.extended", [[
---
name: tiger.extended
sort: by_weight
import_tables:
  - tiger.default
...
根默认	root	2
]])
  write_dictionary("tiger.default", [[
---
name: tiger.default
sort: by_weight
...
导入默认	base	3
]])

  local content, stats = assert(core.build({
    dictionary = "tiger.extended",
    base_dir = temp_dir,
  }))
  assert_equal(content, "导入默认\tbase\n根默认\troot\n", "default columns")
  assert_equal(stats.exported, 2, "default-column export count")
end

local function test_missing_exact_terminator_is_an_error()
  write_dictionary("missing-terminator", [[
---
name: missing-terminator
sort: by_weight
columns:
  - text
  - code
  - weight
 ...
词	code	1
]])
  assert_build_error("missing-terminator", "exact ... terminator", "missing terminator")
end

local function test_unusable_columns_are_an_error()
  write_dictionary("invalid-columns", [[
---
name: invalid-columns
sort: by_weight
columns:
  - weight
  - text
...
1	词
]])
  assert_build_error("invalid-columns", "columns", "invalid columns")
end

local function build_with_failing_file(lines)
  local original_open = io.open
  local closed = false
  local index = 0
  io.open = function()
    return {
      read = function(_, format)
        assert_equal(format, "*l", "streaming read format")
        index = index + 1
        if lines[index] ~= nil then
          return lines[index]
        end
        return nil, "simulated disk read failure"
      end,
      close = function()
        closed = true
      end,
    }
  end

  local ok, content, err = pcall(core.build, {
    dictionary = "read-error",
    base_dir = "/unused",
  })
  io.open = original_open
  if not ok then
    error(content, 0)
  end
  return content, err, closed
end

local function test_body_read_error_returns_no_partial_export_and_closes_file()
  local content, err, closed = build_with_failing_file({
    "---",
    "name: read-error",
    "sort: by_weight",
    "...",
    "已读取\tcode\t1",
  })
  assert_equal(content, nil, "body read error content")
  assert_contains(err, "simulated disk read failure", "body read error")
  assert_equal(closed, true, "body read error closes file")
end

local function test_header_read_error_is_distinct_from_missing_terminator()
  local content, err, closed = build_with_failing_file({
    "---",
    "name: read-error",
    "sort: by_weight",
  })
  assert_equal(content, nil, "header read error content")
  assert_contains(err, "simulated disk read failure", "header read error")
  assert_equal(closed, true, "header read error closes file")
end

local tests = {
  test_merges_root_direct_imports_symbols_and_runtime_records,
  test_equal_weights_keep_stable_source_order,
  test_code_sort_is_bytewise_under_non_c_collation,
  test_absent_columns_use_rime_defaults,
  test_missing_exact_terminator_is_an_error,
  test_unusable_columns_are_an_error,
  test_body_read_error_returns_no_partial_export_and_closes_file,
  test_header_read_error_is_distinct_from_missing_terminator,
}

for _, test in ipairs(tests) do
  test()
end

os.execute("rm -rf " .. temp_dir)
print("table export core tests passed")
