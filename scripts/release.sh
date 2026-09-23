#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/release.sh <version> (pushes an annotated v<version> tag)' >&2
  exit 2
fi
release_version="$1"
python3 - "$release_version" <<'PY'
import plistlib,re,sys
from pathlib import Path
version = sys.argv[1]
if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
    raise SystemExit('Version must be semver without a v prefix')
info = plistlib.loads(Path('Resources/Info.plist').read_bytes())
if info['CFBundleShortVersionString'] != version:
    raise SystemExit('Version does not match Resources/Info.plist')
PY
gh auth status --hostname github.com >/dev/null
if [ -n "$(git status --porcelain)" ]; then
  echo 'Commit all changes before releasing.' >&2
  exit 1
fi
if [ "$(git branch --show-current)" != main ]; then
  echo 'Release from main.' >&2
  exit 1
fi
git fetch origin main --tags
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo 'Push main and wait for CI before tagging.' >&2
  exit 1
fi
release_head="$(git rev-parse HEAD)"
release_ci="$(gh run list --workflow ci.yml --branch main --event push --commit "$release_head" --limit 1 --json status,conclusion)"
python3 - "$release_ci" <<'PY'
import json, sys
runs = json.loads(sys.argv[1])
if not runs or runs[0].get('status') != 'completed' or runs[0].get('conclusion') != 'success':
    raise SystemExit('The latest main push workflow for this exact commit must pass before releasing.')
PY
release_tag="v$release_version"
if git show-ref --verify --quiet "refs/tags/$release_tag"; then
  echo 'The tag already exists; release tags are immutable.' >&2
  exit 1
fi
./scripts/check.sh --full
release_notes="$(mktemp)"
trap 'rm -f "$release_notes"' EXIT
python3 scripts/release-notes.py "$release_tag" > "$release_notes"
git tag -a "$release_tag" -F "$release_notes"
git push origin "refs/tags/$release_tag"
printf 'Tag pushed: %s. GitHub Actions will build and publish the preview release.\n' "$release_tag"
