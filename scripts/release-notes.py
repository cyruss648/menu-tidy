#!/usr/bin/env python3
"""Extract an existing version section; never invent release notes or history."""

import argparse
from pathlib import Path
import plistlib
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="vX.Y.Z")
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", args.tag):
        parser.error("expected vX.Y.Z")
    root = Path(__file__).resolve().parent.parent
    version = args.tag[1:]
    info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
    if version != info["CFBundleShortVersionString"]:
        parser.error("tag and bundle version disagree")
    lines = (root / "CHANGELOG.md").read_text().splitlines()
    result = []
    active = False
    for line in lines:
        if line.startswith("## "):
            if active:
                break
            active = re.match(r"^## \[?v?" + re.escape(version) + r"(?:\]|\s|$)", line) is not None
        if active:
            result.append(line)
    if not result:
        parser.error("CHANGELOG.md has no matching release section")
    print("\n".join(result).strip())
    print("\n### 下载与验证\n")
    print("Apple Silicon 下载 `macos-arm64.zip`，Intel 下载 `macos-x86_64.zip`。")
    print("同时下载对应 `.sha256`，在同一目录运行 `shasum -a 256 -c <文件名>.sha256`。")
    print("解压后将 Menu Tidy.app 移到 /Applications，再按界面引导授权辅助功能。")
    print("\n本版本为预览版，使用项目专用自签名证书，未经过 Apple 公证。")
    print("macOS 27 刘海屏图标较多时，普通展开仍可能需要系统溢出入口；")
    print("完整限制与使用说明见 README，测试证据见 docs。")


if __name__ == "__main__":
    main()
