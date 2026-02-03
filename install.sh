#!/usr/bin/env bash
set -euo pipefail

# install.sh - Install mistserver-bootstrap CLI tools
# Creates symlinks in /usr/local/bin and sets up config directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[install][warn] %s\n' "$*" >&2; }
fail() { printf '[install][error] %s\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
CONFIG_DIR="${CONFIG_DIR:-/etc/mistserver}"

# ─────────────────────────────────────────────────────────────────────────────
# Check requirements
# ─────────────────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
  log "Running with sudo..."
  exec sudo "$0" "$@"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Install
# ─────────────────────────────────────────────────────────────────────────────

log "Installing mistserver-bootstrap tools..."
log "Source: ${SCRIPT_DIR}"
log "Install prefix: ${INSTALL_PREFIX}"
log "Config dir: ${CONFIG_DIR}"
echo ""

# Create config directory
mkdir -p "${CONFIG_DIR}"

# Create symlinks for bin scripts
log "Creating symlinks in ${INSTALL_PREFIX}/bin..."
mkdir -p "${INSTALL_PREFIX}/bin"

for script in "${SCRIPT_DIR}/bin/"*; do
  if [ -f "${script}" ] && [ -x "${script}" ]; then
    name="$(basename "${script}")"
    target="${INSTALL_PREFIX}/bin/${name}"

    if [ -L "${target}" ]; then
      rm "${target}"
    elif [ -e "${target}" ]; then
      warn "Skipping ${name}: file exists and is not a symlink"
      continue
    fi

    ln -s "${script}" "${target}"
    log "  ${name} -> ${script}"
  fi
done

# Also symlink videogen.sh as mist-videogen if not already done
if [ -f "${SCRIPT_DIR}/scripts/videogen.sh" ]; then
  if [ ! -e "${INSTALL_PREFIX}/bin/videogen" ]; then
    ln -s "${SCRIPT_DIR}/bin/mist-videogen" "${INSTALL_PREFIX}/bin/videogen"
    log "  videogen -> ${SCRIPT_DIR}/bin/mist-videogen"
  fi
fi

# Create default environment file if it doesn't exist
if [ ! -f "${CONFIG_DIR}/bootstrap.env" ]; then
  if [ -f "${SCRIPT_DIR}/env.example" ]; then
    cp "${SCRIPT_DIR}/env.example" "${CONFIG_DIR}/bootstrap.env"
    log "Created ${CONFIG_DIR}/bootstrap.env"
  fi
fi

# Store the bootstrap root location
cat > "${CONFIG_DIR}/bootstrap-root" <<EOF
${SCRIPT_DIR}
EOF
log "Stored bootstrap root in ${CONFIG_DIR}/bootstrap-root"

echo ""
log "Installation complete!"
echo ""
echo "Available commands:"
echo "  mist-install     Install MistServer (build from source or download binary)"
echo "  mist-passwd      Change MistServer admin password"
echo "  mist-https       Enable/disable HTTPS reverse proxy"
echo "  mist-monitoring  Enable/disable Prometheus + Grafana"
echo "  mist-status      Show MistServer status"
echo "  mist-videogen    Generate test video stream"
echo ""
echo "Configuration:"
echo "  Edit ${CONFIG_DIR}/bootstrap.env to customize settings"
echo ""
echo "Quick start (native installation):"
echo "  mist-install                     # Build from source with AV support"
echo "  mist-install --binary            # Or download pre-built binary"
echo "  mist-monitoring enable           # Enable Prometheus + Grafana"
echo "  mist-https enable --domain ...   # Enable HTTPS reverse proxy"
