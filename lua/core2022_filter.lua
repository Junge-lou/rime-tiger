local M = {}

local charsets = {
  { first = 0x4e00, last = 0x9fff }, -- CJK Unified Ideographs
  { first = 0x3400, last = 0x4dbf }, -- Extension A
  { first = 0x20000, last = 0x2a6df }, -- Extension B
  { first = 0x2a700, last = 0x2b73f }, -- Extension C
  { first = 0x2b740, last = 0x2b81f }, -- Extension D
  { first = 0x2b820, last = 0x2ceaf }, -- Extension E
  { first = 0x2ceb0, last = 0x2ebef }, -- Extension F
  { first = 0x30000, last = 0x3134f }, -- Extension G
  { first = 0x31350, last = 0x323af }, -- Extension H
  { first = 0x2ebf0, last = 0x2ee5d }, -- Extension I
  { first = 0x31c0, last = 0x31ef }, -- CJK Strokes
  { first = 0x2e80, last = 0x2eff }, -- CJK Radicals Supplement
  { first = 0x2f00, last = 0x2fdf }, -- Kangxi Radicals
  { first = 0xf900, last = 0xfadf }, -- CJK Compatibility Ideographs
  { first = 0x2f800, last = 0x2fa1f }, -- Compatibility Supplement
  { first = 0x2ff0, last = 0x2fff }, -- Ideographic Description Characters
  { first = 0x3100, last = 0x312f }, -- Bopomofo
  { first = 0x31a0, last = 0x31bf }, -- Bopomofo Extended
  { first = 0xe000, last = 0xf8ff }, -- Private Use Area
  { first = 0xf0000, last = 0xffffd }, -- Supplementary Private Use Area-A
  { first = 0x100000, last = 0x10fffd }, -- Supplementary Private Use Area-B
}

local function is_cjk(code)
  for _, charset in ipairs(charsets) do
    if code >= charset.first and code <= charset.last then
      return true
    end
  end
  return false
end

local function lookup(coredb, ch)
  if not coredb or not coredb.lookup then
    return nil
  end
  local ok, result = pcall(function()
    return coredb:lookup(ch)
  end)
  if not ok then
    return nil
  end
  return result
end

local function should_yield(text, full_mode, coredb)
  if full_mode or text == nil or text == "" then
    return true
  end
  if not coredb then
    return true
  end

  for pos in utf8.codes(tostring(text)) do
    local code = utf8.codepoint(text, pos)
    if is_cjk(code) then
      local result = lookup(coredb, utf8.char(code))
      if result == nil then
        return true
      end
      if result == "" then
        return false
      end
    end
  end
  return true
end

function M.init(env)
  if not ReverseDb then
    env.core2022_db = nil
    return
  end
  local ok, db = pcall(function()
    return ReverseDb("build/core2022.reverse.bin")
  end)
  if ok then
    env.core2022_db = db
  else
    env.core2022_db = nil
  end
end

function M.func(input, env)
  local context = env and env.engine and env.engine.context
  local full_mode = context and context.get_option and context:get_option("extended_char")
  local coredb = env and env.core2022_db
  for cand in input:iter() do
    if should_yield(cand and cand.text, full_mode, coredb) then
      yield(cand)
    end
  end
end

function M._test_should_yield(text, full_mode, coredb)
  return should_yield(text, full_mode, coredb)
end

return M
