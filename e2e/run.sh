#!/usr/bin/env bash
# e2e harness: Kong 3.9 DB-less + echo upstreams (docker compose).
# Asserts routing, SSRF allowlist 403, fail-closed 503, preserve_host,
# query handling and TLS/SNI. Requires docker + jq.
#
#   ./run.sh          run everything, tear down after
#   KEEP=1 ./run.sh   leave the stack running for inspection
set -u
cd "$(dirname "$0")"

PROXY=http://localhost:18000
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "ok    $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

# assert_json <name> <jq filter> <expected> -- <curl args...>
assert_json() {
  local name=$1 filter=$2 expected=$3
  shift 4
  local body actual
  body=$(curl -s "$@")
  actual=$(jq -r "$filter" <<<"$body" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    ok "$name"
  else
    fail "$name (expected '$expected', got '$actual')"
  fi
}

# assert_status <name> <expected> -- <curl args...>
assert_status() {
  local name=$1 expected=$2
  shift 3
  local actual
  actual=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$actual" = "$expected" ]; then
    ok "$name"
  else
    fail "$name (expected HTTP $expected, got $actual)"
  fi
}

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v docker >/dev/null || { echo "docker is required"; exit 1; }

docker compose up -d --quiet-pull 2>&1 | grep -v '^\s*$' || true

cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    docker compose down -v >/dev/null 2>&1
  else
    echo "(KEEP=1: stack left running; docker compose down -v to stop)"
  fi
}
trap cleanup EXIT

printf 'waiting for kong'
up=0
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/api/ping" 2>/dev/null || true)
  if [ "$code" = "200" ]; then up=1; break; fi
  printf .; sleep 1
done
echo
if [ "$up" != "1" ]; then
  echo "kong never became ready; logs:"
  docker compose logs --tail 60 kong
  exit 1
fi

# --- no match ----------------------------------------------------------------
assert_json "no match passes through to the route's service" \
  '.os.hostname' echo-default -- "$PROXY/api/ping"
assert_status "on_no_match=reject_503 rejects" 503 -- "$PROXY/strict/x"

# --- upstream entity mode ------------------------------------------------------
assert_json "upstream entity target routes via the Kong Upstream" \
  '.os.hostname' echo-a -- -H "X-Tenant: bankxyz" "$PROXY/api/ping"

# --- literal url + preserve_host=false ----------------------------------------
SBX=(-H "X-Env: sandbox-1" "$PROXY/api/orders?a=1")
assert_json "regex rule routes to the literal url target" \
  '.os.hostname' echo-b -- "${SBX[@]}"
assert_json "full client path is forwarded via \$(uri)" \
  '.path' /api/orders -- "${SBX[@]}"
assert_json "preserve_host=false rewrites Host to host:port" \
  '.headers.host' echo-b.internal:8080 -- "${SBX[@]}"
assert_json "client query string is preserved" \
  '.query.a' 1 -- "${SBX[@]}"

# --- template query ------------------------------------------------------------
QR=(-H "X-Query-Replace: 1" "$PROXY/api/x?a=1")
assert_json "template path overrides client path" '.path' /fixed -- "${QR[@]}"
assert_json "template query is applied" '.query.src' gateway -- "${QR[@]}"
assert_json "template query replaces the client query" \
  '.query.a // "absent"' absent -- "${QR[@]}"

# --- fail closed ---------------------------------------------------------------
assert_status "unresolved variable fails closed with 503" 503 -- \
  -H "X-Fail-Var: 1" "$PROXY/api/x"
assert_json "resolved query variable routes" '.path' /p/ok -- \
  -H "X-Fail-Var: 1" "$PROXY/api/x?q=ok"

# --- SSRF allowlist ------------------------------------------------------------
assert_json "templated host on the allowlist routes" \
  '.os.hostname' echo-a -- -H "X-Region: echo-a.internal" "$PROXY/api/ping"
assert_status "host off the allowlist gets 403" 403 -- \
  -H "X-Region: evil.com" "$PROXY/api/ping"

# --- preserve_host default -----------------------------------------------------
assert_json "preserve_host default keeps the client Host" \
  '.headers.host' localhost:18000 -- -H "X-Keep-Host: 1" "$PROXY/api/ping"

# --- TLS / SNI -----------------------------------------------------------------
# connection.servername is only present when the upstream hop was TLS, so it
# proves both the handshake and the SNI value. (.protocol can't be used: the
# echo server trusts X-Forwarded-Proto and reports the CLIENT protocol.)
TLS=(-H "X-TLS: 1" "$PROXY/api/ping")
assert_json "http target does no TLS handshake" \
  '.connection.servername // "none"' none -- "${SBX[@]}"
assert_json "https target handshakes with SNI = target host" \
  '.connection.servername' echo-b.internal -- "${TLS[@]}"
assert_json "https Host rewritten with non-default port" \
  '.headers.host' echo-b.internal:8443 -- "${TLS[@]}"
assert_json "SNI follows the client Host when preserve_host" \
  '.connection.servername' localhost -- -H "X-TLS-Preserve: 1" "$PROXY/api/ping"

# --------------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "--- kong logs (tail) ---"
  docker compose logs --tail 40 kong
  exit 1
fi
