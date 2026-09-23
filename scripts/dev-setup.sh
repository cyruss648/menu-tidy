#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: Python 3.11+ is required. Install it manually; no hooks were changed.' >&2
  exit 1
fi
exec python3 scripts/check-dev-tools.py "$@"
