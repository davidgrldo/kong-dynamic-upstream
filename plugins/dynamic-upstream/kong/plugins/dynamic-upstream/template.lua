-- Variable substitution and target-URL handling for dynamic-upstream.
--
-- Supported variables (v1 — deliberately not a full expression language):
--   $(uri)                 request path, no query string
--   $(header.NAME)         request header value
--   $(query.NAME)          query-string argument (first value if repeated)
--   $(consumer.username)   authenticated consumer username
--   $(consumer.custom_id)  authenticated consumer custom_id
--
-- `uri`, `header.*` and `query.*` are CLIENT-CONTROLLED: when any of them
-- appears in the authority (host) portion of a target URL template, the
-- resolved host MUST pass the allowed_hosts allowlist (SSRF guard).

local M = {}

local VAR_PATTERN = "%$%(([%w_%-%.]+)%)"

local CLIENT_CONTROLLED_NS = { uri = true, header = true, query = true }

function M.vars_in(template)
  local vars = {}
  for var in template:gmatch(VAR_PATTERN) do
    vars[#vars + 1] = var
  end
  return vars
end

function M.is_client_controlled(var)
  local ns = var:match("^([^.]+)")
  return CLIENT_CONTROLLED_NS[ns] == true
end

-- The authority (host[:port]) portion of a URL template: everything after
-- the scheme up to the first "/" or "?" — or up to a literal "$(uri)"
-- token, since $(uri) always expands with a leading "/" and therefore
-- starts the path. nil when the template has no scheme.
function M.authority_of(url_template)
  local rest = url_template:match("^[a-zA-Z][%w+.-]*://(.*)$")
  if not rest then
    return nil
  end
  local slash = rest:find("/", 1, true)
  local qmark = rest:find("?", 1, true)
  local uri_tok = rest:find("$(uri)", 1, true)
  local stop = math.min(slash or math.huge, qmark or math.huge,
                        uri_tok or math.huge)
  return (stop == math.huge) and rest or rest:sub(1, stop - 1)
end

-- True when the authority of the URL template contains a variable. Such
-- templates require allowed_hosts AND a literal :port (so a header value
-- cannot pick the port on an allowlisted host).
function M.host_is_dynamic(url_template)
  local authority = M.authority_of(url_template)
  return authority ~= nil and authority:find("%$%(") ~= nil
end

local function resolve(var)
  if var == "uri" then
    return kong.request.get_path()
  end
  local ns, name = var:match("^([^.]+)%.(.+)$")
  if ns == "header" then
    local v = kong.request.get_header(name)
    if type(v) == "table" then v = v[1] end
    return v
  elseif ns == "query" then
    local v = kong.request.get_query_arg(name)
    if type(v) == "table" then v = v[1] end
    return v
  elseif ns == "consumer" then
    local consumer = kong.client.get_consumer()
    if consumer and (name == "username" or name == "custom_id") then
      return consumer[name]
    end
  end
  return nil
end

-- Substitute all variables. Fails closed: any unresolved variable is an
-- error, never silently replaced with an empty string (an empty host or
-- path segment could route somewhere unintended).
function M.substitute(template)
  local missing
  local out = template:gsub(VAR_PATTERN, function(var)
    local value = resolve(var)
    if value == nil or value == "" then
      missing = missing or var
      return ""
    end
    return value
  end)
  if missing then
    return nil, "unresolved variable: $(" .. missing .. ")"
  end
  return out
end

-- Parse "http(s)://host[:port][/path][?query]". Returns
-- { scheme, host, port, path, query } — path and query kept separate
-- because the PDK sets them separately (set_path must not contain "?").
-- Rejects userinfo (@), whitespace, fragments (#) and anything that is
-- not http/https.
function M.parse_url(url)
  if url:find("[@%s#]") then
    return nil, "invalid target url"
  end
  local scheme, rest = url:match("^(https?)://(.+)$")
  if not scheme then
    return nil, "target url must start with http:// or https://"
  end
  local query
  rest, query = rest:match("^([^?]*)%??(.*)$")
  if query == "" then
    query = nil
  end
  local authority, path = rest:match("^([^/]+)(/.*)$")
  if not authority then
    authority, path = rest, nil
  end
  local host, port = authority:match("^([^:]+):(%d+)$")
  if not host then
    host, port = authority, nil
  end
  if host == "" or host:find("[^%w%._%-]") then
    return nil, "invalid target host"
  end
  port = tonumber(port) or (scheme == "https" and 443 or 80)
  if port < 1 or port > 65535 then
    return nil, "invalid target port"
  end
  return { scheme = scheme, host = host, port = port,
           path = path, query = query }
end

-- Allowlist match. Supported patterns:
--   "api.internal"   exact, case-insensitive
--   "*.internal"     any subdomain of .internal (at least one label)
function M.host_allowed(host, allowed)
  if type(allowed) ~= "table" or #allowed == 0 then
    return false
  end
  host = host:lower()
  for _, pattern in ipairs(allowed) do
    pattern = pattern:lower()
    if pattern:sub(1, 2) == "*." then
      local suffix = pattern:sub(2) -- ".internal"
      if #host > #suffix and host:sub(-#suffix) == suffix then
        return true
      end
    elseif host == pattern then
      return true
    end
  end
  return false
end

return M
