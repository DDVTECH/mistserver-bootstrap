#!/usr/bin/env bash
# MistServer configuration manipulation utilities
# Source lib/common.sh before this file

# ─────────────────────────────────────────────────────────────────────────────
# Config path detection
# ─────────────────────────────────────────────────────────────────────────────

# Get MistServer config file path based on runtime mode
# Arguments: [mode] - optional, auto-detected if not provided
# Returns: path to mistserver.conf
get_config_path() {
  local mode="${1:-$(detect_mode)}"

  case "${mode}" in
    docker)
      # Inside container: standard path
      echo "/etc/mistserver.conf"
      ;;
    *)
      # Native: check standard locations in order
      if [ -f "/etc/mistserver/mistserver.conf" ]; then
        echo "/etc/mistserver/mistserver.conf"
      elif [ -f "/etc/mistserver.conf" ]; then
        echo "/etc/mistserver.conf"
      elif [ -f "${MIST_BOOTSTRAP_ROOT}/configs/mistserver.conf" ]; then
        echo "${MIST_BOOTSTRAP_ROOT}/configs/mistserver.conf"
      else
        # Default location for new installs
        echo "/etc/mistserver.conf"
      fi
      ;;
  esac
}

# Check if MistServer config exists and is readable
config_exists() {
  local config_path="${1:-$(get_config_path)}"
  [ -f "${config_path}" ] && [ -r "${config_path}" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# MistServer API interaction
# ─────────────────────────────────────────────────────────────────────────────

# Default MistServer connection settings
MIST_HOST="${MIST_HOST:-localhost}"
MIST_API_PORT="${MIST_API_PORT:-4242}"
MIST_HTTP_PORT="${MIST_HTTP_PORT:-8080}"

# Build MistServer API URL
get_mist_api_url() {
  local host="${1:-${MIST_HOST}}"
  local port="${2:-${MIST_API_PORT}}"
  echo "http://${host}:${port}"
}

# Check if MistServer is reachable
mist_is_reachable() {
  local host="${1:-${MIST_HOST}}"
  local port="${2:-${MIST_API_PORT}}"

  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 5 "http://${host}:${port}/metrics" >/dev/null 2>&1
    return $?
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=5 -O /dev/null "http://${host}:${port}/metrics" 2>/dev/null
    return $?
  else
    # Can't check, assume reachable
    return 0
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Config manipulation helpers
# ─────────────────────────────────────────────────────────────────────────────

# Update pubaddr in MistServer config for HTTPS/domain setup
# Arguments: domain, [config_file]
# This updates HTTP pubaddr and WebRTC pubhost for proper embed codes
update_pubaddr() {
  local domain="$1"
  local config_file="${2:-$(get_config_path)}"

  if [ ! -f "${config_file}" ]; then
    warn "Config file not found: ${config_file}"
    return 1
  fi

  require_command "jq" "Install jq: apt install jq"

  local http_pubaddr
  local webrtc_pubhost="${domain}"

  # Set up pubaddr array with HTTPS and HTTP fallback
  http_pubaddr='["https://'"${domain}"'/view/","http://'"${domain}"':8080"]'

  log "Updating pubaddr in ${config_file} for domain: ${domain}"

  local tmp_file
  tmp_file="$(mktemp)"

  jq \
    --argjson http_pubaddr "${http_pubaddr}" \
    --arg webrtc_pubhost "${webrtc_pubhost}" \
    '
    # Update HTTP protocol pubaddr
    (if .config.protocols? != null
     then .config.protocols = (.config.protocols
           | map(
               if .connector == "HTTP" then .pubaddr = $http_pubaddr
               elif .connector == "WebRTC" then .pubhost = $webrtc_pubhost
               else .
               end))
     else .
     end)
    ' \
    "${config_file}" > "${tmp_file}"

  if [ $? -eq 0 ]; then
    cat "${tmp_file}" > "${config_file}"
    rm -f "${tmp_file}"
    log "pubaddr updated successfully"
    return 0
  else
    rm -f "${tmp_file}"
    warn "Failed to update pubaddr"
    return 1
  fi
}

# Clear pubaddr settings (revert to direct access)
clear_pubaddr() {
  local config_file="${1:-$(get_config_path)}"

  if [ ! -f "${config_file}" ]; then
    warn "Config file not found: ${config_file}"
    return 1
  fi

  require_command "jq" "Install jq: apt install jq"

  log "Clearing pubaddr in ${config_file}"

  local tmp_file
  tmp_file="$(mktemp)"

  jq \
    '
    # Remove pubaddr from HTTP protocol, pubhost from WebRTC
    (if .config.protocols? != null
     then .config.protocols = (.config.protocols
           | map(
               if .connector == "HTTP" then del(.pubaddr)
               elif .connector == "WebRTC" then del(.pubhost)
               else .
               end))
     else .
     end)
    ' \
    "${config_file}" > "${tmp_file}"

  if [ $? -eq 0 ]; then
    cat "${tmp_file}" > "${config_file}"
    rm -f "${tmp_file}"
    log "pubaddr cleared"
    return 0
  else
    rm -f "${tmp_file}"
    warn "Failed to clear pubaddr"
    return 1
  fi
}

# Add trusted proxy CIDR to config
# Arguments: cidr, [config_file]
add_trusted_proxy() {
  local cidr="$1"
  local config_file="${2:-$(get_config_path)}"

  if [ ! -f "${config_file}" ]; then
    warn "Config file not found: ${config_file}"
    return 1
  fi

  require_command "jq" "Install jq: apt install jq"

  log "Adding trusted proxy ${cidr} to ${config_file}"

  local tmp_file
  tmp_file="$(mktemp)"

  jq \
    --arg cidr "${cidr}" \
    '
    .trustedproxy = ((.trustedproxy // []) + [$cidr] | unique)
    ' \
    "${config_file}" > "${tmp_file}"

  if [ $? -eq 0 ]; then
    cat "${tmp_file}" > "${config_file}"
    rm -f "${tmp_file}"
    return 0
  else
    rm -f "${tmp_file}"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Password hashing
# ─────────────────────────────────────────────────────────────────────────────

# Hash password using MD5 (MistServer uses MD5 for password storage)
hash_password() {
  local password="$1"
  printf '%s' "${password}" | md5sum | awk '{print $1}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Backend target helpers
# ─────────────────────────────────────────────────────────────────────────────

# Get MistServer backend target for reverse proxy
# Returns appropriate target based on mode (Docker service name or localhost)
get_mist_backend() {
  local mode="${1:-$(detect_mode)}"

  case "${mode}" in
    docker)
      echo "${MIST_BACKEND:-mist:${MIST_API_PORT}}"
      ;;
    *)
      echo "${MIST_BACKEND:-${MIST_HOST}:${MIST_API_PORT}}"
      ;;
  esac
}

# Get MistServer HTTP backend (for streaming)
get_mist_http_backend() {
  local mode="${1:-$(detect_mode)}"

  case "${mode}" in
    docker)
      echo "${MIST_HTTP_BACKEND:-mist:${MIST_HTTP_PORT}}"
      ;;
    *)
      echo "${MIST_HTTP_BACKEND:-${MIST_HOST}:${MIST_HTTP_PORT}}"
      ;;
  esac
}

# Get Prometheus backend for Grafana
get_prometheus_backend() {
  local mode="${1:-$(detect_mode)}"

  case "${mode}" in
    docker)
      echo "${PROMETHEUS_BACKEND:-prometheus:${PROMETHEUS_PORT:-9090}}"
      ;;
    *)
      echo "${PROMETHEUS_BACKEND:-${PROMETHEUS_HOST:-localhost}:${PROMETHEUS_PORT:-9090}}"
      ;;
  esac
}

# Get Grafana backend for reverse proxy
get_grafana_backend() {
  local mode="${1:-$(detect_mode)}"

  case "${mode}" in
    docker)
      echo "${GRAFANA_BACKEND:-grafana:${GRAFANA_PORT:-3000}}"
      ;;
    *)
      echo "${GRAFANA_BACKEND:-${GRAFANA_HOST:-localhost}:${GRAFANA_PORT:-3000}}"
      ;;
  esac
}

# Get MistServer target for Prometheus scraping
get_mist_target() {
  local mode="${1:-$(detect_mode)}"

  # MIST_TARGET takes precedence if explicitly set
  if [ -n "${MIST_TARGET:-}" ]; then
    echo "${MIST_TARGET}"
    return
  fi

  case "${mode}" in
    docker)
      echo "mist:${MIST_API_PORT}"
      ;;
    *)
      echo "${MIST_HOST}:${MIST_API_PORT}"
      ;;
  esac
}
