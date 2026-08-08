package.path = "./lua/?.lua;" .. package.path

local user_data_dir = "/tmp/rime-tiger-option-sync-test"
os.execute("rm -rf " .. user_data_dir)
os.execute("mkdir -p " .. user_data_dir .. "/lua")

local clock_ms = 1000
rime_api = {
  get_user_data_dir = function()
    return user_data_dir
  end,
  get_time_ms = function()
    return clock_ms
  end,
}

local option_state = require("option_state")
local option_sync = require("option_sync")

local function contains(list, expected)
  for _, value in ipairs(list) do
    if value == expected then
      return true
    end
  end
  return false
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
  end
end

local function test_common_options_include_extended_char()
  assert_equal(contains(option_sync._test_option_names("tiger"), "extended_char"), true, "tiger syncs extended_char")
  assert_equal(contains(option_sync._test_option_names("tigress"), "extended_char"), true, "tigress syncs extended_char")
end

local function test_py_c_excludes_extended_char()
  assert_equal(contains(option_sync._test_option_names("PY_c"), "extended_char"), false, "PY_c should not sync extended_char")
end

local function make_env(options)
  local set_calls = {}
  local notifier = {
    connect = function()
      return {
        disconnect = function() end,
      }
    end,
  }
  local ctx = {
    get_option = function(_, name)
      return options[name] and true or false
    end,
    set_option = function(_, name, value)
      set_calls[#set_calls + 1] = { name = name, value = value and true or false }
      options[name] = value and true or false
    end,
    option_update_notifier = notifier,
  }
  return { engine = { context = ctx, schema = { schema_id = "tiger" } } }, set_calls
end

local function test_init_restores_persisted_state_over_rime_context()
  option_state._test_reset()
  option_state.set_many({ extended_char = false })
  option_state._test_reset()

  local options = { extended_char = true }
  local env, set_calls = make_env(options)

  option_sync.init(env)

  assert_equal(options.extended_char, false, "init should restore persisted full charset state")
  assert_equal(#set_calls > 0, true, "init should apply persisted full charset state")

  local saved = assert(dofile(user_data_dir .. "/lua/option_state_data.lua"))
  assert_equal(saved.extended_char, false, "init should keep persisted full charset state")
end

local function test_init_restores_saved_statistics_state_after_redeploy()
  option_state._test_reset()
  option_state.set_many({ input_speed_stat = true })
  option_state._test_reset()

  local options = { input_speed_stat = false }
  local env, set_calls = make_env(options)

  option_sync.init(env)

  assert_equal(options.input_speed_stat, true, "init should restore saved statistics state")
  assert_equal(#set_calls > 0, true, "init should apply the saved statistics state")
  local saved = assert(dofile(user_data_dir .. "/lua/option_state_data.lua"))
  assert_equal(saved.input_speed_stat, true, "init should keep the saved statistics state")
end

local function test_key_sync_is_throttled()
  option_state._test_reset()
  local options = { extended_char = false }
  local env, _ = make_env(options)
  local get_calls = 0
  local original_get = env.engine.context.get_option
  env.engine.context.get_option = function(self, name)
    get_calls = get_calls + 1
    return original_get(self, name)
  end

  clock_ms = 1000
  option_sync.init(env)
  get_calls = 0
  option_sync.func({ release = function() return false end }, env)
  assert_equal(get_calls, 0, "sync should not poll again within the interval")

  clock_ms = 1250
  option_sync.func({ release = function() return false end }, env)
  assert_equal(get_calls, 11, "sync should poll once after the interval")
end

local tests = {
  test_common_options_include_extended_char,
  test_py_c_excludes_extended_char,
  test_init_restores_persisted_state_over_rime_context,
  test_init_restores_saved_statistics_state_after_redeploy,
  test_key_sync_is_throttled,
}

for _, test in ipairs(tests) do
  test()
end

print("option_sync tests passed")
