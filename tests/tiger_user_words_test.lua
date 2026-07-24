package.path = "./lua/?.lua;" .. package.path

local trigger = require("tiger_add_trigger")

assert(trigger.can_append("abcd"))
assert(trigger.can_append("abcd\\"))
assert(not trigger.can_append(""))
assert(not trigger.can_append("\\djs"))
assert(not trigger.can_append("abcd\\\\"))

assert(trigger.target_code("abcd\\\\") == "abcd")
assert(trigger.target_code("abcd\\") == nil)
assert(trigger.target_code("\\\\") == nil)
assert(trigger.target_code("\\djs\\\\") == nil)
assert(trigger.target_code("ab\\cd\\\\") == nil)

local temp_dir = os.tmpname()
os.remove(temp_dir)
assert(os.execute("mkdir -p " .. temp_dir))

local errors = {}
rime_api = {
  get_user_data_dir = function()
    return temp_dir
  end,
}
log = {
  error = function(message)
    table.insert(errors, message)
  end,
}

local function notifier()
  return {
    connect = function(_, _)
      return { disconnect = function() end }
    end,
  }
end

local function new_init_env(schema_id)
  return {
    engine = {
      schema = {
        schema_id = schema_id,
        page_size = 5,
      },
      context = {
        update_notifier = notifier(),
        select_notifier = notifier(),
      },
    },
  }
end

local words = require("tiger_user_words")
local tiger_env = new_init_env("tiger")
local second_tiger_env = new_init_env("tiger")
local tigress_env = new_init_env("tigress")

words.processor.init(tiger_env)
words.processor.init(second_tiger_env)
words.processor.init(tigress_env)

assert(tiger_env.state.config.extended_dict == "tiger.user.dict.yaml")
assert(tigress_env.state.config.extended_dict == "tigress.user.dict.yaml")
assert(tiger_env.state == second_tiger_env.state)
assert(tiger_env.state ~= tigress_env.state)
assert(io.open(temp_dir .. "/tiger.user.dict.yaml", "r"))
assert(io.open(temp_dir .. "/tigress.user.dict.yaml", "r"))
assert(require("tigress_user_words") == words)

local unknown_env = new_init_env("unknown")
words.processor.init(unknown_env)
assert(unknown_env.state == nil)
assert(#errors == 1)

assert(os.remove(temp_dir .. "/tiger.user.dict.yaml"))
assert(os.remove(temp_dir .. "/tigress.user.dict.yaml"))
assert(os.remove(temp_dir))

print("tiger_user_words tests passed")
