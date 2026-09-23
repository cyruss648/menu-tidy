#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  printf '%s\n' 'Usage: scripts/check.sh [--static [-- FILE...]] | --swift | --full' \
    'Default: static checks of tracked and non-ignored untracked source files.' \
    '--static checks supplied files only when FILE arguments are present.' \
    '--swift runs the complete macOS Swift build and core test suite.' \
    '--full runs both; no source files are modified.'
}

mode="${1:---static}"
if [ "$#" -gt 0 ]; then shift; fi
case "$mode" in
  --help|-h) usage; exit 0 ;;
  --static)
    if [ "${1:-}" = '--' ]; then shift; fi
    exec python3 scripts/check-source.py "$@"
    ;;
  --swift|--full)
    if [ "$#" -ne 0 ]; then usage >&2; exit 2; fi
    ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$mode" = '--full' ]; then python3 scripts/check-source.py; fi
if [ "$(uname -s)" != 'Darwin' ]; then
  printf '%s\n' 'ERROR: Swift app checks require macOS and its SDK; use --static for portable source checks.' >&2
  exit 1
fi
printf '%s\n' 'RUN: swift build -Xswiftc -warnings-as-errors'
swift build -Xswiftc -warnings-as-errors
printf '%s\n' 'RUN: swift test -Xswiftc -warnings-as-errors'
swift test -Xswiftc -warnings-as-errors
