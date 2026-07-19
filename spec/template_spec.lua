local t = require "spec.test_helper"

local function fresh_template(mock)
  package.loaded["kong.plugins.dynamic-upstream.template"] = nil
  _G.kong = {
    request = {
      get_path = function() return mock.path or "/orders/1" end,
      get_header = function(name) return (mock.headers or {})[name] end,
      get_query_arg = function(name) return (mock.query or {})[name] end,
    },
    client = {
      get_consumer = function() return mock.consumer end,
    },
  }
  return require "kong.plugins.dynamic-upstream.template"
end

-- vars_in / is_client_controlled / host_is_dynamic ---------------------------

t.test("extracts variables from a template", function()
  local template = fresh_template({})
  local vars = template.vars_in("https://$(header.x-region).internal$(uri)")
  t.equal(#vars, 2)
  t.equal(vars[1], "header.x-region")
  t.equal(vars[2], "uri")
end)

t.test("classifies client-controlled namespaces", function()
  local template = fresh_template({})
  t.truthy(template.is_client_controlled("header.x-tenant"))
  t.truthy(template.is_client_controlled("query.env"))
  t.truthy(template.is_client_controlled("uri"))
  t.falsy(template.is_client_controlled("consumer.username"))
end)

t.test("detects a variable in the host portion", function()
  local template = fresh_template({})
  t.truthy(template.host_is_dynamic("https://$(header.x-r).svc:8443/api"))
  t.truthy(template.host_is_dynamic("http://$(consumer.username).internal"))
  t.falsy(template.host_is_dynamic("https://static.internal$(uri)"))
  t.falsy(template.host_is_dynamic("https://static.internal/v1?x=$(query.x)"))
  t.falsy(template.host_is_dynamic("https://static.internal?x=$(query.x)"))
end)

-- substitute ------------------------------------------------------------------

t.test("substitutes all supported variables", function()
  local template = fresh_template({
    path = "/v1/orders",
    headers = { ["x-region"] = "jkt" },
    query = { env = "sandbox" },
    consumer = { username = "bankxyz", custom_id = "c-42" },
  })
  local out = template.substitute(
    "https://$(header.x-region).internal$(uri)?env=$(query.env)&p=$(consumer.username)")
  t.equal(out, "https://jkt.internal/v1/orders?env=sandbox&p=bankxyz")
end)

t.test("fails closed on an unresolved variable", function()
  local template = fresh_template({ headers = {} })
  local out, err = template.substitute("https://$(header.x-missing).internal")
  t.falsy(out)
  t.equal(err, "unresolved variable: $(header.x-missing)")
end)

t.test("treats an empty header value as unresolved", function()
  local template = fresh_template({ headers = { ["x-region"] = "" } })
  local out = template.substitute("https://$(header.x-region).internal")
  t.falsy(out)
end)

t.test("uses the first value of a repeated header", function()
  local template = fresh_template({ headers = { ["x-r"] = { "a", "b" } } })
  t.equal(template.substitute("https://$(header.x-r).internal"),
          "https://a.internal")
end)

-- parse_url -------------------------------------------------------------------

t.test("parses scheme, host, port and path", function()
  local template = fresh_template({})
  local u = template.parse_url("https://api.internal:8443/v1/orders")
  t.equal(u.scheme, "https")
  t.equal(u.host, "api.internal")
  t.equal(u.port, 8443)
  t.equal(u.path, "/v1/orders")
end)

t.test("defaults ports by scheme and path to nil", function()
  local template = fresh_template({})
  t.equal(template.parse_url("http://a.internal").port, 80)
  t.equal(template.parse_url("https://a.internal").port, 443)
  t.equal(template.parse_url("https://a.internal").path, nil)
end)

t.test("accepts underscores in hostnames", function()
  local template = fresh_template({})
  t.equal(template.parse_url("http://snake_case.internal/x").host,
          "snake_case.internal")
end)

t.test("splits the query string off the path", function()
  local template = fresh_template({})
  local u = template.parse_url("https://a.internal:8443/v1/orders?env=sbx&p=1")
  t.equal(u.path, "/v1/orders")
  t.equal(u.query, "env=sbx&p=1")
  local q = template.parse_url("https://a.internal?x=1")
  t.equal(q.host, "a.internal")
  t.equal(q.path, nil)
  t.equal(q.query, "x=1")
  t.equal(template.parse_url("https://a.internal/v1").query, nil)
end)

t.test("rejects userinfo, whitespace, fragments and bad schemes", function()
  local template = fresh_template({})
  t.falsy(template.parse_url("https://evil@a.internal/"))
  t.falsy(template.parse_url("https://a.internal/ /x"))
  t.falsy(template.parse_url("https://a.internal/x#frag"))
  t.falsy(template.parse_url("ftp://a.internal/"))
  t.falsy(template.parse_url("https://:8080/x"))
end)

-- host_allowed ------------------------------------------------------------------

t.test("allowlist matches exact and wildcard patterns", function()
  local template = fresh_template({})
  local allowed = { "api.internal", "*.svc.cluster.local" }
  t.truthy(template.host_allowed("api.internal", allowed))
  t.truthy(template.host_allowed("API.INTERNAL", allowed))
  t.truthy(template.host_allowed("orders.svc.cluster.local", allowed))
  t.falsy(template.host_allowed("svc.cluster.local", allowed)) -- no bare suffix
  t.falsy(template.host_allowed("evil.com", allowed))
  t.falsy(template.host_allowed("api.internal.evil.com", allowed))
end)

t.test("empty allowlist denies everything", function()
  local template = fresh_template({})
  t.falsy(template.host_allowed("api.internal", {}))
  t.falsy(template.host_allowed("api.internal", nil))
end)

return t
