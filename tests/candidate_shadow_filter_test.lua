package.path = "./lua/?.lua;" .. package.path

local loaded, candidate_shadow_filter = pcall(require, "candidate_shadow_filter")
if not loaded then
  error("candidate shadow filter module should load: " .. tostring(candidate_shadow_filter), 0)
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
  end
end

local function candidate(kind, options)
  options = options or {}
  local cand = {
    type = options.type or "simplified",
    text = options.text or "",
    comment = options.comment or "",
    quality = options.quality or 0,
    genuine = options.genuine,
  }
  cand.get_dynamic_type = function()
    return kind
  end
  cand.get_genuine = function(self)
    return self.genuine or self
  end
  return cand
end

local function input_of(candidates)
  return {
    iter = function()
      local index = 0
      return function()
        index = index + 1
        return candidates[index]
      end
    end,
  }
end

local function apply_filter(candidates)
  local output = {}
  local previous_yield = yield
  yield = function(cand)
    output[#output + 1] = cand
  end
  candidate_shadow_filter.func(input_of(candidates))
  yield = previous_yield
  return output
end

ShadowCandidate = function(item, candidate_type, text, comment)
  return candidate("Shadow", {
    genuine = item,
    type = candidate_type,
    text = text,
    comment = comment,
    quality = item.quality,
  })
end

local function test_flattens_nested_shadow_candidates()
  local original = candidate("Phrase", {
    type = "table",
    text = "怎么",
    quality = 100,
  })
  local traditional = candidate("Shadow", {
    genuine = original,
    text = "怎麼",
    comment = "〔怎么〕",
    quality = 100,
  })
  local pinyin = candidate("Shadow", {
    genuine = traditional,
    text = "怎麼",
    comment = "zěnme",
    quality = 120,
  })

  local output = apply_filter({ pinyin })
  local flattened = output[1]

  assert_equal(#output, 1, "filter keeps candidate count")
  assert_equal(flattened:get_genuine(), original, "flattened shadow points to table candidate")
  assert_equal(flattened.text, "怎麼", "flattened shadow keeps displayed text")
  assert_equal(flattened.comment, "zěnme", "flattened shadow keeps displayed comment")
  assert_equal(flattened.quality, 120, "flattened shadow keeps outer quality")
end

local function test_keeps_single_shadow_candidate_unchanged()
  local original = candidate("Phrase", {
    type = "table",
    text = "怎么",
  })
  local shadow = candidate("Shadow", {
    genuine = original,
    text = "怎麼",
  })

  local output = apply_filter({ shadow })

  assert_equal(output[1], shadow, "single shadow is passed through")
end

test_flattens_nested_shadow_candidates()
test_keeps_single_shadow_candidate_unchanged()

print("candidate shadow filter tests passed")
