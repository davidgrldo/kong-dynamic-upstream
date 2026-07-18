local t = require "spec.test_helper"

local function fresh_rules(headers)
  package.loaded["kong.plugins.dynamic-upstream.rules"] = nil
  _G.kong = {
    request = {
      get_header = function(name) return (headers or {})[name] end,
    },
    log = { err = function() end },
  }
  -- Stand-in for ngx.re.find, enough for unit tests (plain find).
  _G.ngx = _G.ngx or {}
  _G.ngx.re = {
    find = function(subject, regex)
      local from, to = string.find(subject, regex)
      return from, to, nil
    end,
  }
  return require "kong.plugins.dynamic-upstream.rules"
end

t.test("matches a header by exact value", function()
  local rules = fresh_rules({ ["x-tenant"] = "bankxyz" })
  t.truthy(rules.match({ header = { name = "x-tenant", value = "bankxyz" } }))
  t.falsy(rules.match({ header = { name = "x-tenant", value = "other" } }))
end)

t.test("matches a header by regex", function()
  local rules = fresh_rules({ ["x-env"] = "sandbox-7" })
  t.truthy(rules.match({ header = { name = "x-env", regex = "^sandbox" } }))
  t.falsy(rules.match({ header = { name = "x-env", regex = "^prod" } }))
end)

t.test("matches on header presence when no value or regex", function()
  local rules = fresh_rules({ ["x-canary"] = "1" })
  t.truthy(rules.match({ header = { name = "x-canary" } }))
  t.falsy(rules.match({ header = { name = "x-other" } }))
end)

t.test("does not match a missing header or condition", function()
  local rules = fresh_rules({})
  t.falsy(rules.match({ header = { name = "x-tenant", value = "a" } }))
  t.falsy(rules.match({}))
  t.falsy(rules.match(nil))
end)

t.test("first matching rule wins, in order", function()
  local rules = fresh_rules({ ["x-tenant"] = "bankxyz", ["x-env"] = "sandbox" })
  local rule, index = rules.first_match({
    { condition = { header = { name = "x-none" } },
      target = { upstream = "a" } },
    { condition = { header = { name = "x-env", value = "sandbox" } },
      target = { upstream = "b" } },
    { condition = { header = { name = "x-tenant", value = "bankxyz" } },
      target = { upstream = "c" } },
  })
  t.equal(index, 2)
  t.equal(rule.target.upstream, "b")
end)

t.test("no rules means no match", function()
  local rules = fresh_rules({})
  t.falsy(rules.first_match({}))
  t.falsy(rules.first_match(nil))
end)

return t
