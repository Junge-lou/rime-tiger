--[[
Source:https://github.com/hchunhui/librime-lua/issues/35
通过特定命令启动外部程序。

※将"- lua_processor@exe_processor" 放在 engine/processors 里，并位于默认 selector 之前
※rime.lua中 增加"exe_processor = require("exe")"


--]] local function generic_open(dest)
  if os.execute('start "" ' .. dest) then
    return true
  elseif os.execute('open ' .. dest) then
    return true
  elseif os.execute('xdg-open ' .. dest) then
    return true
  end
end

local function command_matches(input, ...)
  for _, command in ipairs({...}) do
    if input == "/" .. command or input == "\\" .. command then
      return true
    end
  end
  return false
end

local function exe(key, env)
  local engine = env.engine
  local context = engine.context
  local kNoop = 2
  if command_matches(context.input, "huma", "zhmn") then
    generic_open("https://tiger-code.com")
    context:clear()
  elseif command_matches(context.input, "baidu", "bddu", "fuxl") then
    generic_open("https://www.baidu.com")
  elseif command_matches(context.input, "biying", "bing", "biyk", "htxk") then
    generic_open("https://cn.bing.com")
  elseif command_matches(context.input, "guge", "google", "hgzz") then
    generic_open("https://www.google.com")
    context:clear()
  elseif command_matches(context.input, "wangpan", "whpj", "mbia") then
    generic_open("http://huma.ysepan.com")
    context:clear()
  elseif command_matches(context.input, "genda", "gfda", "piua", "muyi", "emon") then
    generic_open("https://typer.owenyang.top")
    context:clear()
  elseif command_matches(context.input, "zitong", "zits", "whib") then
    generic_open("https://zi.tools")
    context:clear()
  elseif command_matches(context.input, "yedian", "yedm", "dnih") then
    generic_open("http://www.yedict.com")
    context:clear()
  end
  return kNoop
end

return exe
-- return { func = exe }    --与"return exe"等效。
