#!/usr/bin/env bash
set -euo pipefail

if [ -f /scripts/gen_mist_config.sh ]; then
  /usr/bin/env bash /scripts/gen_mist_config.sh || true
fi

exec MistController -c /etc/mistserver.conf
