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

    if has_upstream and t.preserve_host ~= nil and t.preserve_host ~= ngx.null then
      return nil, where .. "preserve_host only applies to url targets"
    end

    if has_url then
      local ok, err = validate_url_template(t.url)
      if not ok then
        return nil, where .. err
      end
      -- SNI follows whichever Host preserve_host selects, so for https
      -- targets the choice must be conscious, not a default.
      if t.url:match("^https://")
         and (t.preserve_host == nil or t.preserve_host == ngx.null) then
        return nil, where .. "https target url requires an explicit "
          .. "preserve_host (upstream SNI follows the chosen Host)"
      end
      -- SSRF guard, enforced at config time: a client-influenced host is
      -- only accepted together with a non-empty allowlist, and the port
      -- must be pinned in the template so a header value cannot pick it.
      if template.host_is_dynamic(t.url) then
        if #(config.allowed_hosts or {}) == 0 then
          return nil, where .. "target url has a variable in the host; "
            .. "allowed_hosts must be set"
        end
        if not template.authority_of(t.url):find(":%d+$") then
          return nil, where .. "target url has a variable in the host; "
            .. "a literal :port is required"
        end
      end
    end
  end
  return true
end

local function validate_allowed_host(v)
  if v:match("^%*%.[%w_][%w%._%-]*$") or v:match("^[%w_][%w%._%-]*$") then
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
                        -- no default: the cross-field validator must see
                        -- whether the operator set it (https requires an
                        -- explicit choice). The handler treats nil as true.
                        { preserve_host = { type = "boolean" } },
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
