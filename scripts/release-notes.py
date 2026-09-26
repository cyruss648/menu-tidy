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
    print("\n### 软件内更新与首次安装\n")
    print("已包含更新器的版本，可在「权限与设置 → 软件更新」点击「检查更新…」，")
    print("由程序下载、验证并安装新版本；也可设置是否自动检查更新、自动下载并在退出时安装。")
    print("更新保留图标分类与偏好设置；后台菜单栏操作结束后才会进行更新安装。")
    print("尚无「软件更新」入口的旧版本，需要先按下方步骤安装一次含更新器的新版本；")
    print("此后的更新即可在软件内完成，无需每次手动下载替换应用。")
    print("\n### 下载与验证\n")
    print(f"Apple Silicon 下载 `Menu-Tidy-{version}-macos-arm64.zip`，")
    print(f"Intel 下载 `Menu-Tidy-{version}-macos-x86_64.zip`。")
    print("同时下载对应 `.sha256`，在同一目录运行 `shasum -a 256 -c <文件名>.sha256`。")
    print("退出旧实例后，将解压得到的 Menu Tidy.app 移到 /Applications，按界面引导授权辅助功能。")
    print("macOS 27 的后台位置调整另需点击「授权排序目录…」，在系统选择器中确认已定位的 Preferences 目录；无需完整磁盘访问。")
    print("使用独立图标栏还需屏幕录制权限；图像只在内存中处理，不上传、不存盘、不采集声音。")
    if "-" in version:
        print("\n本版本为预览版，发布到独立的预览更新渠道，不会覆盖正式渠道。")
    else:
        print("\n本版本发布到正式更新渠道。预览版本使用独立的预览更新渠道。")
    print("使用项目专用自签名证书，未经过 Apple 公证；更新归档和更新列表均使用 EdDSA 签名并验证。")
    print("macOS 27 的图标栏显示最近采集的原始快照，隐藏期间不会实时更新。")
    print("macOS 27 通过身份明确对应的系统排序记录逐项隐藏；采集图像和点击时会让单个图标临时可见，")
    print("不移动用户鼠标，不发送全局模拟键鼠事件。点击只向原始辅助功能对象请求一次受支持的动作，")
    print("确认原生菜单打开后等待其关闭，再恢复隐藏，不补发模拟点击。结束隐藏管理或正常退出时条件恢复原记录，")
    print("外部改动不会被强行覆盖；未完成的恢复保留记录。不支持或未确认成功的分类继续保留为待应用草稿。")
    print("macOS 27 的原生 ⌘ 拖拽整理前先恢复受管理隐藏项，完成后根据边界确认分类，再执行并验证后台隐藏。")
    print("排序记录读回或动作返回成功不等于图标已经隐藏或菜单已经出现，实际兼容性以验证记录为准。")
    print("最低部署目标为 macOS 13；独立窗口捕获需要 macOS 14+，区域快照需要 macOS 15.2+。")
    print("本机代表性应用的验证不等同于所有应用、旧系统或多显示器场景均兼容。")
    source = f"https://github.com/cyruss648/menu-tidy/blob/{args.tag}"
    print(f"\n[完整使用说明]({source}/README.md) · [后台方案与验证边界]({source}/docs/BACKGROUND-INPUT.md) · [历史验证记录]({source}/docs/ICON-PANEL-VERIFICATION.md)")


if __name__ == "__main__":
    main()
