#!/usr/bin/env bash
set -euo pipefail

exec MistController -c /etc/mistserver.conf
