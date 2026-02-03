#!/bin/sh
set -eu

# gen_caddyfile.sh - Generate Caddyfile for MistServer reverse proxy
# POSIX-sh compatible for Alpine/Docker use

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIST_BOOTSTRAP_ROOT="${MIST_BOOTSTRAP_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# Logging functions (standalone - don't source libs in Docker container)
log() { printf '[caddyfile] %s\n' "$1"; }
warn() { printf '[caddyfile][warn] %s\n' "$*" >&2; }

# Configuration
: "${DOMAIN:=}"
: "${MODE:=docker}"

# Backend targets (configurable, with mode-aware defaults)
if [ "${MODE}" = "docker" ]; then
  MIST_API_BACKEND="${MIST_API_BACKEND:-${MIST_BACKEND:-mist:4242}}"
  MIST_HTTP_BACKEND="${MIST_HTTP_BACKEND:-mist:8080}"
  GRAFANA_BACKEND="${GRAFANA_BACKEND:-grafana:3000}"
else
  MIST_API_BACKEND="${MIST_API_BACKEND:-${MIST_BACKEND:-localhost:4242}}"
  MIST_HTTP_BACKEND="${MIST_HTTP_BACKEND:-localhost:8080}"
  GRAFANA_BACKEND="${GRAFANA_BACKEND:-localhost:3000}"
fi

# Output path
if [ "${MODE}" = "docker" ]; then
  CADDYFILE_PATH="${CADDYFILE_PATH:-/etc/caddy/Caddyfile}"
else
  CADDYFILE_PATH="${CADDYFILE_PATH:-${MIST_BOOTSTRAP_ROOT}/configs/Caddyfile}"
fi

log "Mode: ${MODE}"
log "MistServer API backend: ${MIST_API_BACKEND}"
log "MistServer HTTP backend: ${MIST_HTTP_BACKEND}"
log "Grafana backend: ${GRAFANA_BACKEND}"
log "Output: ${CADDYFILE_PATH}"

# Create output directory if needed
mkdir -p "$(dirname "${CADDYFILE_PATH}")"

# Build routes block
routes="
encode gzip
log

@mist_noslash path /mist
redir @mist_noslash /mist/ 308

@ws_mist path /mist/ws*
reverse_proxy @ws_mist ${MIST_API_BACKEND} {
  header_up Host {host}
  header_up X-Real-IP {remote}
  header_up X-Forwarded-For {remote}
  header_up X-Forwarded-Proto {scheme}
  transport http {
    versions h2c 1.1
  }
}

handle_path /mist/* {
  reverse_proxy ${MIST_API_BACKEND}
}

handle_path /view/* {
  reverse_proxy ${MIST_HTTP_BACKEND} {
    header_up X-Mst-Path \"{scheme}://{host}/view/\"
  }
}

handle_path /hls/* {
  header {
    Access-Control-Allow-Origin *
    Access-Control-Allow-Methods \"GET, POST, OPTIONS\"
    Access-Control-Allow-Headers \"DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range\"
    Access-Control-Expose-Headers \"Content-Length,Content-Range\"
  }
  reverse_proxy ${MIST_HTTP_BACKEND}
}

handle_path /webrtc/* {
  reverse_proxy ${MIST_HTTP_BACKEND}
}

@grafana_noslash path /grafana
redir @grafana_noslash /grafana/ 308

@grafana path /grafana*
handle @grafana {
  reverse_proxy ${GRAFANA_BACKEND} {
    header_up Host {host}
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Prefix /grafana
  }
}

handle {
  respond \"Not found\" 404
}
"

# Write Caddyfile
if [ -n "${DOMAIN}" ]; then
  log "Domain: ${DOMAIN} (HTTPS + HTTP)"
  cat > "${CADDYFILE_PATH}" <<EOF
${DOMAIN} {
${routes}
}
:80 {
${routes}
}
EOF
else
  log "No domain set (HTTP only on :80)"
  cat > "${CADDYFILE_PATH}" <<EOF
:80 {
${routes}
}
EOF
fi

log "Caddyfile generated at ${CADDYFILE_PATH}"
