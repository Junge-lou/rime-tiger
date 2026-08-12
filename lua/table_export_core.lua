local M = {}

local DEFAULT_COLUMNS = { "text", "code", "weight" }
local ENTRY_TEXT = 1
local ENTRY_CODE = 2
local ENTRY_WEIGHT = 3
local ENTRY_ORDER = 4
local ENTRY_RUNTIME_WEIGHT = 5

local function split_tab(line)
  local fields = {}
  local start = 1
  while true do
    local separator = string.find(line, "\t", start, true)
    if not separator then
      fields[#fields + 1] = string.sub(line, start)
      return fields
    end
    fields[#fields + 1] = string.sub(line, start, separator - 1)
    start = separator + 1
  end
end

local function trim(value)
  return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function scalar(value)
  value = trim(value)
  local quote = string.sub(value, 1, 1)
  if #value >= 2 and (quote == '"' or quote == "'") and string.sub(value, -1) == quote then
    return string.sub(value, 2, -2)
  end
  return value
end

local function parse_inline_list(value)
  local body = string.match(trim(value), "^%[(.*)%]$")
  if not body then
    return nil
  end
  local result = {}
  if trim(body) == "" then
    return result
  end
  for item in string.gmatch(body .. ",", "(.-),") do
    result[#result + 1] = scalar(item)
  end
  return result
end

local function validate_columns(columns, source)
  if not columns then
    return { DEFAULT_COLUMNS[1], DEFAULT_COLUMNS[2], DEFAULT_COLUMNS[3] }
  end
  if #columns == 0 then
    return nil, source .. ": columns must not be empty"
  end

  local indexes = {}
  local seen = {}
  for index, column in ipairs(columns) do
    if column == "" or not string.match(column, "^[%a_][%w_]*$") or seen[column] then
      return nil, source .. ": invalid columns declaration"
    end
    seen[column] = true
    indexes[column] = index
  end
  if not indexes.text or not indexes.code then
    return nil, source .. ": columns must contain text and code"
  end
  return columns
end

local function parse_header(next_line, source)
  local header = {
    import_tables = {},
  }
  local current_list
  local columns_declared = false

  while true do
    local line, read_err = next_line()
    if line == nil then
      if read_err ~= nil then
        return nil, source .. ": " .. tostring(read_err)
      end
      return nil, source .. ": missing exact ... terminator"
    end
    if line == "..." then
      break
    end

    local key, value = string.match(line, "^([%a_][%w_%-]*):%s*(.-)%s*$")
    if key then
      current_list = nil
      if key == "name" or key == "sort" then
        header[key] = scalar(value)
      elseif key == "columns" or key == "import_tables" then
        local inline = value ~= "" and parse_inline_list(value) or nil
        if value ~= "" and not inline then
          return nil, source .. ": invalid " .. key .. " declaration"
        end
        if key == "columns" then
          if columns_declared then
            return nil, source .. ": duplicate columns declaration"
          end
          columns_declared = true
          header.columns = inline or {}
        else
          header.import_tables = inline or {}
        end
        if value == "" then
          current_list = key
        end
      end
    elseif current_list then
      local item = string.match(line, "^%s+%-%s+(.+)%s*$")
      if item then
        local parsed = scalar(item)
        if parsed == "" then
          return nil, source .. ": invalid " .. current_list .. " declaration"
        end
        header[current_list][#header[current_list] + 1] = parsed
      elseif not string.match(line, "^%s*$") and not string.match(line, "^%s*#") then
        current_list = nil
      end
    end
  end

  local columns, err = validate_columns(header.columns, source)
  if not columns then
    return nil, err
  end
  header.columns = columns
  return header
end

local function strip_carriage_return(line)
  if string.sub(line, -1) == "\r" then
    return string.sub(line, 1, -2)
  end
  return line
end

local function open_file_lines(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, nil, err
  end

  local function close()
    if file then
      file:close()
      file = nil
    end
  end

  local function next_line()
    if not file then
      return nil
    end
    local line, read_err = file:read("*l")
    if line == nil then
      close()
      return nil, read_err
    end
    return strip_carriage_return(line)
  end
  return next_line, close
end

local function open_content_lines(path, read_file)
  local ok, content, read_err = pcall(read_file, path)
  if not ok then
    return nil, nil, tostring(content)
  end
  if type(content) ~= "string" then
    return nil, nil, tostring(read_err or "could not read dictionary")
  end

  local offset = 1
  local length = #content
  local function close()
    content = nil
  end
  local function next_line()
    if not content then
      return nil
    end
    if offset > length then
      close()
      return nil
    end
    local newline = string.find(content, "\n", offset, true)
    local line
    if newline then
      line = string.sub(content, offset, newline - 1)
      offset = newline + 1
    else
      line = string.sub(content, offset)
      close()
    end
    return strip_carriage_return(line)
  end
  return next_line, close
end

local function process_dictionary(path, read_file, make_consumer)
  local next_line, close, open_err
  if read_file then
    next_line, close, open_err = open_content_lines(path, read_file)
  else
    next_line, close, open_err = open_file_lines(path)
  end
  if not next_line then
    return nil, path .. ": " .. tostring(open_err)
  end

  local header, header_err = parse_header(next_line, path)
  if not header then
    close()
    return nil, header_err
  end
  local consume_line = make_consumer(header.columns)
  while true do
    local line, read_err = next_line()
    if line == nil then
      if read_err ~= nil then
        close()
        return nil, path .. ": " .. tostring(read_err)
      end
      break
    end
    consume_line(line)
  end
  close()
  return header
end

local function dictionary_path(base_dir, name)
  local separator = string.sub(base_dir, -1) == "/" and "" or "/"
  return base_dir .. separator .. name .. ".dict.yaml"
end

local function contains_unsafe(value)
  return string.find(value, "\0", 1, true)
    or string.find(value, "\t", 1, true)
    or string.find(value, "\r", 1, true)
    or string.find(value, "\n", 1, true)
end

local function normalize_weight(value)
  if value == nil or value == "" then
    return 0
  end
  local weight = tonumber(value)
  if not weight or weight ~= weight then
    return nil
  end
  return weight
end

local function validate_pair(text, code, stats)
  if type(text) ~= "string" or type(code) ~= "string" or text == "" then
    stats.skipped_malformed = stats.skipped_malformed + 1
    return false
  end
  if contains_unsafe(text) or contains_unsafe(code) then
    stats.skipped_unsafe = stats.skipped_unsafe + 1
    return false
  end
  if string.match(code, "^%s*$") then
    stats.skipped_blank_code = stats.skipped_blank_code + 1
    return false
  end
  return true
end

local function column_indexes(columns)
  local indexes = {}
  for index, name in ipairs(columns) do
    indexes[name] = index
  end
  return indexes
end

local function bytewise_less(a, b)
  local a1, a2, a3, a4 = string.byte(a, 1, 4)
  local b1, b2, b3, b4 = string.byte(b, 1, 4)
  if a1 ~= b1 then
    return (a1 or -1) < (b1 or -1)
  end
  if a2 ~= b2 then
    return (a2 or -1) < (b2 or -1)
  end
  if a3 ~= b3 then
    return (a3 or -1) < (b3 or -1)
  end
  if a4 ~= b4 then
    return (a4 or -1) < (b4 or -1)
  end
  local length = math.min(#a, #b)
  for index = 5, length do
    local a_byte = string.byte(a, index)
    local b_byte = string.byte(b, index)
    if a_byte ~= b_byte then
      return a_byte < b_byte
    end
  end
  return #a < #b
end

function M.build(options)
  if type(options) ~= "table" then
    return nil, "options must be a table"
  end
  if type(options.dictionary) ~= "string" or options.dictionary == "" then
    return nil, "dictionary must be a non-empty string"
  end
  local base_dir = options.base_dir or "."
  if type(base_dir) ~= "string" or base_dir == "" then
    return nil, "base_dir must be a non-empty string"
  end
  local read_file = options.read_file
  if read_file ~= nil and type(read_file) ~= "function" then
    return nil, "read_file must be a function"
  end

  local stats = {
    exported = 0,
    skipped_duplicate = 0,
    skipped_malformed = 0,
    skipped_blank_code = 0,
    skipped_unsafe = 0,
  }
  local by_pair = {}
  local next_order = 0

  local function add_entry(text, code, weight)
    if not validate_pair(text, code, stats) then
      return nil
    end
    weight = normalize_weight(weight)
    if not weight then
      stats.skipped_malformed = stats.skipped_malformed + 1
      return nil
    end
    local pair = code .. "\0" .. text
    if by_pair[pair] then
      stats.skipped_duplicate = stats.skipped_duplicate + 1
      return by_pair[pair]
    end
    next_order = next_order + 1
    local entry = { text, code, weight, next_order }
    by_pair[pair] = entry
    return entry
  end

  local function make_dictionary_consumer(columns)
    local indexes = column_indexes(columns)
    local required_fields = math.max(indexes.text, indexes.code)
    return function(line)
      if string.match(line, "^%s*$") or string.match(line, "^%s*#") then
        return
      end
      local fields = split_tab(line)
      if #fields < required_fields or #fields > #columns then
        stats.skipped_malformed = stats.skipped_malformed + 1
      else
        add_entry(fields[indexes.text], fields[indexes.code], indexes.weight and fields[indexes.weight])
      end
    end
  end

  local root_name = options.dictionary
  local root, root_err = process_dictionary(
    dictionary_path(base_dir, root_name),
    read_file,
    make_dictionary_consumer
  )
  if not root then
    return nil, root_err
  end
  local seen_sources = { [root_name] = true }
  for _, name in ipairs(root.import_tables) do
    if not seen_sources[name] then
      seen_sources[name] = true
      local imported, import_err = process_dictionary(
        dictionary_path(base_dir, name),
        read_file,
        make_dictionary_consumer
      )
      if not imported then
        return nil, import_err
      end
    end
  end

  if options.symbols ~= nil and type(options.symbols) ~= "table" then
    return nil, "symbols must be a table"
  end
  local symbols = {}
  for index, symbol in ipairs(options.symbols or {}) do
    symbols[#symbols + 1] = {
      value = symbol,
      index = index,
      order = type(symbol) == "table" and tonumber(symbol.order) or nil,
    }
  end
  table.sort(symbols, function(a, b)
    local a_order = a.order or a.index
    local b_order = b.order or b.index
    if a_order ~= b_order then
      return a_order < b_order
    end
    return a.index < b.index
  end)
  for _, item in ipairs(symbols) do
    local symbol = item.value
    if type(symbol) ~= "table" then
      stats.skipped_malformed = stats.skipped_malformed + 1
    else
      add_entry(symbol.text, symbol.code, symbol.weight)
    end
  end

  if options.user_records ~= nil and type(options.user_records) ~= "table" then
    return nil, "user_records must be a table"
  end
  for _, record in ipairs(options.user_records or {}) do
    if type(record) ~= "table" then
      stats.skipped_malformed = stats.skipped_malformed + 1
    elseif validate_pair(record.text, record.code, stats) then
      local weight = normalize_weight(record.weight)
      if not weight then
        stats.skipped_malformed = stats.skipped_malformed + 1
      else
        local pair = record.code .. "\0" .. record.text
        if record.hidden then
          by_pair[pair] = nil
        elseif record.added and not by_pair[pair] then
          add_entry(record.text, record.code, weight)
        end
        if by_pair[pair] and weight ~= 0 then
          by_pair[pair][ENTRY_RUNTIME_WEIGHT] = weight
        end
      end
    end
  end

  local entries = {}
  for _, entry in pairs(by_pair) do
    entries[#entries + 1] = entry
  end
  -- Avoid retaining the merge, sort, and render working sets at the same time.
  by_pair = nil
  table.sort(entries, function(a, b)
    if a[ENTRY_CODE] ~= b[ENTRY_CODE] then
      return bytewise_less(a[ENTRY_CODE], b[ENTRY_CODE])
    end
    local a_weight = a[ENTRY_RUNTIME_WEIGHT] or a[ENTRY_WEIGHT]
    local b_weight = b[ENTRY_RUNTIME_WEIGHT] or b[ENTRY_WEIGHT]
    if a_weight ~= b_weight then
      return a_weight > b_weight
    end
    return a[ENTRY_ORDER] < b[ENTRY_ORDER]
  end)

  local rendered = {}
  local exported = #entries
  for index = 1, exported do
    local entry = entries[index]
    rendered[#rendered + 1] = entry[ENTRY_TEXT] .. "\t" .. entry[ENTRY_CODE] .. "\n"
    entries[index] = nil
  end
  stats.exported = exported
  local content = table.concat(rendered)
  entries = nil
  rendered = nil
  return content, stats
end

return M
