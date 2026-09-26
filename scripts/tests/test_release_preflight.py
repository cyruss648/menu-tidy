import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_update_feed import COMMIT, SIGNATURE, fixture_info

SCRIPT = Path(__file__).resolve().parents[1] / 'release-preflight.py'
SPEC = importlib.util.spec_from_file_location('release_preflight', SCRIPT)
PREFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT)


class LocalReleasePreflightTests(unittest.TestCase):
    def test_local_identity_uses_exact_final_feed_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Resources').mkdir()
            for version in ('01.2.3', '1.2.3-rc..1', '1.2.3-01'):
                (root / 'Resources/Info.plist').write_bytes(plistlib.dumps(fixture_info(version)))
                with patch.object(PREFLIGHT, 'git_output', return_value=COMMIT.encode()):
                    with self.assertRaises(ValueError):
                        PREFLIGHT.validate_local(root, 'v' + version)
            (root / 'Resources/Info.plist').write_bytes(plistlib.dumps(fixture_info()))
            with patch.object(PREFLIGHT, 'git_output', return_value=COMMIT.encode()):
                self.assertEqual(PREFLIGHT.validate_local(root, 'v1.2.3'), ('1.2.3', '42', 'stable'))

    def test_local_only_does_not_contact_remote(self):
        with patch.object(PREFLIGHT, 'validate_local', return_value=('1.2.3', '42', 'stable')), \
                patch.object(PREFLIGHT, 'copy_remote_feeds') as remote:
            self.assertEqual(PREFLIGHT.check_release(Path('/fixture'), 'v1.2.3', True), ('1.2.3', '42', 'stable'))
            remote.assert_not_called()

    def test_only_explicit_absent_branch_is_first_release(self):
        with patch.object(PREFLIGHT, 'run_git', return_value=subprocess.CompletedProcess([], 2, b'', b'')) as run:
            self.assertFalse(PREFLIGHT.copy_remote_feeds(Path('/fixture'), Path('/destination')))
            self.assertEqual(run.call_count, 1)
        for status, stdout in [(1, b''), (128, b''), (2, b'unexpected'), (0, b'wrong ref')]:
            with self.subTest(status=status, stdout=stdout), \
                    patch.object(PREFLIGHT, 'run_git', return_value=subprocess.CompletedProcess([], status, stdout, b'private diagnostic')):
                with self.assertRaises(ValueError) as failure:
                    PREFLIGHT.copy_remote_feeds(Path('/fixture'), Path('/destination'))
                self.assertNotIn('private diagnostic', str(failure.exception))

    def test_existing_empty_branch_cannot_reset_version_baseline(self):
        with patch.object(PREFLIGHT, 'validate_local', return_value=('1.2.3', '42', 'stable')), \
                patch.object(PREFLIGHT, 'copy_remote_feeds', return_value=True), \
                patch.object(PREFLIGHT.FEED, 'read_published_identities', return_value={}):
            with self.assertRaisesRegex(ValueError, 'no feeds'):
                PREFLIGHT.check_release(Path('/fixture'), 'v1.2.3')

    def test_preflight_rejects_old_build_or_nonincreasing_version(self):
        for previous in ({'stable': ('1.2.2', 42)}, {'stable': ('1.2.3', 41)},
                         {'preview': ('1.3.0-rc.1', 43)}):
            with self.subTest(previous=previous), \
                    patch.object(PREFLIGHT, 'validate_local', return_value=('1.2.3', '42', 'stable')), \
                    patch.object(PREFLIGHT, 'copy_remote_feeds', return_value=True), \
                    patch.object(PREFLIGHT.FEED, 'read_published_identities', return_value=previous):
                with self.assertRaises(ValueError):
                    PREFLIGHT.check_release(Path('/fixture'), 'v1.2.3')

    def test_signature_failure_is_not_treated_as_no_previous_feed(self):
        with patch.object(PREFLIGHT, 'validate_local', return_value=('1.2.3', '42', 'stable')), \
                patch.object(PREFLIGHT, 'copy_remote_feeds', return_value=True), \
                patch.object(PREFLIGHT.FEED, 'read_published_identities', side_effect=ValueError('signature rejected')):
            with self.assertRaisesRegex(ValueError, 'signature rejected'):
                PREFLIGHT.check_release(Path('/fixture'), 'v1.2.3')

    def test_git_errors_and_environment_do_not_expose_update_secret(self):
        with patch.dict(PREFLIGHT.os.environ, {'SPARKLE_PRIVATE_KEY': 'private fixture'}), \
                patch.object(PREFLIGHT.subprocess, 'run', return_value=subprocess.CompletedProcess([], 128, b'', b'private fixture')) as run:
            with self.assertRaises(ValueError) as failure:
                PREFLIGHT.git_output(Path('/fixture'), 'rev-parse', 'HEAD')
            self.assertNotIn('private fixture', str(failure.exception))
            self.assertNotIn('SPARKLE_PRIVATE_KEY', run.call_args.kwargs['env'])
            self.assertEqual(run.call_args.kwargs['env']['GIT_TERMINAL_PROMPT'], '0')

    def test_credential_url_is_rejected_before_fetch(self):
        result = subprocess.CompletedProcess([], 0, (COMMIT + '\trefs/heads/updates\n').encode(), b'')
        for remote in ('https://private-fixture@github.com/owner/repo.git',
                       'ssh://git:private-fixture@github.com/owner/repo.git'):
            with self.subTest(remote=remote), patch.object(PREFLIGHT, 'run_git', return_value=result), \
                    patch.object(PREFLIGHT, 'git_output', return_value=remote.encode()):
                with self.assertRaises(ValueError) as failure:
                    PREFLIGHT.copy_remote_feeds(Path('/fixture'), Path('/destination'))
                self.assertNotIn('private-fixture', str(failure.exception))


class RemoteFeedReadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote = self.root / 'remote source'
        self.local = self.root / 'local source'
        self.destination = self.root / 'copied feeds'
        for directory in (self.remote, self.local):
            directory.mkdir()
            self.git(directory, 'init', '--quiet', '--initial-branch=updates')
        self.git(self.local, 'remote', 'add', 'origin', str(self.remote))
        self.destination.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, directory, *arguments):
        return subprocess.run(['git', '-C', str(directory), '-c', 'user.name=Fixture',
                               '-c', 'user.email=fixture@example.invalid', *arguments],
                              capture_output=True, check=True).stdout

    def commit(self):
        self.git(self.remote, 'add', '.')
        self.git(self.remote, 'commit', '--quiet', '-m', 'controlled feed fixture')

    def write_feed(self, arch, version='1.2.2', build='41'):
        path = self.remote / 'stable' / f'appcast-{arch}.xml'
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(PREFLIGHT.FEED.make_feed(version, build, 'stable', arch,
                         {'archive': 'fixture.zip', 'length': 1, 'edSignature': SIGNATURE}, 'fixture notes', 'date'))

    def test_fetch_copies_only_allowed_feed_blobs_without_checkout_or_local_refs(self):
        for arch in PREFLIGHT.FEED.ARCHES:
            self.write_feed(arch)
        (self.remote / 'unexpected-script.sh').write_text('exit 1\n')
        self.commit()
        before = self.git(self.local, 'for-each-ref')
        self.assertTrue(PREFLIGHT.copy_remote_feeds(self.local, self.destination))
        self.assertEqual(self.git(self.local, 'for-each-ref'), before)
        self.assertEqual({str(path.relative_to(self.destination)) for path in self.destination.rglob('*') if path.is_file()},
                         {'stable/appcast-arm64.xml', 'stable/appcast-x86_64.xml'})
        self.assertFalse((self.destination / '.git').exists())
        with patch.object(PREFLIGHT.FEED, 'verify_feed_public', side_effect=lambda _, path: path.read_bytes()):
            self.assertEqual(PREFLIGHT.FEED.read_published_identities(Path('/fixture/Info.plist'), self.destination),
                             {'stable': ('1.2.2', 41)})

    def test_symlink_feed_is_rejected_without_following_target(self):
        (self.remote / 'stable').mkdir()
        (self.remote / 'stable/appcast-arm64.xml').symlink_to('/private/not-a-feed')
        self.commit()
        with self.assertRaisesRegex(ValueError, 'regular files'):
            PREFLIGHT.copy_remote_feeds(self.local, self.destination)

    def test_architecture_disagreement_is_rejected_by_shared_parser(self):
        self.write_feed('arm64')
        self.write_feed('x86_64', '1.2.1', '40')
        self.commit()
        PREFLIGHT.copy_remote_feeds(self.local, self.destination)
        with patch.object(PREFLIGHT.FEED, 'verify_feed_public', side_effect=lambda _, path: path.read_bytes()):
            with self.assertRaisesRegex(ValueError, 'disagree'):
                PREFLIGHT.FEED.read_published_identities(Path('/fixture/Info.plist'), self.destination)


if __name__ == '__main__':
    unittest.main()
