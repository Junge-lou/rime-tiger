package.path = "./lua/?.lua;" .. package.path

local core = require("table_export_core")

local function compare_bytewise(left, right)
  local shared_length = math.min(#left, #right)
  for index = 1, shared_length do
    local left_byte = string.byte(left, index)
    local right_byte = string.byte(right, index)
    if left_byte ~= right_byte then
      return left_byte < right_byte and -1 or 1
    end
  end
  if #left == #right then
    return 0
  end
  return #left < #right and -1 or 1
end

local function verify_dictionary(dictionary, minimum_count)
  local content, stats = assert(core.build({
    dictionary = dictionary,
    base_dir = ".",
    symbols = {},
    user_records = {},
  }))

  assert(string.sub(content, 1, 3) ~= "\239\187\191", dictionary .. ": output has a UTF-8 BOM")
  assert(string.sub(content, 1, 4) ~= "---\n", dictionary .. ": output has a YAML header")
  assert(not string.find(content, "\r", 1, true), dictionary .. ": output contains a CR byte")
  assert(not string.find(content, "\0", 1, true), dictionary .. ": output contains a NUL byte")
  assert(string.sub(content, -1) == "\n", dictionary .. ": output must end with one newline")
  assert(string.sub(content, 1, 1) ~= "\n", dictionary .. ": output has a leading empty record")
  assert(not string.find(content, "\n\n", 1, true), dictionary .. ": output has an empty record")

  local count = 0
  local previous_code
  for line in string.gmatch(content, "(.-)\n") do
    assert(line ~= "", dictionary .. ": output has an empty record")
    local first_tab = string.find(line, "\t", 1, true)
    assert(first_tab, dictionary .. ": output line has no Tab separator")
    assert(not string.find(line, "\t", first_tab + 1, true), dictionary .. ": output line has extra Tabs")

    local text = string.sub(line, 1, first_tab - 1)
    local code = string.sub(line, first_tab + 1)
    assert(text ~= "", dictionary .. ": output line has empty text")
    assert(code ~= "", dictionary .. ": output line has empty code")
    if previous_code then
      assert(
        compare_bytewise(previous_code, code) <= 0,
        string.format("%s: code order decreased from %q to %q", dictionary, previous_code, code)
      )
    end
    previous_code = code
    count = count + 1
  end

  assert(count == stats.exported, string.format(
    "%s: counted %d output rows, stats reported %d",
    dictionary,
    count,
    stats.exported
  ))
  assert(count > minimum_count, string.format(
    "%s: expected more than %d rows, got %d",
    dictionary,
    minimum_count,
    count
  ))
  for _, counter in ipairs({
    "skipped_duplicate",
    "skipped_malformed",
    "skipped_blank_code",
    "skipped_unsafe",
  }) do
    assert(stats[counter] == 0, string.format(
      "%s: expected %s=0, got %s",
      dictionary,
      counter,
      tostring(stats[counter])
    ))
  end

  return count
end

local tiger_count = verify_dictionary("tiger.extended", 100000)
local tigress_count = verify_dictionary("tigress.extended", 200000)

print(string.format("real export smoke passed: tiger=%d tigress=%d", tiger_count, tigress_count))
