#!/usr/bin/env python3
"""Fetch the exact Sparkle distribution used by SwiftPM, checking its pinned hash."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request


VERSION = "2.10.0"
URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-for-Swift-Package-Manager.zip"
# Sparkle's official 2.10.0 Package.swift binaryTarget checksum.
SHA256 = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
ROOT = Path(__file__).resolve().parents[1]


def fetch(output: Path) -> None:
    output = output.absolute()
    if output.is_symlink():
        raise SystemExit("The Sparkle output must not be a symlink")
    receipt = output / ".sparkle-distribution-sha256"
    required = ("sign_update", "generate_appcast", "generate_keys")
    if receipt.is_file() and receipt.read_text().strip() == SHA256 and all(
        (output / "bin" / name).is_file() for name in required
    ):
        print(f"Sparkle {VERSION} tools ready: {output / 'bin'}")
        return
    if output.exists() and any(output.iterdir()):
        raise SystemExit("Refusing to overwrite an unrecognized Sparkle tools directory")
    cache = ROOT / ".build/downloads"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"Sparkle-{VERSION}-spm.zip"
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        request = urllib.request.Request(URL, headers={"User-Agent": "MenuTidy-Build"})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read(100 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != SHA256:
            raise SystemExit("Sparkle distribution checksum mismatch; nothing extracted or executed")
        archive.write_bytes(data)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sparkle-extract-", dir=output.parent) as scratch:
        extracted = Path(scratch)
        # ditto preserves the executable bits and framework symlinks. Only this
        # hash-pinned official distribution is ever passed to the extractor.
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], check=True)
        candidates = list(extracted.glob("**/bin/sign_update"))
        if len(candidates) != 1:
            raise SystemExit("Unexpected Sparkle distribution layout")
        distribution = candidates[0].parent.parent
        if not all((distribution / "bin" / name).is_file() for name in required):
            raise SystemExit("Sparkle distribution is missing a required signing tool")
        output.mkdir(exist_ok=True)
        shutil.copytree(distribution / "bin", output / "bin", symlinks=True, dirs_exist_ok=True)
        receipt.write_text(SHA256 + "\n")
    print(f"Sparkle {VERSION} tools ready: {output / 'bin'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    fetch(parser.parse_args().output)
