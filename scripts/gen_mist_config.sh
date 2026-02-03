#!/usr/bin/env bash
set -euo pipefail

# Determine script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIST_BOOTSTRAP_ROOT="${MIST_BOOTSTRAP_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# Source shared libraries if available
if [ -f "${MIST_BOOTSTRAP_ROOT}/lib/common.sh" ]; then
  # shellcheck source=../lib/common.sh
  source "${MIST_BOOTSTRAP_ROOT}/lib/common.sh"
  # shellcheck source=../lib/config.sh
  source "${MIST_BOOTSTRAP_ROOT}/lib/config.sh"
  LOG_PREFIX="mist-config"
else
  # Fallback logging for standalone use
  log() { printf '[mist-config] %s\n' "$1"; }
  warn() { printf '[mist-config][warn] %s\n' "$*" >&2; }
  fail() { printf '[mist-config][error] %s\n' "$*" >&2; exit 1; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

# Accept config path as first argument, or use CONF_FILE env var, or auto-detect
if [ -n "${1:-}" ]; then
  CONF_FILE="$1"
elif [ -n "${CONF_FILE:-}" ]; then
  CONF_FILE="${CONF_FILE}"
elif type get_config_path >/dev/null 2>&1; then
  CONF_FILE="$(get_config_path)"
else
  # Default for Docker container
  CONF_FILE="/etc/mistserver.conf"
fi

if [ ! -f "${CONF_FILE}" ]; then
  fail "Config file not found: ${CONF_FILE}"
fi

TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Environment Variables
# ─────────────────────────────────────────────────────────────────────────────

: "${ADMIN_USER:=}"
: "${ADMIN_PASSWORD:=}"
: "${DOMAIN:=}"
: "${BANDWIDTH_EXCLUDE_LOCAL:=}"
: "${BANDWIDTH_LIMIT_MBIT:=}"
: "${LOCATION_NAME:=}"
: "${LOCATION_LAT:=}"
: "${LOCATION_LON:=}"
: "${PROMETHEUS_PATH:=}"

# ─────────────────────────────────────────────────────────────────────────────
# Computed Values
# ─────────────────────────────────────────────────────────────────────────────

ADMIN_HASH=""
if [ -n "${ADMIN_PASSWORD}" ]; then
  if type hash_password >/dev/null 2>&1; then
    ADMIN_HASH="$(hash_password "${ADMIN_PASSWORD}")"
  else
    ADMIN_HASH="$(printf '%s' "${ADMIN_PASSWORD}" | md5sum | awk '{print $1}')"
  fi
fi

HTTP_PUBADDR=""
WEBRTC_PUBHOST=""
if [ -n "${DOMAIN}" ]; then
  HTTP_PUBADDR='["https://'"${DOMAIN}"'/view/","http://'"${DOMAIN}"':8080"]'
  WEBRTC_PUBHOST="${DOMAIN}"
fi

DEFAULT_EXCEPTIONS='["::1","127.0.0.0/8","10.0.0.0/8","192.168.0.0/16","172.16.0.0/12"]'

LIMIT_BYTES=""
if [ -n "${BANDWIDTH_LIMIT_MBIT}" ] && [ "${BANDWIDTH_LIMIT_MBIT}" != "0" ]; then
  LIMIT_BYTES=$(( BANDWIDTH_LIMIT_MBIT * 125000 ))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────

log "Config file: ${CONF_FILE}"

if [ -n "${ADMIN_USER}" ] && [ -n "${ADMIN_HASH}" ]; then
  log "Setting admin user '${ADMIN_USER}' from environment."
else
  log "ADMIN_USER not provided; preserving existing admin accounts."
fi

bw_mode="$(printf '%s' "${BANDWIDTH_EXCLUDE_LOCAL}" | tr '[:upper:]' '[:lower:]')"
case "${bw_mode}" in
  true)
    log "BANDWIDTH_EXCLUDE_LOCAL=true; applying default private subnets."
    ;;
  false)
    log "BANDWIDTH_EXCLUDE_LOCAL=false; clearing bandwidth exception list."
    ;;
  "")
    log "BANDWIDTH_EXCLUDE_LOCAL not set; leaving bandwidth exceptions unchanged."
    ;;
  *)
    log "BANDWIDTH_EXCLUDE_LOCAL='${BANDWIDTH_EXCLUDE_LOCAL}' (unrecognized); leaving bandwidth exceptions unchanged."
    ;;
esac

if [ -n "${LIMIT_BYTES}" ]; then
  log "BANDWIDTH_LIMIT_MBIT=${BANDWIDTH_LIMIT_MBIT} -> limit ${LIMIT_BYTES} bytes/s."
else
  log "BANDWIDTH_LIMIT_MBIT not set or zero; no bandwidth cap applied."
fi

if [ -n "${PROMETHEUS_PATH}" ]; then
  log "PROMETHEUS_PATH='${PROMETHEUS_PATH}' will overwrite config.prometheus."
else
  log "PROMETHEUS_PATH not provided; keeping existing path."
fi

if [ -n "${LOCATION_NAME}" ] || [ -n "${LOCATION_LAT}" ] || [ -n "${LOCATION_LON}" ]; then
  log "Applying location override name='${LOCATION_NAME}' lat='${LOCATION_LAT}' lon='${LOCATION_LON}'."
else
  log "LOCATION_* variables not set; leaving config.location untouched."
fi

if [ -n "${HTTP_PUBADDR}" ]; then
  log "DOMAIN='${DOMAIN}' -> public HTTP/WebRTC endpoints will point to ${HTTP_PUBADDR}."
else
  log "DOMAIN not set; leaving public endpoint URLs as-is."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Apply Configuration with jq
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not installed. Install with: apt install jq"
fi

jq \
  --arg admin_user "${ADMIN_USER}" \
  --arg admin_hash "${ADMIN_HASH}" \
  --argjson http_pubaddr "${HTTP_PUBADDR:-null}" \
  --arg webrtc_pubhost "${WEBRTC_PUBHOST}" \
  --arg domain "${DOMAIN}" \
  --arg prometheus_path "${PROMETHEUS_PATH}" \
  --arg bw_exclude "${BANDWIDTH_EXCLUDE_LOCAL}" \
  --arg default_exceptions "${DEFAULT_EXCEPTIONS}" \
  --argjson limit_bytes "$( [ -n "${LIMIT_BYTES}" ] && echo "${LIMIT_BYTES}" || echo 'null' )" \
  --arg loc_name "${LOCATION_NAME}" \
  --arg loc_lat "${LOCATION_LAT}" \
  --arg loc_lon "${LOCATION_LON}" \
  '
  .
  | (if (($admin_user|length)>0 and ($admin_hash|length)>0)
     then .account = { ($admin_user): { "password": $admin_hash } }
     else .
     end)
  | (if ($bw_exclude|ascii_downcase) == "true"
     then .bandwidth = (.bandwidth // {}) | .bandwidth.exceptions = ($default_exceptions | fromjson)
     elif ($bw_exclude|ascii_downcase) == "false"
     then .bandwidth = (.bandwidth // {}) | .bandwidth.exceptions = [""]
     else .
     end)
  | (if $limit_bytes != null
     then .bandwidth = (.bandwidth // {}) | .bandwidth.limit = $limit_bytes
     else .
     end)
  | (if ($prometheus_path|length) > 0
     then .config.prometheus = $prometheus_path
     else .
     end)
  | (if (($loc_name|length)>0) or (($loc_lat|length)>0) or (($loc_lon|length)>0)
     then .config.location = (
            (.config.location // {})
            | (if ($loc_name|length)>0 then .name = $loc_name else . end)
            | (if ($loc_lat|length)>0 then .lat = ($loc_lat|tonumber) else . end)
            | (if ($loc_lon|length)>0 then .lon = ($loc_lon|tonumber) else . end)
          )
     else .
     end)
  | (if ($http_pubaddr != null) and (($http_pubaddr|length)>0) and (.config.protocols? // null) != null
     then .config.protocols = (.config.protocols
           | map(
               if .connector == "HTTP" then .pubaddr = $http_pubaddr
               elif .connector == "WebRTC" then .pubhost = $webrtc_pubhost
               else .
               end))
     else .
     end)
  | (if ($domain|length) > 0
     then .ui_settings = (.ui_settings // {})
          | .ui_settings.HTTPSUrl = "https://\($domain)/view/"
          | .ui_settings.HTTPUrl = "http://\($domain):8080/"
     else .
     end)
  ' \
  "${CONF_FILE}" > "${TMP_FILE}"

cat "${TMP_FILE}" > "${CONF_FILE}"
chmod 0644 "${CONF_FILE}"

log "Configuration updated successfully."
exit 0
