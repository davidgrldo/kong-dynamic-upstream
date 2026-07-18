local typedefs = require "kong.db.schema.typedefs"
local template = require "kong.plugins.dynamic-upstream.template"

local function missing(v)
  return v == nil or v == ngx.null or v == ""
end

local ALLOWED_VAR_NS = {
  uri = true, header = true, query = true, consumer = true,
}

local function validate_url_template(url)
  if not url:match("^https?://") then
    return nil, "target url must start with http:// or https://"
  end
  for _, var in ipairs(template.vars_in(url)) do
    local ns, name = var:match("^([^.]+)%.?(.*)$")
    if not ALLOWED_VAR_NS[ns] then
      return nil, "unknown variable namespace: $(" .. var .. ")"
    end
    if ns == "consumer" and name ~= "username" and name ~= "custom_id" then
      return nil, "unsupported consumer variable: $(" .. var .. ")"
    end
    if (ns == "header" or ns == "query") and name == "" then
      return nil, "variable needs a name: $(" .. var .. ")"
    end
  end
  return true
end

local function validate(config)
  if #(config.rules or {}) == 0 then
    return nil, "at least one rule is required"
  end

  for i, rule in ipairs(config.rules) do
    local where = "rule #" .. i .. ": "
    local h = rule.condition and rule.condition.header
    if not h or missing(h.name) then
      return nil, where .. "condition.header.name is required"
    end
    if not missing(h.value) and not missing(h.regex) then
      return nil, where .. "set header value or regex, not both"
    end

    local t = rule.target or {}
    local has_upstream = not missing(t.upstream)
    local has_url = not missing(t.url)
    if has_upstream == has_url then
      return nil, where .. "target needs exactly one of upstream or url"
    end

    if has_url then
      local ok, err = validate_url_template(t.url)
      if not ok then
        return nil, where .. err
      end
      -- SSRF guard, enforced at config time: a client-influenced host is
      -- only accepted together with a non-empty allowlist.
      if template.host_is_dynamic(t.url)
         and #(config.allowed_hosts or {}) == 0 then
        return nil, where .. "target url has a variable in the host; "
          .. "allowed_hosts must be set"
      end
    end
  end
  return true
end

local function validate_allowed_host(v)
  if v:match("^%*%.[%w][%w%.%-]*$") or v:match("^[%w][%w%.%-]*$") then
    return true
  end
  return nil, "allowed_hosts entries must be a hostname or *.suffix pattern"
end

return {
  name = "dynamic-upstream",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { rules = {
              type = "array",
              required = true,
              elements = {
                type = "record",
                fields = {
                  { condition = {
                      type = "record",
                      fields = {
                        { header = {
                            type = "record",
                            fields = {
                              { name = { type = "string", required = true } },
                              { value = { type = "string" } },
                              { regex = { type = "string" } },
                            },
                        } },
                      },
                  } },
                  { target = {
                      type = "record",
                      fields = {
                        { upstream = { type = "string" } },
                        { url = { type = "string" } },
                        { preserve_host = { type = "boolean", default = true } },
                      },
                  } },
                },
              },
          } },
          { allowed_hosts = {
              type = "array",
              default = {},
              elements = { type = "string",
                           custom_validator = validate_allowed_host },
          } },
          { on_no_match = {
              type = "string",
              default = "passthrough",
              one_of = { "passthrough", "reject_503" },
          } },
        },
        custom_validator = validate,
    } },
  },
}
