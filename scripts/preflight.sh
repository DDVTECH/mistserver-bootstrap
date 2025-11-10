#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[preflight] %s\n' "$*"; }
warn() { printf '[preflight][warn] %s\n' "$*" >&2; }
fail() { printf '[preflight][error] %s\n' "$*" >&2; exit 1; }

enable_caddy="${ENABLE_CADDY:-false}"
skip_domain_check="${SKIP_DOMAIN_DNS_CHECK:-false}"
skip_domain_ip_match="${SKIP_DOMAIN_IP_MATCH:-false}"
skip_port_check="${SKIP_PORT_CHECK:-false}"
skip_port_selftest="${SKIP_PORT_SELFTEST:-false}"

# Load .env if present so we validate the same values docker compose will use.
if [ -f "${ROOT_DIR}/.env" ]; then
  log "Loading environment overrides from .env"
  set -a
  # shellcheck disable=SC1090
  . "${ROOT_DIR}/.env"
  set +a
fi

domain_raw="${DOMAIN:-}"
domain_ips=""
sanitize_domain() {
  local dom="$1"
  dom="${dom#http://}"
  dom="${dom#https://}"
  dom="${dom%%/*}"
  # Strip :port if supplied
  dom="${dom%%:*}"
  printf '%s' "${dom}"
}

domain_clean="$(sanitize_domain "${domain_raw}")"
if [ -n "${domain_raw}" ]; then
  log "DOMAIN provided: '${domain_raw}' (sanitized -> '${domain_clean}')"
else
  log "DOMAIN not set; skipping DNS/hostname validation."
fi

if [ -n "${domain_clean}" ]; then
  if ! [[ "${domain_clean}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    fail "DOMAIN must only contain letters, digits, dots, and dashes (got '${domain_clean}')"
  fi
fi

resolve_domain_ips() {
  local dom="$1"
  local resolver=""
  local ips=""
  local tmp=""

  if command -v getent >/dev/null 2>&1; then
    tmp="$(getent ahosts "${dom}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    if [ -n "${tmp// }" ]; then
      resolver="getent"
      ips="${tmp}"
    fi
  fi
  if [ -z "${ips// }" ] && command -v host >/dev/null 2>&1; then
    tmp="$(host "${dom}" 2>/dev/null | awk '/has (IPv6 )?address/ {print $NF}' | sort -u | tr '\n' ' ' || true)"
    if [ -n "${tmp// }" ]; then
      resolver="host"
      ips="${tmp}"
    fi
  fi
  if [ -z "${ips// }" ] && command -v dscacheutil >/dev/null 2>&1; then
    tmp="$(dscacheutil -q host -a name "${dom}" 2>/dev/null | awk '/^ip_address:/ {print $2}' | sort -u | tr '\n' ' ')"
    if [ -n "${tmp// }" ]; then
      resolver="dscacheutil"
      ips="${tmp}"
    fi
  fi
  if [ -z "${ips// }" ] && command -v nslookup >/dev/null 2>&1; then
    tmp="$(nslookup "${dom}" 2>/dev/null | awk '/^Address: / {print $2}' | sort -u | tr '\n' ' ' || true)"
    if [ -n "${tmp// }" ]; then
      resolver="nslookup"
      ips="${tmp}"
    fi
  fi
  if [ -z "${ips// }" ] && command -v dig >/dev/null 2>&1; then
    tmp="$(dig +short "${dom}" 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "${tmp// }" ]; then
      resolver="dig"
      ips="${tmp}"
    fi
  fi

  if [ -z "${ips// }" ]; then
    return 1
  fi

  local clean=""
  clean="$(printf '%s' "${ips}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
  printf '%s|%s\n' "${resolver}" "${clean}"
}

if [ -n "${domain_clean}" ]; then
  if [ "${skip_domain_check}" = "true" ]; then
    warn "SKIP_DOMAIN_DNS_CHECK=true; skipping DNS lookup for '${domain_clean}'."
  else
    resolver_and_ips="$(resolve_domain_ips "${domain_clean}" || true)"
    if [ -z "${resolver_and_ips}" ]; then
      fail "DOMAIN '${domain_clean}' does not appear to resolve; set SKIP_DOMAIN_DNS_CHECK=true to bypass."
    else
      resolver_used="${resolver_and_ips%%|*}"
      domain_ips="${resolver_and_ips#*|}"
      log "DOMAIN '${domain_clean}' resolves via ${resolver_used:-resolver}: ${domain_ips}"
    fi
  fi
fi

get_local_ips() {
  local ips=""
  if command -v ip >/dev/null 2>&1; then
    ips="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
  fi
  if [ -z "${ips// }" ] && command -v hostname >/dev/null 2>&1; then
    ips="$(hostname -I 2>/dev/null | tr '\n' ' ')"
  fi
  if [ -z "${ips// }" ] && command -v ifconfig >/dev/null 2>&1; then
    ips="$(ifconfig 2>/dev/null | awk '/inet6? /{print $2}' | sed 's/addr://g' | tr '\n' ' ')"
  fi
  local filtered=""
  for ip in ${ips}; do
    case "${ip}" in
      0.0.0.0|::)
        continue
        ;;
    esac
    filtered="${filtered} ${ip}"
  done
  filtered="$(printf '%s' "${filtered}" | xargs 2>/dev/null || true)"
  if [ -n "${filtered}" ]; then
    printf '%s' "${filtered}"
  else
    printf '%s' "${ips}"
  fi
}

if [ -n "${domain_ips}" ]; then
  if [ "${skip_domain_ip_match}" = "true" ]; then
    warn "SKIP_DOMAIN_IP_MATCH=true; skipping domain/local IP comparison."
  else
    local_ips="$(get_local_ips)"
    if [ -z "${local_ips// }" ]; then
      warn "Unable to determine local interface addresses; skipping domain/local IP comparison."
    else
      log "Local interface addresses detected: ${local_ips}"
      match_ip=""
      for dip in ${domain_ips}; do
        for lip in ${local_ips}; do
          if [ "${dip}" = "${lip}" ]; then
            match_ip="${dip}"
            break 2
          fi
        done
      done
      if [ -z "${match_ip}" ]; then
        fail "DOMAIN '${domain_clean}' resolves to [${domain_ips}], but this host has [${local_ips}]. Update DNS, adjust host networking, or rerun with SKIP_DOMAIN_IP_MATCH=true."
      else
        log "DOMAIN resolution matches local address (${match_ip})."
      fi
    fi
  fi
fi

check_port_free() {
  local port="$1"
  log "Checking port ${port} availability..."
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(:|\.|])${port}$"; then
      fail "Port ${port} is already in use; stop that process or skip Caddy."
    fi
    log "Port ${port} is free (checked via ss)."
    return
  fi

  if command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"${port}" -sTCP:LISTEN -n >/dev/null 2>&1; then
      fail "Port ${port} is already in use; stop that process or skip Caddy."
    fi
    log "Port ${port} is free (checked via lsof)."
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    if netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(:|\.|])${port}$"; then
      fail "Port ${port} is already in use; stop that process or skip Caddy."
    fi
    log "Port ${port} is free (checked via netstat)."
    return
  fi

  warn "Could not verify whether port ${port} is available (missing ss/lsof/netstat)."
}

curl_required=false

self_test_http_port() {
  local port="$1"
  local host="$2"
  local token
  token="__preflight_${port}_$RANDOM$(date +%s%N)"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local ready_file="${tmpdir}/ready"
  local server_log="${tmpdir}/server.log"

  if ! command -v python3 >/dev/null 2>&1; then
    rm -rf "${tmpdir}"
    fail "python3 is required for the HTTP self-test."
  fi
  if ! command -v curl >/dev/null 2>&1; then
    rm -rf "${tmpdir}"
    fail "curl is required for the HTTP self-test."
  fi

  log "Starting temporary HTTP self-test server on port ${port}."
  python3 - "${port}" "${token}" "${ready_file}" <<'PY' >"${server_log}" 2>&1 &
import http.server
import socket
import socketserver
import sys

port = int(sys.argv[1])
token = "/" + sys.argv[2]
ready = sys.argv[3]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == token:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(token[1:].encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

class DualStackServer(socketserver.TCPServer):
    allow_reuse_address = True
    address_family = socket.AF_INET6 if hasattr(socket, "AF_INET6") else socket.AF_INET

    def server_bind(self):
        if self.address_family == socket.AF_INET6 and hasattr(socket, "IPPROTO_IPV6"):
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except OSError:
                pass
        return super().server_bind()

with DualStackServer(("", port), Handler) as httpd:
    with open(ready, "w") as f:
        f.write("ready")
    httpd.timeout = 5
    httpd.handle_request()
PY
  local server_pid=$!

  for _ in $(seq 1 50); do
    if [ -f "${ready_file}" ]; then
      break
    fi
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      err="$(cat "${server_log}" 2>/dev/null)"
      rm -rf "${tmpdir}"
      fail "Self-test server on port ${port} exited before becoming ready. ${err}
Ensure the port is available and you have permission to bind it, or disable Caddy/preflight."
    fi
    sleep 0.1
  done

  if [ ! -f "${ready_file}" ]; then
    kill "${server_pid}" 2>/dev/null || true
    err="$(cat "${server_log}" 2>/dev/null)"
    rm -rf "${tmpdir}"
    fail "Timed out waiting for self-test server on port ${port}. ${err}
Ensure the port is available and you have permission to bind it, or disable Caddy/preflight."
  fi

  local url="http://${host}:${port}/${token}"
  log "Self-test: requesting ${url}"
  if ! curl -sS --fail --max-time 5 "${url}" >/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    err="$(cat "${server_log}" 2>/dev/null)"
    rm -rf "${tmpdir}"
    fail "Self-test request to ${url} failed. Ensure DNS + port forwarding reach this host or disable preflight. ${err}"
  fi

  log "Self-test succeeded for ${url}"
  kill "${server_pid}" 2>/dev/null || true
  wait "${server_pid}" 2>/dev/null || true
  rm -rf "${tmpdir}"
}

if [ "${enable_caddy}" = "true" ]; then
  log "Caddy profile requested; ports 80/443 must be free."
  if [ "${skip_port_check}" = "true" ]; then
    warn "SKIP_PORT_CHECK=true; not verifying port availability."
  else
    check_port_free 80
    check_port_free 443
  fi

  if [ "${skip_port_selftest}" = "true" ]; then
    warn "SKIP_PORT_SELFTEST=true; skipping ACME-style loopback test."
  else
    host_for_selftest="${domain_clean:-localhost}"
    log "Running ACME-style loopback self-test using host '${host_for_selftest}'."
    self_test_http_port 80 "${host_for_selftest}"
    if [ -n "${domain_clean}" ]; then
      log "Domain set; also testing reachability on port 443 (plain HTTP payload)."
      self_test_http_port 443 "${host_for_selftest}"
    fi
  fi
else
  log "Caddy profile not enabled; port checks and self-tests skipped."
fi

require_integer() {
  local value="$1"
  local label="$2"
  if [ -z "${value}" ]; then
    return 0
  fi
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    fail "${label} must be an integer (got '${value}')"
  fi
}

require_float_in_range() {
  local value="$1"
  local label="$2"
  local min="$3"
  local max="$4"

  if [ -z "${value}" ]; then
    return 0
  fi

  if ! [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    fail "${label} must be numeric (got '${value}')"
  fi

  if ! awk -v v="${value}" -v lo="${min}" -v hi="${max}" 'BEGIN{exit !(v>=lo && v<=hi)}'; then
    fail "${label} must be between ${min} and ${max} (got '${value}')"
  fi
}

require_bool() {
  local value="$1"
  local label="$2"
  if [ -z "${value}" ]; then
    return 0
  fi
  case "${value}" in
    true|false|TRUE|FALSE)
      return 0
      ;;
    *)
      fail "${label} must be 'true' or 'false' (got '${value}')"
      ;;
  esac
}

if [ -n "${BANDWIDTH_LIMIT_MBIT:-}" ]; then
  log "Validating BANDWIDTH_LIMIT_MBIT='${BANDWIDTH_LIMIT_MBIT}'."
fi
require_integer "${BANDWIDTH_LIMIT_MBIT:-}" "BANDWIDTH_LIMIT_MBIT"

if [ -n "${LOCATION_LAT:-}" ]; then
  log "Validating LOCATION_LAT='${LOCATION_LAT}'."
fi
require_float_in_range "${LOCATION_LAT:-}" "LOCATION_LAT" "-90" "90"

if [ -n "${LOCATION_LON:-}" ]; then
  log "Validating LOCATION_LON='${LOCATION_LON}'."
fi
require_float_in_range "${LOCATION_LON:-}" "LOCATION_LON" "-180" "180"

if [ -n "${BANDWIDTH_EXCLUDE_LOCAL:-}" ]; then
  log "Validating BANDWIDTH_EXCLUDE_LOCAL='${BANDWIDTH_EXCLUDE_LOCAL}'."
fi
require_bool "${BANDWIDTH_EXCLUDE_LOCAL:-}" "BANDWIDTH_EXCLUDE_LOCAL"

log "Preflight checks passed."
