package.path = "./lua/?.lua;" .. package.path

local records = {
  { code = "bbbb", text = "隐藏旧", hidden = true, ordered = false, added = false, updated_at = 10 },
  { code = "aaaa", text = "隐藏新", hidden = true, ordered = false, added = false, updated_at = 20 },
  { code = "cccc", text = "调序词", hidden = false, ordered = true, added = false, updated_at = 30 },
  { code = "dddd", text = "快捷词", hidden = false, ordered = false, added = true, source = "shortcut", updated_at = 40 },
  { code = "eeee", text = "迁移词", hidden = false, ordered = false, added = true, updated_at = 50 },
}

local actions = {}
package.loaded.tiger_user_words = {
  manager_snapshot = function(schema_id)
    assert(schema_id == "tiger")
    return records
  end,
  restore_hidden = function(schema_id, code, text)
    table.insert(actions, { "restore", schema_id, code, text })
    return text ~= "失败项"
  end,
  clear_order = function(schema_id, code, text)
    table.insert(actions, { "order", schema_id, code, text })
    return true
  end,
  remove_shortcut = function(schema_id, code, text)
    table.insert(actions, { "shortcut", schema_id, code, text })
    return true
  end,
}

local manager = require("tiger_user_words_manager")
local test = manager._test

assert(test.parse_route("\\gl").category == nil)
assert(test.parse_route("\\glh").category == "h")
assert(test.parse_route("\\glocode").query == "code")
assert(test.parse_route("\\glh;a'").query == ";a'")
assert(test.parse_route("\\gluABC") == nil)
assert(test.parse_route("=1+1") == nil)

local hidden = test.category_records(records, "h", "")
assert(#hidden == 2 and hidden[1].text == "隐藏新" and hidden[2].text == "隐藏旧")
assert(#test.category_records(records, "h", "bbbb") == 1)
assert(#test.category_records(records, "o", "") == 1)
local shortcut = test.category_records(records, "u", "")
assert(#shortcut == 1 and shortcut[1].text == "快捷词")
assert(test.record_comment("h", hidden[1]):find("恢复", 1, true))
assert(test.record_comment("o", records[3]):find("清除调序", 1, true))
assert(test.record_comment("u", records[4]):find("删除", 1, true))

Candidate = function(candidate_type, start, finish, text, comment)
  return { type = candidate_type, start = start, _end = finish, text = text, comment = comment }
end

local yielded = {}
yield = function(cand) table.insert(yielded, cand) end

local properties = {}
local context
context = {
  input = "",
  refresh_count = 0,
  composition = {
    empty = function() return context.input == "" end,
    back = function() return context.segment end,
  },
}
function context:push_input(text) self.input = self.input .. text end
function context:pop_input(count) self.input = self.input:sub(1, #self.input - count) end
function context:clear() self.input = "" end
function context:refresh_non_confirmed_composition() self.refresh_count = self.refresh_count + 1 end
function context:get_property(name) return properties[name] or "" end
function context:set_property(name, value) properties[name] = value end
function context:get_selected_candidate() return self.selected end

local env = { engine = { schema = { schema_id = "tiger" }, context = context } }
local function key(keycode, modifiers)
  modifiers = modifiers or {}
  return {
    keycode = keycode,
    ctrl = function() return modifiers.ctrl or false end,
    alt = function() return modifiers.alt or false end,
    shift = function() return modifiers.shift or false end,
    super = function() return modifiers.super or false end,
    release = function() return modifiers.release or false end,
  }
end

manager.processor.init(env)
assert(manager.processor.func(key(0x4d, { ctrl = true, shift = true }), env) == 1)
assert(context.input == "\\gl")

yielded = {}
manager.translator.func("\\gl", { start = 0, _end = 3 }, env)
assert(#yielded == 3 and yielded[1].text == "已隐藏" and yielded[3].text == "快捷加词")

context.selected = yielded[1]
assert(manager.processor.func(key(0x20), env) == 1)
assert(context.input == "\\glh")

context.input = "\\gl"
context.segment = {
  selected_index = 0,
  menu = {
    prepare = function() end,
    get_candidate_at = function(_, index) return yielded[index + 1] end,
  },
}
assert(manager.processor.func(key(0x32), env) == 1)
assert(context.input == "\\glo")
context.input = "\\glh"

yielded = {}
manager.translator.func("\\glh", { start = 0, _end = 4 }, env)
assert(#yielded == 2 and yielded[1].text == "隐藏新")
context.selected = yielded[1]
assert(manager.processor.func(key(0xffff, { shift = true }), env) == 1)
assert(actions[#actions][1] == "restore" and actions[#actions][3] == "aaaa")

assert(manager.processor.func(key(0xff08), env) == 1)
assert(context.input == "\\gl")
assert(manager.processor.func(key(0xff1b), env) == 1)
assert(context.input == "")

print("tiger user words manager tests passed")
