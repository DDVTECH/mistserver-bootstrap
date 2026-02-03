#!/usr/bin/env bash
# MistServer API client for bash
# Provides functions to interact with MistServer via HTTP API

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

# Fall back to common env var names for better UX
MIST_API_HOST="${MIST_API_HOST:-${MIST_HOST:-localhost}}"
MIST_API_PORT="${MIST_API_PORT:-4242}"
MIST_API_USERNAME="${MIST_API_USERNAME:-${ADMIN_USER:-}}"
MIST_API_PASSWORD="${MIST_API_PASSWORD:-${ADMIN_PASSWORD:-}}"

# Cookie jar for session persistence
_MIST_COOKIE_JAR="${TMPDIR:-/tmp}/mist_cookies_$$"

# Authentication state
_MIST_AUTHENTICATED=false

# Build API base URL
_mist_api_url() {
  echo "http://${MIST_API_HOST}:${MIST_API_PORT}/api2"
}

# ─────────────────────────────────────────────────────────────────────────────
# Authentication (MD5 challenge-response)
# ─────────────────────────────────────────────────────────────────────────────

# Calculate MD5 hash of a string
# Arguments: string to hash
# Returns: hex-encoded MD5 hash
_mist_md5() {
  local input="$1"
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "${input}" | md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    # macOS
    printf '%s' "${input}" | md5
  else
    echo "Error: md5sum or md5 command required for authentication" >&2
    return 1
  fi
}

# Calculate MistServer password hash: MD5(MD5(password) + challenge)
# Arguments: password, challenge
# Returns: hex-encoded hash
_mist_password_hash() {
  local password="$1"
  local challenge="$2"

  local password_md5
  password_md5=$(_mist_md5 "${password}")

  _mist_md5 "${password_md5}${challenge}"
}

# Authenticate with MistServer using MD5 challenge-response
# Returns: 0 on success, 1 on failure
_mist_authenticate() {
  # Skip if no credentials configured
  if [ -z "${MIST_API_USERNAME}" ] || [ -z "${MIST_API_PASSWORD}" ]; then
    return 0
  fi

  # Step 1: Request challenge
  local challenge_cmd
  challenge_cmd=$(jq -n --arg u "${MIST_API_USERNAME}" \
    '{authorize: {username: $u, password: ""}}')

  local response
  response=$(_mist_api_raw "${challenge_cmd}")
  if [ $? -ne 0 ]; then
    return 1
  fi

  # Check status
  local status
  status=$(echo "${response}" | jq -r '.authorize.status // empty')

  case "${status}" in
    OK)
      # Already authenticated
      _MIST_AUTHENTICATED=true
      return 0
      ;;
    NOACC)
      echo "Error: No accounts exist on MistServer" >&2
      return 1
      ;;
    CHALL)
      # Continue with authentication
      ;;
    *)
      echo "Error: Unexpected auth status: ${status}" >&2
      return 1
      ;;
  esac

  # Extract challenge
  local challenge
  challenge=$(echo "${response}" | jq -r '.authorize.challenge // empty')
  if [ -z "${challenge}" ]; then
    echo "Error: No challenge in response" >&2
    return 1
  fi

  # Step 2: Calculate password hash and send auth request
  local password_hash
  password_hash=$(_mist_password_hash "${MIST_API_PASSWORD}" "${challenge}")

  local auth_cmd
  auth_cmd=$(jq -n --arg u "${MIST_API_USERNAME}" --arg p "${password_hash}" \
    '{authorize: {username: $u, password: $p}}')

  response=$(_mist_api_raw "${auth_cmd}")
  if [ $? -ne 0 ]; then
    return 1
  fi

  # Check final status
  status=$(echo "${response}" | jq -r '.authorize.status // empty')
  if [ "${status}" = "OK" ]; then
    _MIST_AUTHENTICATED=true
    return 0
  fi

  echo "Error: Authentication failed" >&2
  return 1
}

# Check if response indicates session expired (CHALL status in response)
# Arguments: API response JSON
# Returns: 0 if re-auth needed, 1 otherwise
_mist_needs_reauth() {
  local response="$1"
  local status
  status=$(echo "${response}" | jq -r '.authorize.status // empty')
  [ "${status}" = "CHALL" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Low-level API call
# ─────────────────────────────────────────────────────────────────────────────

# Raw API call without authentication handling
# Arguments: JSON command string
# Returns: JSON response on stdout
_mist_api_raw() {
  local command="$1"
  local url
  url="$(_mist_api_url)?command=$(printf '%s' "${command}" | jq -sRr @uri)"

  local response
  response=$(curl -sf --max-time 10 \
    -b "${_MIST_COOKIE_JAR}" \
    -c "${_MIST_COOKIE_JAR}" \
    "${url}" 2>/dev/null)
  local exit_code=$?

  if [ ${exit_code} -ne 0 ]; then
    echo '{"error":"Failed to connect to MistServer at '"${MIST_API_HOST}:${MIST_API_PORT}"'"}' >&2
    return 1
  fi

  echo "${response}"
}

# Make an API request to MistServer (with authentication)
# Arguments: JSON command string
# Returns: JSON response on stdout
# Example: mist_api '{"active_streams":true}'
mist_api() {
  local command="$1"

  # Authenticate if credentials are configured and not yet authenticated
  if [ -n "${MIST_API_USERNAME}" ] && [ "${_MIST_AUTHENTICATED}" != "true" ]; then
    if ! _mist_authenticate; then
      return 1
    fi
  fi

  local response
  response=$(_mist_api_raw "${command}")
  if [ $? -ne 0 ]; then
    return 1
  fi

  # Check if session expired and re-auth needed
  if _mist_needs_reauth "${response}"; then
    _MIST_AUTHENTICATED=false
    if ! _mist_authenticate; then
      return 1
    fi
    # Retry the original request
    response=$(_mist_api_raw "${command}")
    if [ $? -ne 0 ]; then
      return 1
    fi
  fi

  echo "${response}"
}

# Make an API request and extract a specific field
# Arguments: JSON command, jq filter
# Example: mist_api_get '{"active_streams":true}' '.active_streams'
mist_api_get() {
  local command="$1"
  local filter="$2"

  local response
  response=$(mist_api "${command}")
  if [ $? -ne 0 ]; then
    return 1
  fi

  echo "${response}" | jq -r "${filter}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Protocol (Output) Management
# ─────────────────────────────────────────────────────────────────────────────

# Update a protocol's configuration
# Arguments: connector_name, json_updates
# Example: mist_update_protocol "HTTP" '{"pubaddr":["https://example.com/view/"]}'
mist_update_protocol() {
  local connector="$1"
  local updates="$2"

  # Build the new config by merging connector name with updates
  local new_config
  new_config=$(echo "${updates}" | jq --arg c "${connector}" '. + {connector: $c}')

  local command
  command=$(jq -n \
    --arg connector "${connector}" \
    --argjson new_config "${new_config}" \
    '{updateprotocol: [{connector: $connector}, $new_config]}')

  mist_api "${command}"
}

# Set HTTP protocol pubaddr for reverse proxy
# Arguments: domain [http_port]
mist_set_pubaddr() {
  local domain="$1"
  local http_port="${2:-${MIST_HTTP_PORT:-8080}}"
  local pubaddr
  pubaddr=$(jq -n --arg d "${domain}" --arg p "${http_port}" \
    '["https://\($d)/view/", "http://\($d):\($p)"]')

  mist_update_protocol "HTTP" "{\"pubaddr\": ${pubaddr}}"
}

# Set WebRTC protocol pubhost
# Arguments: domain
mist_set_pubhost() {
  local domain="$1"
  mist_update_protocol "WebRTC" "{\"pubhost\": \"${domain}\"}"
}

# Clear pubaddr (revert to direct access)
mist_clear_pubaddr() {
  # Set to null to clear
  mist_update_protocol "HTTP" '{"pubaddr": null}'
}

# Clear pubhost
mist_clear_pubhost() {
  mist_update_protocol "WebRTC" '{"pubhost": null}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Stream Management
# ─────────────────────────────────────────────────────────────────────────────

# List all configured streams
mist_streams() {
  mist_api_get '{"streams":true}' '.streams'
}

# Get info about a specific stream
# Arguments: stream_name
mist_stream_info() {
  local name="$1"
  mist_api_get '{"streams":true}' ".streams.\"${name}\""
}

# Add or update a stream
# Arguments: stream_name, source, [json_options]
# Example: mist_stream_add "live" "push://" '{"always_on":false}'
mist_stream_add() {
  local name="$1"
  local source="$2"
  local options="${3:-{}}"

  local stream_config
  stream_config=$(echo "${options}" | jq --arg n "${name}" --arg s "${source}" '. + {name: $n, source: $s}')

  local command
  command=$(jq -n --arg name "${name}" --argjson config "${stream_config}" \
    '{addstream: {($name): $config}}')

  mist_api "${command}"
}

# Delete a stream
# Arguments: stream_name
mist_stream_delete() {
  local name="$1"
  mist_api "{\"deletestream\": \"${name}\"}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Push Management
# ─────────────────────────────────────────────────────────────────────────────

# List active pushes
mist_push_list() {
  mist_api_get '{"push_list":true}' '.push_list'
}

# Start a push
# Arguments: stream_name, target_uri
mist_push_start() {
  local stream="$1"
  local target="$2"

  local command
  command=$(jq -n --arg s "${stream}" --arg t "${target}" \
    '{push_start: {stream: $s, target: $t}}')

  mist_api "${command}"
}

# Stop a push by ID
# Arguments: push_id
mist_push_stop() {
  local push_id="$1"
  mist_api "{\"push_stop\": ${push_id}}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Status & Monitoring
# ─────────────────────────────────────────────────────────────────────────────

# Get active streams with stats
mist_active_streams() {
  mist_api_get '{"active_streams":{"longform":true}}' '.active_streams'
}

# Get connected clients
mist_clients() {
  mist_api_get '{"clients":{"time":-5}}' '.clients'
}

# Get server stats (CPU, memory, etc.)
mist_stats() {
  mist_api_get '{"stats":true}' '.stats'
}

# ─────────────────────────────────────────────────────────────────────────────
# Configuration Management
# ─────────────────────────────────────────────────────────────────────────────

# Get current config
mist_config() {
  mist_api_get '{"config":true}' '.config'
}

# Backup full config
mist_config_backup() {
  mist_api_get '{"config_backup":true}' '.config_backup'
}

# Restore full config
# Arguments: config_json
mist_config_restore() {
  local config="$1"
  local command
  command=$(jq -n --argjson cfg "${config}" '{config_restore: $cfg}')
  mist_api "${command}"
}

# Save config to disk
mist_save() {
  mist_api '{"save":true}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Session Management
# ─────────────────────────────────────────────────────────────────────────────

# Stop all sessions for a stream
# Arguments: stream_name
mist_stop_sessions() {
  local stream="$1"
  mist_api "{\"stop_sessions\": \"${stream}\"}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Health Check
# ─────────────────────────────────────────────────────────────────────────────

# Check if MistServer is reachable
mist_health() {
  local metrics_path="${PROMETHEUS_PATH:-metrics}"
  if curl -sf --max-time 5 "http://${MIST_API_HOST}:${MIST_API_PORT}/${metrics_path}" >/dev/null 2>&1; then
    echo "ok"
    return 0
  else
    echo "unreachable"
    return 1
  fi
}

# Wait for MistServer to be ready
# Arguments: [timeout_seconds]
mist_wait_ready() {
  local timeout="${1:-30}"
  local elapsed=0

  while [ ${elapsed} -lt ${timeout} ]; do
    if mist_health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

# Clean up cookie jar on exit (if sourced as library)
_mist_cleanup() {
  rm -f "${_MIST_COOKIE_JAR}" 2>/dev/null || true
}

# Register cleanup only if not already set
if [ -z "${_MIST_CLEANUP_REGISTERED:-}" ]; then
  trap _mist_cleanup EXIT
  _MIST_CLEANUP_REGISTERED=true
fi
