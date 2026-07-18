-- Rule evaluation for dynamic-upstream. Rules are evaluated in config order;
-- the FIRST matching rule wins.

local M = {}

-- A header condition matches when the header is present and:
--   value  set -> exact string equality
--   regex  set -> ngx.re (PCRE) match with JIT + pattern cache ("jo")
--   neither    -> presence check
function M.match(condition)
  local h = condition and condition.header
  if not h then
    return false
  end
  local actual = kong.request.get_header(h.name)
  if type(actual) == "table" then
    actual = actual[1]
  end
  if type(actual) ~= "string" then
    return false
  end
  if h.value ~= nil then
    return actual == h.value
  end
  if h.regex ~= nil then
    local from, _, err = ngx.re.find(actual, h.regex, "jo")
    if err then
      kong.log.err("dynamic-upstream: bad regex in rule: ", err)
      return false
    end
    return from ~= nil
  end
  return true
end

function M.first_match(rules)
  for i, rule in ipairs(rules or {}) do
    if M.match(rule.condition) then
      return rule, i
    end
  end
  return nil
end

return M
