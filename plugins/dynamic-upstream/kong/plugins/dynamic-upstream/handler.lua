local rules = require "kong.plugins.dynamic-upstream.rules"
local template = require "kong.plugins.dynamic-upstream.template"

-- PRIORITY 750. Higher priority runs earlier in a phase, so this runs
-- AFTER authentication plugins (~1000+, ensuring $(consumer.*) is
-- populated) and AFTER request-transformer (801, so header rewrites have
-- settled before rules are evaluated).
local Handler = { VERSION = "0.2.0", PRIORITY = 750 }

local function fail(status, message)
  return kong.response.exit(status, { message = message })
end

local function apply_url_target(config, target)
  local url, err = template.substitute(target.url)
  if not url then
    kong.log.err("dynamic-upstream: ", err)
    return fail(503, "Upstream resolution failed")
  end

  local parsed, perr = template.parse_url(url)
  if not parsed then
    kong.log.err("dynamic-upstream: ", perr, " (resolved from template)")
    return fail(503, "Upstream resolution failed")
  end

  -- SSRF guard: a host assembled from client-controlled input must be on
  -- the allowlist. A literal host in config is operator-controlled and
  -- therefore trusted as-is.
  if template.host_is_dynamic(target.url)
     and not template.host_allowed(parsed.host, config.allowed_hosts) then
    kong.log.warn("dynamic-upstream: resolved host not in allowed_hosts: ",
                  parsed.host)
    return fail(403, "Upstream host not allowed")
  end

  kong.service.request.set_scheme(parsed.scheme)
  kong.service.set_target(parsed.host, parsed.port)
  if parsed.path then
    kong.service.request.set_path(parsed.path)
  end
  if parsed.query then
    -- A query string in the template replaces the client's query;
    -- without one, the client's query passes through untouched.
    kong.service.request.set_raw_query(parsed.query)
  end
  -- set_target() also overwrites ngx.var.upstream_host with the bare
  -- target host, and nginx derives both the upstream Host header AND the
  -- TLS SNI from that variable (proxy_ssl_name $upstream_host). So the
  -- Host must be set explicitly on BOTH branches: restored to the
  -- client's value for preserve_host, or rewritten to host[:port] for
  -- the target. SNI follows whichever host is chosen.
  if target.preserve_host == false then
    local default_port = parsed.scheme == "https" and 443 or 80
    local host_header = parsed.host
    if parsed.port ~= default_port then
      host_header = host_header .. ":" .. parsed.port
    end
    kong.service.request.set_header("Host", host_header)
  else
    local client_host = kong.request.get_header("Host")
                        or kong.request.get_host()
    kong.service.request.set_header("Host", client_host)
  end
end

function Handler:access(config)
  local rule = rules.first_match(config.rules)
  if not rule then
    if config.on_no_match == "reject_503" then
      return fail(503, "No upstream rule matched")
    end
    return -- passthrough: the route's configured service handles it
  end

  local target = rule.target
  if target.upstream and target.upstream ~= "" then
    local ok, err = kong.service.set_upstream(target.upstream)
    if not ok then
      kong.log.err("dynamic-upstream: set_upstream failed: ", err)
      return fail(503, "Upstream resolution failed")
    end
    return
  end

  return apply_url_target(config, target)
end

return Handler
