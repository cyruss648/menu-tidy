#!/usr/bin/env python3
"""Embed the resolved Sparkle framework and select this build's update feed."""

import argparse
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def prepare(app: Path) -> None:
    candidates = list((ROOT / ".build/artifacts/sparkle").glob(
        "*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    ))
    if len(candidates) != 1:
        raise SystemExit("Expected the single Sparkle framework resolved by SwiftPM")
    source = candidates[0]
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(exist_ok=True)
    destination = frameworks / "Sparkle.framework"
    if destination.is_symlink():
        raise SystemExit("Refusing to overwrite a symlinked framework destination")
    if destination.exists():
        shutil.rmtree(destination)
    # Preserve Apple's versioned framework symlinks and helper executable modes.
    subprocess.run(["/usr/bin/ditto", str(source), str(destination)], check=True)
    license_file = ROOT / ".build/checkouts/Sparkle/LICENSE"
    if not license_file.is_file():
        raise SystemExit("Sparkle's redistribution license is missing")
    shutil.copyfile(license_file, app / "Contents/Resources/Sparkle-LICENSE.txt")
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    arch = platform.machine()
    if arch not in ("arm64", "x86_64"):
        raise SystemExit(f"Unsupported update architecture: {arch}")
    channel = "preview" if "-" in info["CFBundleShortVersionString"] else "stable"
    info["SUFeedURL"] = (
        "https://raw.githubusercontent.com/cyruss648/menu-tidy/updates/"
        f"{channel}/appcast-{arch}.xml"
    )
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    prepare(parser.parse_args().app)
