#!/usr/bin/env bash
# Shared utilities for mistserver-bootstrap scripts
# Source this file: source "${SCRIPT_DIR}/../lib/common.sh"

# Determine MIST_BOOTSTRAP_ROOT if not already set
if [ -z "${MIST_BOOTSTRAP_ROOT:-}" ]; then
  # Try to find it relative to this script
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    MIST_BOOTSTRAP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  else
    # Fallback to current directory
    MIST_BOOTSTRAP_ROOT="$(pwd)"
  fi
fi
export MIST_BOOTSTRAP_ROOT

# ─────────────────────────────────────────────────────────────────────────────
# Logging functions
# ─────────────────────────────────────────────────────────────────────────────

# Set LOG_PREFIX to customize the prefix (default: "mist")
LOG_PREFIX="${LOG_PREFIX:-mist}"

log()  { printf '[%s] %s\n' "${LOG_PREFIX}" "$*"; }
warn() { printf '[%s][warn] %s\n' "${LOG_PREFIX}" "$*" >&2; }
fail() { printf '[%s][error] %s\n' "${LOG_PREFIX}" "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Environment loading
# ─────────────────────────────────────────────────────────────────────────────

# Load environment variables from multiple sources (priority: later overrides earlier)
# 1. System-wide (/etc/mistserver/bootstrap.env)
# 2. User config (~/.config/mistserver/bootstrap.env)
# 3. Repository .env
# 4. Current directory .env (if different from repo)
load_env() {
  # System-wide config
  if [ -f /etc/mistserver/bootstrap.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /etc/mistserver/bootstrap.env
    set +a
  fi

  # User config
  if [ -f "${HOME}/.config/mistserver/bootstrap.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${HOME}/.config/mistserver/bootstrap.env"
    set +a
  fi

  # Repository .env
  if [ -f "${MIST_BOOTSTRAP_ROOT}/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${MIST_BOOTSTRAP_ROOT}/.env"
    set +a
  fi

  # Current directory .env (if different from repo root)
  if [ -f ".env" ] && [ "$(pwd)" != "${MIST_BOOTSTRAP_ROOT}" ]; then
    set -a
    # shellcheck disable=SC1091
    . ".env"
    set +a
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Mode detection
# ─────────────────────────────────────────────────────────────────────────────

# Detect runtime mode: docker, native, or unknown
# Returns: "docker" if running inside container
#          "native" if MistServer is running natively (systemd or direct)
#          "unknown" if can't determine
detect_mode() {
  # Check if we're inside a Docker container
  if [ -f /.dockerenv ]; then
    echo "docker"
    return
  fi

  # Check cgroups for containerization
  if [ -f /proc/1/cgroup ] && grep -qE '(docker|containerd|lxc)' /proc/1/cgroup 2>/dev/null; then
    echo "docker"
    return
  fi

  # Check if MistServer is running via systemd
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet mistserver 2>/dev/null; then
    echo "native"
    return
  fi

  # Check if MistController process is running
  if pgrep -x MistController >/dev/null 2>&1; then
    echo "native"
    return
  fi

  echo "unknown"
}

# ─────────────────────────────────────────────────────────────────────────────
# Network utilities (extracted from preflight.sh)
# ─────────────────────────────────────────────────────────────────────────────

# Get local interface IP addresses
# Returns: space-separated list of IPs
get_local_ips() {
  local ips=""

  # Try 'ip' command first (Linux)
  if command -v ip >/dev/null 2>&1; then
    ips="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
  fi

  # Fallback to 'hostname -I' (some Linux)
  if [ -z "${ips// }" ] && command -v hostname >/dev/null 2>&1; then
    ips="$(hostname -I 2>/dev/null | tr '\n' ' ')"
  fi

  # Fallback to ifconfig (macOS, older Linux)
  if [ -z "${ips// }" ] && command -v ifconfig >/dev/null 2>&1; then
    ips="$(ifconfig 2>/dev/null | awk '/inet6? /{print $2}' | sed 's/addr://g' | tr '\n' ' ')"
  fi

  # Filter out 0.0.0.0 and ::
  local filtered=""
  for ip in ${ips}; do
    case "${ip}" in
      0.0.0.0|::)
        continue
        ;;
    esac
    filtered="${filtered} ${ip}"
  done

  # Clean up whitespace
  filtered="$(printf '%s' "${filtered}" | xargs 2>/dev/null || true)"
  if [ -n "${filtered}" ]; then
    printf '%s' "${filtered}"
  else
    printf '%s' "${ips}"
  fi
}

# Resolve domain name to IP addresses
# Arguments: domain_name
# Returns: "resolver|ip1 ip2 ..." or empty string on failure
resolve_domain_ips() {
  local dom="$1"
  local resolver=""
  local ips=""
  local tmp=""

  # Try getent (most reliable on Linux)
  if command -v getent >/dev/null 2>&1; then
    tmp="$(getent ahosts "${dom}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    if [ -n "${tmp// }" ]; then
      resolver="getent"
      ips="${tmp}"
    fi
  fi

  # Try host command
  if [ -z "${ips// }" ] && command -v host >/dev/null 2>&1; then
    tmp="$(host "${dom}" 2>/dev/null | awk '/has (IPv6 )?address/ {print $NF}' | sort -u | tr '\n' ' ' || true)"
    if [ -n "${tmp// }" ]; then
      resolver="host"
      ips="${tmp}"
    fi
  fi

  # Try dscacheutil (macOS)
  if [ -z "${ips// }" ] && command -v dscacheutil >/dev/null 2>&1; then
    tmp="$(dscacheutil -q host -a name "${dom}" 2>/dev/null | awk '/^ip_address:/ {print $2}' | sort -u | tr '\n' ' ')"
    if [ -n "${tmp// }" ]; then
      resolver="dscacheutil"
      ips="${tmp}"
    fi
  fi

  # Try nslookup
  if [ -z "${ips// }" ] && command -v nslookup >/dev/null 2>&1; then
    tmp="$(nslookup "${dom}" 2>/dev/null | awk '/^Address: / {print $2}' | sort -u | tr '\n' ' ' || true)"
    if [ -n "${tmp// }" ]; then
      resolver="nslookup"
      ips="${tmp}"
    fi
  fi

  # Try dig
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

  # Clean up and return
  local clean=""
  clean="$(printf '%s' "${ips}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
  printf '%s|%s\n' "${resolver}" "${clean}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Validation utilities
# ─────────────────────────────────────────────────────────────────────────────

# Require a value to be an integer
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

# Require a value to be a float in range
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

# Require a value to be boolean (true/false)
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

# ─────────────────────────────────────────────────────────────────────────────
# Command checking
# ─────────────────────────────────────────────────────────────────────────────

# Check if a command is available, fail with helpful message if not
require_command() {
  local cmd="$1"
  local install_hint="${2:-}"

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    if [ -n "${install_hint}" ]; then
      fail "Required command '${cmd}' not found. ${install_hint}"
    else
      fail "Required command '${cmd}' not found."
    fi
  fi
}

# Check if Docker is available and running
require_docker() {
  require_command "docker" "Install Docker: sudo apt install docker.io docker-compose-v2 (or see https://docs.docker.com/engine/install/)"

  if ! docker info >/dev/null 2>&1; then
    fail "Docker is not running. Start Docker and try again."
  fi
}
