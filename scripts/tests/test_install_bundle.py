"""Isolated complete-bundle installation and rollback regressions."""

import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("install_bundle", SCRIPTS / "install-bundle.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


def make_app(parent, version):
    app = parent / "Menu Tidy.app"
    (app / "Contents/Resources").mkdir(parents=True)
    (app / "Contents/MacOS").mkdir()
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "dev.hdh.MenuTidy",
        "CFBundleExecutable": "MenuTidy",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": version,
    }))
    (app / "Contents/MacOS/MenuTidy").write_text(version)
    return app


class BundleInstallationTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.parent = self.root / "Applications"
        self.backups = self.root / "Backups"
        self.source = make_app(self.root / "Build", "2")
        self.target = make_app(self.parent, "1")
        self.original_inode = self.target.stat().st_ino
        (self.target / "Contents/Resources/removed.txt").write_text("old resource")
        self.processes = patch.object(INSTALL, "ensure_not_running").start()
        self.verify = patch.object(INSTALL, "verify_bundle", side_effect=INSTALL.validate_bundle).start()
        self.copy = patch.object(INSTALL, "copy_bundle",
                                 side_effect=lambda source, destination: shutil.copytree(
                                     source, destination, symlinks=True)).start()
        self.addCleanup(patch.stopall)

    def install(self):
        return INSTALL.install(self.source, self.parent, self.backups)

    def assert_original(self):
        self.assertEqual(self.target.stat().st_ino, self.original_inode)
        self.assertEqual((self.target / "Contents/MacOS/MenuTidy").read_text(), "1")
        self.assertEqual((self.target / "Contents/Resources/removed.txt").read_text(), "old resource")

    def assert_no_transaction(self):
        self.assertEqual(list(self.parent.glob(".MenuTidy-install-*")), [])

    def test_complete_replacement_removes_retired_resources_and_retains_backup(self):
        (self.source / "Contents/Resources/current.txt").write_text("current")
        (self.source / "Contents/Resources/link").symlink_to("current.txt")
        target, backup = self.install()
        self.assertEqual(target, self.target)
        self.assertFalse((target / "Contents/Resources/removed.txt").exists())
        self.assertEqual((target / "Contents/MacOS/MenuTidy").read_text(), "2")
        self.assertTrue((target / "Contents/Resources/link").is_symlink())
        self.assertEqual((backup / "Contents/Resources/removed.txt").read_text(), "old resource")
        self.assertEqual((backup / "Contents/MacOS/MenuTidy").read_text(), "1")
        self.assertEqual(self.processes.call_count, 2)
        staged = self.verify.call_args_list[0].args[0]
        self.assertEqual(staged.parent.parent, self.parent)
        self.assertEqual(self.verify.call_args_list[1].args[0], target)
        self.assert_no_transaction()

    def test_invalid_staged_signature_leaves_original_installed(self):
        self.verify.side_effect = INSTALL.InstallationError("invalid staged signature")
        with self.assertRaisesRegex(INSTALL.InstallationError, "invalid staged signature"):
            self.install()
        self.assert_original()
        self.assertFalse(self.backups.exists())
        self.assert_no_transaction()

    def test_invalid_installed_signature_rolls_back_original_directory(self):
        self.verify.side_effect = [None, INSTALL.InstallationError("installed verification failed")]
        with self.assertRaisesRegex(INSTALL.InstallationError, "原应用已恢复"):
            self.install()
        self.assert_original()
        self.assert_no_transaction()

    def test_install_rename_failure_restores_original_directory(self):
        rename = os.rename

        def fail_new_bundle(source, target):
            if source.name == "Menu Tidy.app" and source != self.target:
                raise OSError("fixture replacement failure")
            rename(source, target)

        with patch.object(INSTALL.os, "rename", side_effect=fail_new_bundle):
            with self.assertRaisesRegex(INSTALL.InstallationError, "原应用已恢复"):
                self.install()
        self.assert_original()
        self.assert_no_transaction()

    def test_interruption_after_either_successful_rename_restores_original(self):
        rename = os.rename
        for interrupted_step in (1, 2):
            with self.subTest(interrupted_step=interrupted_step):
                calls = 0

                def interrupt_after_rename(source, target):
                    nonlocal calls
                    rename(source, target)
                    calls += 1
                    if calls == interrupted_step:
                        raise KeyboardInterrupt("fixture signal after successful rename")

                with patch.object(INSTALL.os, "rename", side_effect=interrupt_after_rename):
                    with self.assertRaisesRegex(INSTALL.InstallationError, "原应用已恢复"):
                        self.install()
                self.assert_original()
                self.assert_no_transaction()

    def test_backup_failure_never_moves_original(self):
        copy = self.copy.side_effect

        def fail_backup(source, destination):
            if source == self.target:
                raise INSTALL.InstallationError("backup failed")
            copy(source, destination)

        self.copy.side_effect = fail_backup
        with patch.object(INSTALL.os, "rename") as rename:
            with self.assertRaisesRegex(INSTALL.InstallationError, "backup failed"):
                self.install()
            rename.assert_not_called()
        self.assert_original()
        self.assert_no_transaction()

    def test_app_starting_during_preparation_prevents_replacement(self):
        self.processes.side_effect = [None, INSTALL.InstallationError("app started during copy")]
        with patch.object(INSTALL.os, "rename") as rename:
            with self.assertRaisesRegex(INSTALL.InstallationError, "app started during copy"):
                self.install()
            rename.assert_not_called()
        self.assert_original()
        self.assert_no_transaction()

    def test_target_replaced_during_preparation_is_not_overwritten(self):
        external = self.root / "Original.app"

        def external_install(_app):
            os.rename(self.target, external)
            make_app(self.parent, "external")

        self.verify.side_effect = external_install
        with self.assertRaisesRegex(INSTALL.InstallationError, "准备期间已变化"):
            self.install()
        self.assertEqual((self.target / "Contents/MacOS/MenuTidy").read_text(), "external")
        self.assertEqual(external.stat().st_ino, self.original_inode)
        self.assert_no_transaction()

    def test_failed_fresh_install_does_not_leave_unverified_app(self):
        shutil.rmtree(self.target)
        self.verify.side_effect = [None, INSTALL.InstallationError("installed verification failed")]
        with self.assertRaisesRegex(INSTALL.InstallationError, "installed verification failed"):
            self.install()
        self.assertFalse(self.target.exists())
        self.assertFalse(self.backups.exists())
        self.assert_no_transaction()

    def test_failed_rollback_retains_original_in_recovery_directory(self):
        rename = os.rename
        self.verify.side_effect = [None, INSTALL.InstallationError("installed verification failed")]

        def fail_restore(source, target):
            if source.name == "Previous.app":
                raise OSError("fixture restore failure")
            rename(source, target)

        with patch.object(INSTALL.os, "rename", side_effect=fail_restore):
            with self.assertRaisesRegex(INSTALL.InstallationError, "自动回滚未完成"):
                self.install()
        transactions = list(self.parent.glob(".MenuTidy-install-*"))
        self.assertEqual(len(transactions), 1)
        previous = transactions[0] / "Previous.app"
        self.assertEqual(previous.stat().st_ino, self.original_inode)
        self.assertEqual((previous / "Contents/MacOS/MenuTidy").read_text(), "1")
        self.assertEqual(len(list(self.backups.glob("*/Menu Tidy.app"))), 1)

    def test_symlinked_target_cannot_replace_external_application(self):
        external = self.root / "External.app"
        os.rename(self.target, external)
        self.target.symlink_to(external, target_is_directory=True)
        with self.assertRaisesRegex(INSTALL.InstallationError, "符号链接"):
            self.install()
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(external.stat().st_ino, self.original_inode)
        self.copy.assert_not_called()

    def test_concurrent_installer_is_rejected(self):
        with INSTALL.installation_lock(self.parent):
            with self.assertRaisesRegex(INSTALL.InstallationError, "另一个安装操作"):
                self.install()
        self.assert_original()
        self.copy.assert_not_called()

    def test_backup_inside_app_is_rejected_without_recursive_copy(self):
        with self.assertRaisesRegex(INSTALL.InstallationError, "备份目录不能位于"):
            INSTALL.install(self.source, self.parent, self.target / "Contents/Backups")
        self.assert_original()
        self.copy.assert_not_called()


class NativeInstallerCommandTests(unittest.TestCase):
    def test_verification_checks_nested_code_and_strict_resources(self):
        with patch.object(INSTALL, "validate_bundle"), patch.object(INSTALL, "run") as run:
            INSTALL.verify_bundle(Path("/fixture/Menu Tidy.app"))
        run.assert_called_once_with(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                                     "/fixture/Menu Tidy.app"])

    def test_process_probe_failure_is_not_treated_as_quit(self):
        for returncode in (0, 2):
            with self.subTest(returncode=returncode), patch.object(INSTALL.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], returncode, stderr="")):
                with self.assertRaises(INSTALL.InstallationError):
                    INSTALL.ensure_not_running()

    @unittest.skipUnless(Path("/usr/bin/codesign").exists() and Path("/usr/bin/ditto").exists(),
                         "Requires macOS bundle signing tools")
    def test_real_signed_bundle_replacement_drops_previously_sealed_resource(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            source = make_app(root / "Build", "2")
            target = make_app(root / "Applications", "1")
            removed = target / "Contents/Resources/retired-sealed-resource.txt"
            removed.write_text("present only in the old signed bundle")
            for app in (source, target):
                executable = app / "Contents/MacOS/MenuTidy"
                shutil.copyfile("/usr/bin/true", executable)
                executable.chmod(0o755)
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)],
                               check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                INSTALL.verify_bundle(app)
            with patch.object(INSTALL, "ensure_not_running"):
                installed, backup = INSTALL.install(source, target.parent, root / "Backups")
            self.assertFalse(removed.exists())
            self.assertTrue((backup / "Contents/Resources/retired-sealed-resource.txt").exists())
            INSTALL.verify_bundle(installed)
            INSTALL.verify_bundle(backup)


if __name__ == "__main__":
    unittest.main()
