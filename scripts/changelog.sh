#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  printf '%s\n' 'Usage: scripts/changelog.sh [--unreleased | --latest | --tag vX.Y.Z]' \
    'Prints a preview to stdout; never overwrites CHANGELOG.md or creates a tag.' \
    'Keep the manually documented initial release and historical summaries.'
}

mode="${1:---unreleased}"
case "$mode" in
  --help|-h) usage; exit 0 ;;
  --unreleased|--latest)
    if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi
    args=("$mode")
    ;;
  --tag)
    if [ "$#" -ne 2 ] || ! [[ "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then usage >&2; exit 2; fi
    args=(--unreleased --tag "$2")
    ;;
  *) usage >&2; exit 2 ;;
esac
if ! command -v git-cliff >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: git-cliff is required. Install it manually, then retry.' >&2
  exit 1
fi
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  printf '%s\n' 'No commits yet: CHANGELOG.md contains the manual initial-release summary. No history was generated.' >&2
  exit 1
fi
# Personal git-cliff output settings must not turn this preview into a write.
unset GIT_CLIFF_OUTPUT GIT_CLIFF_PREPEND
exec git-cliff --config cliff.toml --offline --no-exec "${args[@]}"
