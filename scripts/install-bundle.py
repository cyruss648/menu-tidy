#!/usr/bin/env python3
"""Install a verified app as a complete bundle, with backup and rollback."""

import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile


BUNDLE_ID = "dev.hdh.MenuTidy"
APP_NAME = "Menu Tidy.app"


class InstallationError(Exception):
    pass


def run(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, check=False)
    if result.returncode:
        raise InstallationError(result.stderr.strip() or f"操作失败（退出码 {result.returncode}）。")


def ensure_not_running():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "MenuTidy"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, text=True, check=False)
    if result.returncode == 0:
        raise InstallationError("请先在 Menu Tidy 设置中退出应用，再执行安装。")
    if result.returncode != 1:
        raise InstallationError("无法确认 Menu Tidy 已退出，已停止安装。")


def validate_bundle(app):
    if app.is_symlink() or not app.is_dir():
        raise InstallationError(f"应用必须是实际目录，不能是符号链接：{app}")
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise InstallationError(f"无法读取应用身份：{app}") from error
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise InstallationError(f"同名应用的身份不同，已停止安装：{app}")


def verify_bundle(app):
    validate_bundle(app)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])


def copy_bundle(source, destination):
    # Every destination is fresh. ditto must never merge into the installed app.
    if destination.exists() or destination.is_symlink():
        raise InstallationError(f"复制目标必须不存在：{destination}")
    run(["/usr/bin/ditto", str(source), str(destination)])


@contextmanager
def installation_lock(parent):
    descriptor = os.open(parent / ".MenuTidy-install.lock",
                         os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise InstallationError("安装锁不是普通文件，已停止安装。")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise InstallationError("另一个安装操作正在进行，请稍后重试。") from error
        yield
    finally:
        # Keep this inode in place so another installer cannot lock a new file
        # while an existing waiter still holds the old one.
        os.close(descriptor)


def target_identity(target):
    if not target.exists() and not target.is_symlink():
        return None
    validate_bundle(target)
    info = target.stat()
    return info.st_dev, info.st_ino


def file_identity(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    return info.st_dev, info.st_ino


def install(app, parent, backup_parent):
    if not parent.is_absolute():
        raise InstallationError("安装目录必须是非空的绝对路径。")
    validate_bundle(app)
    parent.mkdir(parents=True, exist_ok=True)
    parent = parent.resolve()
    target = parent / APP_NAME
    if app.resolve() == target:
        raise InstallationError("待安装应用不能是当前安装目标。")
    if any(backup_parent.resolve().is_relative_to(bundle)
           for bundle in (app.resolve(), target)):
        raise InstallationError("备份目录不能位于待安装或现有的应用包内。")
    with installation_lock(parent):
        ensure_not_running()
        original_identity = target_identity(target)
        # A rename from here to the target always stays on the same filesystem.
        transaction = Path(tempfile.mkdtemp(prefix=".MenuTidy-install-", dir=parent))
        staged = transaction / APP_NAME
        previous = transaction / "Previous.app"
        backup = None
        keep_transaction = False
        staged_identity = None
        try:
            copy_bundle(app, staged)
            verify_bundle(staged)
            staged_identity = file_identity(staged)
            if original_identity is not None:
                backup_parent.mkdir(parents=True, exist_ok=True)
                backup_directory = Path(tempfile.mkdtemp(
                    prefix=datetime.now().strftime("Menu Tidy-%Y%m%d-%H%M%S-"), dir=backup_parent))
                backup = backup_directory / APP_NAME
                try:
                    copy_bundle(target, backup)
                except BaseException:
                    shutil.rmtree(backup_directory)
                    raise
            # Build, copying and signature checks may take time. Recheck as late
            # as possible, before either rename can disturb the installed app.
            ensure_not_running()
            if target_identity(target) != original_identity:
                raise InstallationError("现有应用在安装准备期间已变化，已停止替换。")
            if original_identity is not None:
                os.rename(target, previous)
            os.rename(staged, target)
            verify_bundle(target)
        except BaseException as error:
            try:
                # A signal can arrive after rename succeeds but before Python
                # updates a flag. Recover from the actual directory identities,
                # including when interruption occurs during either rename.
                moved_original = file_identity(previous) is not None
                if staged_identity is not None and file_identity(target) == staged_identity:
                    os.rename(target, staged)
                if moved_original:
                    if file_identity(target) is not None:
                        raise InstallationError("安装目标已被其他操作占用，未覆盖该目录。")
                    os.rename(previous, target)
            except BaseException as rollback_error:
                keep_transaction = True
                raise InstallationError(
                    f"安装失败且自动回滚未完成。请保留恢复目录：{transaction}；"
                    f"备份：{backup}。回滚错误：{rollback_error}") from error
            if moved_original:
                raise InstallationError(f"安装失败，原应用已恢复：{error}") from error
            raise
        finally:
            if not keep_transaction:
                try:
                    shutil.rmtree(transaction)
                except OSError:
                    # Cleanup happens only after verification or rollback. Do
                    # not disguise a successful install, or mask its real error.
                    print(f"未能清理安装临时目录，请保留或稍后删除：{transaction}", file=sys.stderr)
        return target, backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("install_parent", type=Path)
    parser.add_argument("--backup-dir", type=Path,
                        default=Path.home() / "Library/Application Support/Menu Tidy/Backups")
    arguments = parser.parse_args()
    try:
        target, backup = install(arguments.app, arguments.install_parent, arguments.backup_dir)
    except (InstallationError, OSError, KeyboardInterrupt) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Installed: {target}")
    if backup is not None:
        print(f"Backup: {backup}")
    print("请从此路径打开应用并申请辅助功能权限。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
