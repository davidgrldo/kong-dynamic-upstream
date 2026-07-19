local t = require "spec.test_helper"

-- The schema pulls in Kong typedefs and ngx.null; stub both so the
-- cross-field validator can run under plain Lua.
package.loaded["kong.db.schema.typedefs"] = {
  no_consumer = { type = "foreign" },
  protocols_http = { type = "set" },
}
_G.ngx = _G.ngx or {}
_G.ngx.null = _G.ngx.null or {}

local schema = require "kong.plugins.dynamic-upstream.schema"

local validate, allowed_host_validator
for _, f in ipairs(schema.fields) do
  if f.config then
    validate = f.config.custom_validator
    for _, cf in ipairs(f.config.fields) do
      if cf.allowed_hosts then
        allowed_host_validator = cf.allowed_hosts.elements.custom_validator
      end
    end
  end
end

local function rule(condition, target)
  return { condition = { header = condition }, target = target }
end

t.test("accepts a valid config with both target modes", function()
  t.truthy(validate({ rules = {
    rule({ name = "x-tenant", value = "bankxyz" }, { upstream = "cluster-a" }),
    rule({ name = "x-env", regex = "^sandbox" },
         { url = "https://sandbox.internal:8443$(uri)",
           preserve_host = false }),
  } }))
end)

t.test("rejects an empty rule list", function()
  local ok, err = validate({ rules = {} })
  t.falsy(ok)
  t.equal(err, "at least one rule is required")
end)

t.test("rejects a rule without a header name", function()
  t.falsy(validate({ rules = { rule(nil, { upstream = "a" }) } }))
  t.falsy(validate({ rules = { rule({ name = ngx.null }, { upstream = "a" }) } }))
end)

t.test("rejects value and regex together", function()
  local ok, err = validate({ rules = {
    rule({ name = "x", value = "a", regex = "^a" }, { upstream = "a" }),
  } })
  t.falsy(ok)
  t.truthy(err:find("not both"))
end)

t.test("requires exactly one of upstream or url", function()
  t.falsy(validate({ rules = { rule({ name = "x" }, {}) } }))
  t.falsy(validate({ rules = {
    rule({ name = "x" }, { upstream = "a", url = "https://b.internal" }),
  } }))
end)

t.test("rejects unknown or malformed variables", function()
  t.falsy(validate({ rules = {
    rule({ name = "x" }, { url = "https://a.internal/$(magic.beans)" }),
  } }))
  t.falsy(validate({ rules = {
    rule({ name = "x" }, { url = "https://a.internal/$(consumer.email)" }),
  } }))
  t.falsy(validate({ rules = {
    rule({ name = "x" }, { url = "https://a.internal/$(header)" }),
  } }))
end)

t.test("rejects a templated host without allowed_hosts", function()
  local dyn = rule({ name = "x-region" },
                   { url = "https://$(header.x-region).internal:8443$(uri)",
                     preserve_host = false })
  local ok, err = validate({ rules = { dyn } })
  t.falsy(ok)
  t.truthy(err:find("allowed_hosts"))
  t.truthy(validate({ rules = { dyn }, allowed_hosts = { "*.internal" } }))
end)

t.test("rejects a templated host without a literal port", function()
  local ok, err = validate({
    rules = { rule({ name = "x-region" },
                   { url = "http://$(header.x-region).internal$(uri)" }) },
    allowed_hosts = { "*.internal" },
  })
  t.falsy(ok)
  t.truthy(err:find("literal :port"))
end)

t.test("rejects an https url without an explicit preserve_host", function()
  local ok, err = validate({ rules = {
    rule({ name = "x" }, { url = "https://static.internal:8443$(uri)" }),
  } })
  t.falsy(ok)
  t.truthy(err:find("preserve_host"))
  t.truthy(validate({ rules = {
    rule({ name = "x" }, { url = "https://static.internal:8443$(uri)",
                           preserve_host = true }),
  } }))
end)

t.test("rejects preserve_host on an upstream target", function()
  local ok, err = validate({ rules = {
    rule({ name = "x" }, { upstream = "a", preserve_host = false }),
  } })
  t.falsy(ok)
  t.truthy(err:find("only applies to url targets"))
end)

t.test("a static host with path/query variables needs no allowlist", function()
  t.truthy(validate({ rules = {
    rule({ name = "x" }, { url = "http://static.internal$(uri)" }),
    rule({ name = "y" }, { url = "http://static.internal/v1?x=$(query.x)" }),
  } }))
end)

t.test("validates allowed_hosts entries", function()
  t.truthy(allowed_host_validator("api.internal"))
  t.truthy(allowed_host_validator("*.svc.cluster.local"))
  t.truthy(allowed_host_validator("snake_case.internal"))
  t.falsy(allowed_host_validator("*"))
  t.falsy(allowed_host_validator("*."))
  t.falsy(allowed_host_validator("evil/host"))
end)

return t
