#!/usr/bin/env bash
set -euo pipefail

# gen_prometheus_config.sh - Generate prometheus.yml with configurable MistServer target
#
# Usage:
#   MIST_TARGET=localhost:4242 ./gen_prometheus_config.sh [output_path]
#
# Environment:
#   MIST_TARGET    MistServer host:port (default: mist:4242 for Docker)
#   SCRAPE_INTERVAL Prometheus scrape interval (default: 10s)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIST_BOOTSTRAP_ROOT="${MIST_BOOTSTRAP_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# Source common library if available
if [ -f "${MIST_BOOTSTRAP_ROOT}/lib/common.sh" ]; then
  source "${MIST_BOOTSTRAP_ROOT}/lib/common.sh"
else
  log() { echo "[gen_prometheus_config] $*"; }
  warn() { echo "[gen_prometheus_config][warn] $*" >&2; }
fi

# Configuration
MIST_TARGET="${MIST_TARGET:-mist:4242}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-10s}"
PROMETHEUS_PATH="${PROMETHEUS_PATH:-metrics}"
OUTPUT="${1:-}"

# If no output specified, default based on context
if [ -z "${OUTPUT}" ]; then
  if [ -d "/etc/prometheus" ]; then
    OUTPUT="/etc/prometheus/prometheus.yml"
  else
    OUTPUT="${MIST_BOOTSTRAP_ROOT}/configs/prometheus/prometheus.yml"
  fi
fi

# Ensure output directory exists
OUTPUT_DIR="$(dirname "${OUTPUT}")"
if [ ! -d "${OUTPUT_DIR}" ]; then
  mkdir -p "${OUTPUT_DIR}"
fi

log "Generating prometheus.yml"
log "  Target: ${MIST_TARGET}"
log "  Metrics path: /${PROMETHEUS_PATH}"
log "  Output: ${OUTPUT}"

cat > "${OUTPUT}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: mist
    metrics_path: /${PROMETHEUS_PATH}
    scrape_interval: ${SCRAPE_INTERVAL}
    scrape_timeout: 10s
    static_configs:
      - targets:
          - ${MIST_TARGET}
EOF

log "Generated prometheus.yml successfully"
