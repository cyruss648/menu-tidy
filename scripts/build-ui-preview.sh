#!/bin/bash
# Build a separate, noninstalled app for exercising the real SettingsView.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c debug
bin_dir="$(swift build -c debug --show-bin-path)"
app_path="$PWD/dist/Menu Tidy Preview.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/MenuTidy" "$app_path/Contents/MacOS/MenuTidy"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$app_path/Contents/Resources/CHANGELOG.md"
python3 scripts/prepare-update-bundle.py "$app_path"
python3 - "$app_path/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib
import sys

path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info['CFBundleIdentifier'] = 'dev.hdh.MenuTidy.preview'
info['CFBundleDisplayName'] = 'Menu Tidy Preview'
info['CFBundleName'] = 'Menu Tidy Preview'
for key in tuple(info):
    if key.startswith('SU'):
        del info[key]
path.write_bytes(plistlib.dumps(info, sort_keys=False))
PY
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Preview built: %s\nLaunch with: open -n "%s" --args --preview-ui\n' "$app_path" "$app_path"
printf 'Use --preview-ui --preview-permissions to inspect the missing-permission state.\n'
