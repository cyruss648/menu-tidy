#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: scripts/build.sh [debug|release]' >&2; exit 2;; esac
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/dist/Menu Tidy.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/MenuTidy" "$app_path/Contents/MacOS/MenuTidy"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$app_path/Contents/Resources/CHANGELOG.md"
if [ -d Resources/en.lproj ]; then
  mkdir -p "$app_path/Contents/Resources/en.lproj"
  cp Resources/en.lproj/Localizable.strings "$app_path/Contents/Resources/en.lproj/Localizable.strings"
fi
if [ -d Resources/zh-Hans.lproj ]; then
  mkdir -p "$app_path/Contents/Resources/zh-Hans.lproj"
  cp Resources/zh-Hans.lproj/Localizable.strings "$app_path/Contents/Resources/zh-Hans.lproj/Localizable.strings"
fi
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority array" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority:0 string $(uname -m)" "$app_path/Contents/Info.plist"
python3 scripts/prepare-update-bundle.py "$app_path"
python3 scripts/local-signing.py sign "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built: %s\n' "$app_path"
