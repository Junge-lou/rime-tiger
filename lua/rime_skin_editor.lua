local M = {}

local OPTION_NAME = "rime_skin_editor"
local kNoop = 2
local throttle_ms = 2000
local last_launch_ms = -throttle_ms

local now_ms_fn = nil
local execute_fn = nil
local platform_fn = nil

local function now_ms()
  if now_ms_fn then
    return now_ms_fn()
  end
  if rime_api and rime_api.get_time_ms then
    return rime_api.get_time_ms()
  end
  return os.time() * 1000
end

local function path_separator()
  return package.config:sub(1, 1)
end

local function user_data_dir()
  if rime_api and rime_api.get_user_data_dir then
    return rime_api.get_user_data_dir()
  end
  return "."
end

local function shell_quote(value)
  local text = tostring(value or "")
  if path_separator() == "\\" then
    return '"' .. text:gsub('"', '\\"') .. '"'
  end
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function detected_platform()
  if platform_fn then
    return platform_fn()
  end
  if path_separator() == "\\" then
    return "windows"
  end
  local uname = io.popen and io.popen("uname -s 2>/dev/null")
  if uname then
    local value = uname:read("*l") or ""
    uname:close()
    if value == "Darwin" then
      return "mac"
    end
  end
  return "unix"
end

local function launcher_path(platform)
  local sep = path_separator()
  local suffix = platform == "windows" and "启动.bat" or "启动.command"
  return table.concat({ user_data_dir(), "Rime皮肤编辑器", suffix }, sep)
end

local function launcher_command(platform)
  local path = launcher_path(platform)
  if platform == "windows" then
    return 'start "" ' .. shell_quote(path)
  end
  if platform == "mac" then
    return "open " .. shell_quote(path)
  end
  return "sh " .. shell_quote(path) .. " >/dev/null 2>&1 &"
end

local function launch()
  local platform = detected_platform()
  local command = launcher_command(platform)
  local execute = execute_fn or os.execute
  return execute(command)
end

local function launch_throttled()
  local current = now_ms()
  if current - last_launch_ms < throttle_ms then
    return false
  end
  last_launch_ms = current
  launch()
  return true
end

local function get_context(env)
  return env and env.engine and env.engine.context or nil
end

local function maybe_launch(env)
  local ctx = get_context(env)
  if not ctx or not ctx.get_option or not ctx:get_option(OPTION_NAME) then
    return
  end
  if ctx.set_option then
    ctx:set_option(OPTION_NAME, false)
  end

  launch_throttled()
end

local processor = {}

function processor.init(env)
  local ctx = get_context(env)
  if ctx and ctx.option_update_notifier and ctx.option_update_notifier.connect then
    env.rime_skin_editor_notifier = ctx.option_update_notifier:connect(function()
      maybe_launch(env)
    end)
  end
  maybe_launch(env)
end

function processor.fini(env)
  if env and env.rime_skin_editor_notifier and env.rime_skin_editor_notifier.disconnect then
    env.rime_skin_editor_notifier:disconnect()
  end
end

function processor.func(_, env)
  maybe_launch(env)
  return kNoop
end

function M._test_reset(opts)
  opts = opts or {}
  now_ms_fn = opts.now_ms
  execute_fn = opts.execute
  platform_fn = opts.platform
  last_launch_ms = -throttle_ms
end

function M.open_from_command(env)
  local ctx = get_context(env)
  if ctx and ctx.clear then
    ctx:clear()
  end
  return launch_throttled()
end

M.processor = processor

return M
