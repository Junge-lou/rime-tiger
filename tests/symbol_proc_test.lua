package.path = "./lua/?.lua;" .. package.path

rime_api = {
  regex_match = function(text)
    return text:match("[^0-9A-Za-z%s]") ~= nil
  end,
}

local symbol_proc = require("symbol_proc")

local kAccepted = 1
local kNoop = 2

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
  end
end

local function key_event(repr, options)
  options = options or {}
  local keycodes = {
    semicolon = string.byte(";"),
    apostrophe = string.byte("'"),
  }
  return {
    keycode = keycodes[repr] or options.keycode or 0,
    repr = function()
      return repr
    end,
    release = function()
      return options.release or false
    end,
    alt = function()
      return options.alt or false
    end,
    ctrl = function()
      return options.ctrl or false
    end,
    shift = function()
      return options.shift or false
    end,
    caps = function()
      return options.caps or false
    end,
  }
end

local function candidate(text, candidate_type)
  return {
    text = text,
    type = candidate_type or "table",
  }
end

local function runtime(options)
  options = options or {}
  local candidates = options.candidates or {}
  local state = {
    confirmed = false,
    selected = nil,
  }
  local menu = {
    prepare = function(_, count)
      return math.min(count, #candidates)
    end,
    get_candidate_at = function(_, index)
      return candidates[index + 1]
    end,
  }
  local segment = {
    menu = menu,
    selected_index = options.selected_index or 0,
  }
  local composition = {
    empty = function()
      return false
    end,
    back = function()
      return segment
    end,
  }
  local context = {
    composition = composition,
    input = options.input or "abcd",
    has_menu = function()
      return true
    end,
    select = function(_, index)
      state.selected = index
      segment.selected_index = index
    end,
    confirm_current_selection = function()
      state.confirmed = true
    end,
  }
  local config = {
    get_bool = function(_, path)
      assert_equal(path, "smart_candidate_selection/enabled", "processor reads the documented setting")
      return options.enabled
    end,
  }
  local env = {
    engine = {
      context = context,
      schema = {
        config = config,
        page_size = options.page_size or 9,
      },
    },
  }
  return env, state
end

local function process(options, repr, key_options)
  local env, state = runtime(options)
  symbol_proc.init(env)
  local result = symbol_proc.func(key_event(repr, key_options), env)
  return result, state
end

local function test_semicolon_skips_association_for_second_text_candidate()
  local result, state = process({
    candidates = {
      candidate("甲"),
      candidate("😀", "simplified"),
      candidate("乙"),
    },
  }, "semicolon")

  assert_equal(result, kAccepted, "semicolon consumes smart selection")
  assert_equal(state.selected, 2, "semicolon selects the second text candidate")
end

local function test_apostrophe_skips_associations_for_third_text_candidate()
  local result, state = process({
    candidates = {
      candidate("甲"),
      candidate("😀", "simplified"),
      candidate("乙"),
      candidate("✓", "simplified"),
      candidate("丙"),
    },
  }, "apostrophe")

  assert_equal(result, kAccepted, "apostrophe consumes smart selection")
  assert_equal(state.selected, 4, "apostrophe selects the third text candidate")
end

local function test_simplified_keycap_digit_is_skipped()
  local result, state = process({
    candidates = {
      candidate("甲"),
      candidate("1️⃣", "simplified"),
      candidate("乙"),
    },
  }, "semicolon")

  assert_equal(result, kAccepted, "keycap association is bypassed")
  assert_equal(state.selected, 2, "keycap association does not consume second choice")
end

local function test_normal_ascii_digit_counts_as_text_candidate()
  local result, state = process({
    candidates = {
      candidate("甲"),
      candidate("2", "table"),
      candidate("乙"),
    },
  }, "semicolon")

  assert_equal(result, kAccepted, "normal digit can be selected")
  assert_equal(state.selected, 1, "normal digit remains the second text candidate")
end

local function test_extension_han_counts_as_text_candidate()
  local result, state = process({
    candidates = {
      candidate("甲"),
      candidate("😀", "simplified"),
      candidate("𠀀"),
    },
  }, "semicolon")

  assert_equal(result, kAccepted, "extension Han candidate can be selected")
  assert_equal(state.selected, 2, "extension Han remains a text candidate")
end

local function test_insufficient_text_candidates_commits_first_and_passes_key()
  local result, state = process({
    candidates = {
      candidate("甲"),
      candidate("😀", "simplified"),
      candidate("✓", "simplified"),
    },
  }, "semicolon")

  assert_equal(result, kNoop, "punctuation continues after unique text candidate")
  assert_equal(state.selected, 0, "first text candidate is selected before commit")
  assert_equal(state.confirmed, true, "first text candidate is committed")
end

local function test_disabled_setting_preserves_positional_binding()
  local result, state = process({
    enabled = false,
    candidates = {
      candidate("甲"),
      candidate("😀", "simplified"),
      candidate("乙"),
    },
  }, "semicolon")

  assert_equal(result, kNoop, "disabled smart selection passes to key_binder")
  assert_equal(state.selected, nil, "disabled smart selection does not select directly")
  assert_equal(state.confirmed, false, "disabled smart selection keeps current behavior")
end

local function assert_bypasses_smart_selection(input, selected_index, repr, key_options, label)
  local result, state = process({
    input = input,
    selected_index = selected_index,
    candidates = {
      candidate("甲"),
      candidate("😀", "simplified"),
      candidate("乙"),
      candidate("丙"),
      candidate("丁"),
      candidate("戊"),
      candidate("己"),
      candidate("庚"),
      candidate("辛"),
      candidate("壬"),
      candidate("癸"),
    },
  }, repr or "semicolon", key_options)

  assert_equal(result, kNoop, label .. " passes to existing processors")
  assert_equal(state.selected, nil, label .. " does not select directly")
  assert_equal(state.confirmed, false, label .. " does not commit directly")
end

local function test_compatibility_paths_bypass_smart_selection()
  assert_bypasses_smart_selection("\\bq", 0, "semicolon", nil, "backslash symbol menu")
  assert_bypasses_smart_selection(";bq", 0, "semicolon", nil, "semicolon quick-symbol input")
  assert_bypasses_smart_selection("abcd", 9, "semicolon", nil, "later candidate page")
  assert_bypasses_smart_selection("abcd", 0, "semicolon", { shift = true }, "shifted semicolon")
end

local tests = {
  test_semicolon_skips_association_for_second_text_candidate,
  test_apostrophe_skips_associations_for_third_text_candidate,
  test_simplified_keycap_digit_is_skipped,
  test_normal_ascii_digit_counts_as_text_candidate,
  test_extension_han_counts_as_text_candidate,
  test_insufficient_text_candidates_commits_first_and_passes_key,
  test_disabled_setting_preserves_positional_binding,
  test_compatibility_paths_bypass_smart_selection,
}

for _, test in ipairs(tests) do
  test()
end

print("symbol_proc tests passed")
