"""Update bundle packaging regressions; no signing identities or network access."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load_script("prepare_update_bundle", "prepare-update-bundle.py")
SIGNING = load_script("local_update_signing", "local-signing.py")


def make_application(root, version="0.6.0"):
    app = root / "Menu Tidy.app"
    (app / "Contents/Resources").mkdir(parents=True)
    (app / "Contents/MacOS").mkdir()
    (app / "Contents/MacOS/MenuTidy").write_bytes(b"fixture executable")
    info = {
        "CFBundleIdentifier": "dev.hdh.MenuTidy",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "99",
        "LSArchitecturePriority": ["fixture-architecture"],
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": False,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUPublicEDKey": "public-fixture-key",
    }
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    return app, info


def make_framework(destination):
    """Pinned Sparkle 2.10's versioned structure with executable permissions."""
    version = destination / "Versions/B"
    version.mkdir(parents=True)
    (version / "Resources").mkdir()
    (version / "Resources/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.sparkle-project.Sparkle", "CFBundleVersion": "2064",
    }))
    for relative in (
        "Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
        "XPCServices/Installer.xpc/Contents/MacOS/Installer",
        "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    ):
        executable = version / relative
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(b"upstream fixture code")
        executable.chmod(0o755)
    (destination / "Versions/Current").symlink_to("B")
    (destination / "Sparkle").symlink_to("Versions/Current/Sparkle")
    (destination / "Resources").symlink_to("Versions/Current/Resources")
    (destination / "XPCServices").symlink_to("Versions/Current/XPCServices")
    return destination


class UpdateBundlePreparationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.app, self.original_info = make_application(self.root)
        self.source = make_framework(self.root / ".build/artifacts/sparkle/Sparkle/"
                                     "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")
        license_file = self.root / ".build/checkouts/Sparkle/LICENSE"
        license_file.parent.mkdir(parents=True)
        license_file.write_text("Sparkle upstream redistribution license fixture\n")
        self.root_patch = patch.object(PREPARE, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    @unittest.skipUnless(Path("/usr/bin/ditto").exists(), "Requires macOS ditto")
    def test_rebuild_preserves_versioned_framework_and_replaces_stale_code(self):
        destination = self.app / "Contents/Frameworks/Sparkle.framework"
        destination.mkdir(parents=True)
        (destination / "outdated-helper").write_text("stale code")
        with patch.object(PREPARE.platform, "machine", return_value="arm64"):
            PREPARE.prepare(self.app)
        self.assertFalse((destination / "outdated-helper").exists())
        self.assertTrue((destination / "Versions/Current").is_symlink())
        self.assertEqual((destination / "Versions/Current").readlink(), Path("B"))
        self.assertTrue((destination / "Sparkle").is_symlink())
        self.assertEqual((destination / "Sparkle").read_bytes(), b"upstream fixture code")
        for executable in destination.rglob("*"):
            if executable.is_file() and executable.read_bytes() == b"upstream fixture code":
                self.assertTrue(os.access(executable, os.X_OK), executable)
        self.assertEqual((self.app / "Contents/Resources/Sparkle-LICENSE.txt").read_text(),
                         "Sparkle upstream redistribution license fixture\n")

    @unittest.skipUnless(Path("/usr/bin/ditto").exists(), "Requires macOS ditto")
    def test_feed_tracks_architecture_and_channel_without_losing_security_settings(self):
        for version, channel in (("0.6.0", "stable"), ("0.6.0-preview.2", "preview")):
            for architecture in ("arm64", "x86_64"):
                with self.subTest(version=version, architecture=architecture):
                    expected = dict(self.original_info, CFBundleShortVersionString=version)
                    (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(expected))
                    with patch.object(PREPARE.platform, "machine", return_value=architecture):
                        PREPARE.prepare(self.app)
                    actual = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
                    self.assertEqual(actual.pop("SUFeedURL"),
                                     "https://raw.githubusercontent.com/cyruss648/menu-tidy/updates/"
                                     f"{channel}/appcast-{architecture}.xml")
                    self.assertEqual(actual, expected)

    def test_ambiguous_resolved_frameworks_fail_before_mutating_destination(self):
        make_framework(self.root / ".build/artifacts/sparkle/Other/"
                       "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework")
        original = (self.app / "Contents/Info.plist").read_bytes()
        with patch.object(PREPARE.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "single Sparkle framework"):
                PREPARE.prepare(self.app)
            run.assert_not_called()
        self.assertFalse((self.app / "Contents/Frameworks").exists())
        self.assertEqual((self.app / "Contents/Info.plist").read_bytes(), original)

    def test_missing_resolved_framework_does_not_silently_build_without_updater(self):
        shutil.rmtree(self.source)
        with patch.object(PREPARE.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "single Sparkle framework"):
                PREPARE.prepare(self.app)
            run.assert_not_called()

    def test_symlinked_destination_cannot_replace_external_files(self):
        external = self.root / "keep-framework"
        external.mkdir()
        sentinel = external / "keep.txt"
        sentinel.write_text("must survive")
        frameworks = self.app / "Contents/Frameworks"
        frameworks.mkdir()
        (frameworks / "Sparkle.framework").symlink_to(external, target_is_directory=True)
        with patch.object(PREPARE.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "symlinked framework"):
                PREPARE.prepare(self.app)
            run.assert_not_called()
        self.assertEqual(sentinel.read_text(), "must survive")

    @unittest.skipUnless(Path("/usr/bin/ditto").exists(), "Requires macOS ditto")
    def test_missing_license_fails_instead_of_distributing_without_notice(self):
        (self.root / ".build/checkouts/Sparkle/LICENSE").unlink()
        with self.assertRaisesRegex(SystemExit, "redistribution license"):
            PREPARE.prepare(self.app)


class NestedUpdateSigningTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.app, _ = make_application(self.root)
        self.framework = make_framework(self.app / "Contents/Frameworks/Sparkle.framework")
        self.commands = []

    def capture(self, arguments, **_kwargs):
        self.commands.append(arguments)
        return b""

    def test_nested_code_is_signed_before_containers_with_separate_host_requirement(self):
        identity = "A" * 40
        keychain = self.root / "fixture.keychain-db"
        host_requirement = 'identifier "dev.hdh.MenuTidy" and certificate leaf = H"' + identity + '"'
        environment = {"CODE_SIGN_IDENTITY": identity, "CODE_SIGN_KEYCHAIN": str(keychain),
                       "CODE_SIGN_REQUIREMENT": host_requirement}
        with patch.dict(os.environ, environment, clear=True), patch.object(SIGNING, "run", self.capture), \
                redirect_stdout(io.StringIO()):
            SIGNING.sign(self.app)
        signed = {Path(command[-1]): index for index, command in enumerate(self.commands)}
        framework_index = signed[self.framework]
        self.assertLess(framework_index, signed[self.app])
        expected_helpers = {
            self.framework / "Versions/B/XPCServices/Installer.xpc",
            self.framework / "Versions/B/XPCServices/Downloader.xpc",
            self.framework / "Versions/B/Autoupdate",
            self.framework / "Versions/B/Updater.app",
        }
        self.assertEqual(set(signed), expected_helpers | {self.framework, self.app})
        for helper in expected_helpers:
            with self.subTest(helper=helper.name):
                command = self.commands[signed[helper]]
                self.assertLess(signed[helper], framework_index)
                self.assertEqual(command[command.index("--options") + 1], "runtime")
                self.assertNotIn("--requirements", command)
                self.assertNotIn("--identifier", command)
                self.assertEqual(command[command.index("--sign") + 1], identity)
                self.assertEqual(command[command.index("--keychain") + 1], str(keychain))
        downloader = self.commands[signed[self.framework / "Versions/B/XPCServices/Downloader.xpc"]]
        self.assertIn("--preserve-metadata=entitlements", downloader)
        for container in (self.framework, self.app):
            self.assertNotIn("--options", self.commands[signed[container]])
        host = self.commands[signed[self.app]]
        self.assertEqual(host[host.index("--requirements") + 1], "=designated => " + host_requirement)
        self.assertNotIn("--entitlements", host)
        self.assertNotIn("--deep", host)

    def test_helper_signing_failure_never_signs_host_or_falls_back_to_ad_hoc(self):
        def fail_downloader(arguments, **kwargs):
            self.capture(arguments, **kwargs)
            if arguments[-1].endswith("Downloader.xpc"):
                raise SIGNING.SigningError("fixture nested signing failure")

        with patch.dict(os.environ, {"CODE_SIGN_IDENTITY": "B" * 40}, clear=True), \
                patch.object(SIGNING, "run", fail_downloader):
            with self.assertRaisesRegex(SIGNING.SigningError, "nested signing failure"):
                SIGNING.sign(self.app)
        self.assertFalse(any(command[-1] == str(self.app) for command in self.commands))
        self.assertFalse(any(command[command.index("--sign") + 1] == "-" for command in self.commands))

    def test_incomplete_framework_cannot_produce_successfully_signed_app(self):
        shutil.rmtree(self.framework / "Versions/B/Updater.app")
        with patch.dict(os.environ, {"CODE_SIGN_IDENTITY": "C" * 40}, clear=True), \
                patch.object(SIGNING, "run", self.capture):
            with self.assertRaisesRegex(SIGNING.SigningError, "Updater.app"):
                SIGNING.sign(self.app)
        self.assertFalse(any(command[-1] == str(self.app) for command in self.commands))

    def test_local_keychain_is_relocked_if_nested_signing_fails(self):
        with patch.object(SIGNING, "security_command") as security, \
                patch.object(SIGNING, "run", side_effect=SIGNING.SigningError("fixture failure")):
            with self.assertRaises(SIGNING.SigningError):
                SIGNING.sign_local(self.app, "D" * 40, "test-only-placeholder")
        operations = [call.args[0][0] for call in security.call_args_list]
        self.assertEqual(operations, ["unlock-keychain", "lock-keychain"])
        self.assertTrue(security.call_args_list[0].kwargs["secret"])

    def test_ad_hoc_development_build_also_signs_nested_code(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(SIGNING, "MANIFEST", self.root / "none.json"), \
                patch.object(SIGNING, "SIGNING_DIR", self.root / "no-identity"), \
                patch.object(SIGNING, "run", self.capture), redirect_stderr(io.StringIO()):
            SIGNING.sign(self.app)
        self.assertGreater(len(self.commands), 2)
        self.assertEqual(self.commands[-1][-1], str(self.app))
        self.assertTrue(all(command[command.index("--sign") + 1] == "-" for command in self.commands))

    def test_wrong_application_identifier_is_rejected_before_signing(self):
        info_path = self.app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = "example.other-app"
        info_path.write_bytes(plistlib.dumps(info))
        with patch.object(SIGNING, "run") as run:
            with self.assertRaisesRegex(SIGNING.SigningError, "bundle identifier"):
                SIGNING.sign(self.app)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
