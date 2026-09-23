#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 0 ]; then
  echo 'Usage: scripts/package.sh (version comes from Resources/Info.plist)' >&2
  exit 2
fi
./scripts/build.sh release
python3 - <<'PY'
import hashlib
import json
import platform
import plistlib
import re
import subprocess
from pathlib import Path

app = Path('dist/Menu Tidy.app')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
    raise SystemExit('Invalid release version')
arch = platform.machine()
if arch not in ('arm64', 'x86_64'):
    raise SystemExit(f'Unsupported architecture: {arch}')
binary = app / 'Contents/MacOS/MenuTidy'
actual_arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
if actual_arch != arch:
    raise SystemExit(f'Expected native {arch} binary, found {actual_arch}')
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
archive = app.parent / f'Menu-Tidy-{version}-macos-{arch}.zip'
if archive.exists():
    archive.unlink()
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
Path(str(archive) + '.sha256').write_text(f'{digest}  {archive.name}\n')
commit = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True, check=False)
dirty = subprocess.run(['git', 'status', '--porcelain'], capture_output=True, text=True, check=False)
signature = subprocess.run(['codesign', '-d', '-r-', str(app)], capture_output=True, text=True, check=True)
metadata = {
    'version': version, 'build': info['CFBundleVersion'], 'architecture': arch,
    'minimumMacOS': info['LSMinimumSystemVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
    'commit': commit.stdout.strip() if commit.returncode == 0 else None,
    'dirty': bool(dirty.stdout.strip()), 'archive': archive.name, 'sha256': digest,
    'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
    'designatedRequirement': '\n'.join(line for line in (signature.stdout + signature.stderr).splitlines()
                                      if line.startswith('designated =>')),
    'notarized': False,
}
Path(str(archive) + '.metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(f'Packaged: {archive} ({arch})\nSHA256: {digest}')
PY
