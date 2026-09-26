import argparse
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'generate-update-feed.py'
SPEC = importlib.util.spec_from_file_location('update_feed', SCRIPT)
FEED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FEED)
# RFC 8032 Ed25519 test vector 1, public material only.
PUBLIC_KEY = base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode()
SIGNATURE = base64.b64encode(bytes.fromhex(
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555f'
    'b8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')).decode()
COMMIT = 'a' * 40


def fixture_info(version='1.2.3', build='42'):
    return {
        'CFBundleShortVersionString': version, 'CFBundleVersion': build,
        'CFBundleIdentifier': 'dev.hdh.MenuTidy', 'LSMinimumSystemVersion': '13.0',
        'SUPublicEDKey': PUBLIC_KEY, 'SURequireSignedFeed': True,
        'SUVerifyUpdateBeforeExtraction': True,
    }


def create_package(directory, arch='arm64', info=None):
    info = dict(info or fixture_info())
    version = info['CFBundleShortVersionString']
    channel = 'preview' if '-' in version else 'stable'
    info['SUFeedURL'] = FEED.feed_url(channel, arch)
    archive = directory / f'Menu-Tidy-{version}-macos-{arch}.zip'
    binary = b'controlled executable fixture'
    with zipfile.ZipFile(archive, 'w') as zipped:
        zipped.writestr('Menu Tidy.app/Contents/Info.plist', plistlib.dumps(info))
        zipped.writestr('Menu Tidy.app/Contents/MacOS/MenuTidy', binary)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    Path(str(archive) + '.sha256').write_text(digest + '  ' + archive.name + '\n')
    metadata = {
        'version': version, 'build': info['CFBundleVersion'], 'architecture': arch,
        'minimumMacOS': info['LSMinimumSystemVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
        'commit': COMMIT, 'dirty': False, 'archive': archive.name, 'sha256': digest,
        'binarySHA256': hashlib.sha256(binary).hexdigest(),
        'sparklePublicKey': PUBLIC_KEY, 'sparkleFeedURL': info['SUFeedURL'],
        'designatedRequirement': 'designated => identifier "dev.hdh.MenuTidy" and certificate leaf = H"' + 'B' * 40 + '"',
    }
    Path(str(archive) + '.metadata.json').write_text(json.dumps(metadata))
    sidecar = {'archive': archive.name, 'length': archive.stat().st_size,
               'sha256': digest, 'edSignature': SIGNATURE, 'publicKey': PUBLIC_KEY}
    Path(str(archive) + '.eddsa.json').write_text(json.dumps(sidecar))
    return archive, metadata


class ReleaseIdentityTests(unittest.TestCase):
    def test_preview_and_stable_are_explicit_and_distinct(self):
        self.assertEqual(FEED.release_identity(fixture_info(), 'v1.2.3', COMMIT), ('1.2.3', '42', 'stable'))
        self.assertEqual(FEED.release_identity(fixture_info('1.2.4-rc.1'), 'v1.2.4-rc.1', COMMIT)[2], 'preview')
        self.assertNotEqual(FEED.feed_url('stable', 'arm64'), FEED.feed_url('preview', 'arm64'))
        self.assertNotEqual(FEED.feed_url('stable', 'arm64'), FEED.feed_url('stable', 'x86_64'))

    def test_release_identity_rejects_noncanonical_versions_builds_and_unsecured_apps(self):
        cases = [('CFBundleShortVersionString', '01.2.3'), ('CFBundleShortVersionString', '1.2.3-rc.01'),
                 ('CFBundleShortVersionString', '1.2.3+test'), ('CFBundleVersion', '0'),
                 ('CFBundleVersion', '42.0'), ('CFBundleVersion', 42), ('CFBundleVersion', '042'),
                 ('SUPublicEDKey', ''), ('CFBundleIdentifier', 'other'),
                 ('LSMinimumSystemVersion', '12.0'), ('SURequireSignedFeed', False),
                 ('SUVerifyUpdateBeforeExtraction', False)]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                info = fixture_info()
                info[key] = value
                with self.assertRaises(ValueError):
                    FEED.release_identity(info, 'v' + str(info['CFBundleShortVersionString']), COMMIT)
        for tag, commit in [('v1.2.4', COMMIT), ('v1.2.3', 'abc123')]:
            with self.assertRaises(ValueError):
                FEED.release_identity(fixture_info(), tag, commit)

    def test_semver_order_handles_numeric_prerelease_and_final_release(self):
        ordered = ['1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta',
                   '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '1.0.1']
        for left, right in zip(ordered, ordered[1:]):
            self.assertLess(FEED.compare_versions(left, right), 0)
            self.assertGreater(FEED.compare_versions(right, left), 0)
        self.assertEqual(FEED.compare_versions('1.0.0', '1.0.0'), 0)

    def test_channel_cannot_go_backwards_even_with_new_build(self):
        previous = {'stable': ('1.2.3', 42), 'preview': ('1.3.0-rc.1', 43)}
        for version, build, channel in [('1.2.4', '43', 'stable'), ('1.2.2', '44', 'stable'),
                                         ('1.2.3', '44', 'stable'), ('1.3.0-beta.1', '44', 'preview')]:
            with self.subTest(version=version, build=build):
                with self.assertRaises(ValueError):
                    FEED.check_advancement(previous, version, build, channel)
        FEED.check_advancement(previous, '1.2.4', '44', 'stable')
        FEED.check_advancement(previous, '1.3.0-rc.2', '44', 'preview')


class PackageValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.archive, self.metadata = create_package(self.directory)

    def tearDown(self):
        self.temporary.cleanup()

    def load(self):
        return FEED.load_package(self.directory, fixture_info(), 'v1.2.3', COMMIT, 'arm64')

    def test_matching_archive_and_metadata_pass(self):
        self.assertEqual(self.load()[0], self.archive)

    def test_archive_mutation_or_checksum_filename_mismatch_fails(self):
        self.archive.write_bytes(self.archive.read_bytes() + b'tampered')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.load()
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        Path(str(self.archive) + '.sha256').write_text(digest + '  wrong.zip\n')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.load()

    def test_provenance_and_key_or_architecture_mismatch_fails(self):
        metadata_path = Path(str(self.archive) + '.metadata.json')
        for key, value in [('version', '1.2.4'), ('build', '43'), ('architecture', 'x86_64'),
                           ('commit', 'b' * 40), ('dirty', True), ('archive', 'wrong.zip'),
                           ('sparklePublicKey', base64.b64encode(b'x' * 32).decode()),
                           ('sparkleFeedURL', FEED.feed_url('preview', 'arm64')),
                           ('binarySHA256', '0' * 64), ('designatedRequirement', 'adhoc')]:
            with self.subTest(field=key):
                changed = dict(self.metadata)
                changed[key] = value
                metadata_path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    self.load()
        metadata_path.write_text(json.dumps(self.metadata))

    def replace_embedded_info(self, mutation):
        with zipfile.ZipFile(self.archive) as zipped:
            entries = {name: zipped.read(name) for name in zipped.namelist()}
        name = 'Menu Tidy.app/Contents/Info.plist'
        info = plistlib.loads(entries[name])
        info.update(mutation)
        entries[name] = plistlib.dumps(info)
        with zipfile.ZipFile(self.archive, 'w') as zipped:
            for name, data in entries.items():
                zipped.writestr(name, data)
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        Path(str(self.archive) + '.sha256').write_text(digest + '  ' + self.archive.name + '\n')
        self.metadata['sha256'] = digest
        Path(str(self.archive) + '.metadata.json').write_text(json.dumps(self.metadata))

    def test_actual_archive_key_must_match_configuration_even_when_sidecars_match(self):
        self.replace_embedded_info({'SUPublicEDKey': base64.b64encode(b'x' * 32).decode()})
        with self.assertRaisesRegex(ValueError, 'Archived Info'):
            self.load()

    def test_actual_archive_feed_cannot_cross_architecture_or_channel(self):
        self.replace_embedded_info({'SUFeedURL': FEED.feed_url('stable', 'x86_64')})
        with self.assertRaisesRegex(ValueError, 'architecture feed'):
            self.load()

    def test_symlink_release_input_is_rejected(self):
        old = self.archive.with_suffix('.saved')
        self.archive.rename(old)
        self.archive.symlink_to(old)
        with self.assertRaisesRegex(ValueError, 'regular file'):
            self.load()


class SigningBoundaryTests(unittest.TestCase):
    def test_missing_secret_is_rejected(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, 'required'):
            FEED.signer_input()

    def test_signer_secret_only_travels_over_stdin_and_subprocess_errors_are_redacted(self):
        fixture = base64.b64encode(b'controlled fixture secret value!').decode()
        self.assertEqual(len(base64.b64decode(fixture)), 32)
        with patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY': fixture}), patch.object(FEED.subprocess, 'run') as run:
            run.return_value = subprocess.CompletedProcess([], 1, stdout=fixture.encode(), stderr=fixture.encode())
            with self.assertRaises(ValueError) as failure:
                FEED.run_signer(Path('/pinned/bin/sign_update'), Path('/fixture/archive.zip'))
            self.assertNotIn(fixture, str(failure.exception))
            positional, kwargs = run.call_args
            self.assertNotIn(fixture, repr(positional))
            self.assertEqual(kwargs['input'], (fixture + '\n').encode())
            self.assertNotIn('SPARKLE_PRIVATE_KEY', kwargs['env'])
            self.assertTrue(kwargs['capture_output'])

    def test_malformed_secret_is_never_echoed(self):
        for fixture in ['invalid key value', base64.b64encode(b'a' * 31).decode(), 'abc\ndef']:
            with self.subTest(length=len(fixture)), patch.dict(os.environ, {'SPARKLE_PRIVATE_KEY': fixture}):
                with self.assertRaises(ValueError) as failure:
                    FEED.signer_input()
                self.assertNotIn(fixture, str(failure.exception))

    def test_official_signature_block_requires_exact_signed_byte_length(self):
        content = b'<?xml version="1.0"?><rss/>\n'
        suffix = f'<!-- sparkle-signatures:\nedSignature: {SIGNATURE}\nlength: {len(content)}\n-->\n'.encode()
        self.assertEqual(FEED.signed_feed_content(content + suffix), (content, SIGNATURE))
        for changed in [content + suffix + b'extra', b'altered' + content + suffix,
                        content + suffix + suffix, content, content + suffix.replace(b'length:', b'size:')]:
            with self.subTest(changed=changed[-60:]), self.assertRaises(ValueError):
                FEED.signed_feed_content(changed)

    @unittest.skipUnless(sys.platform == 'darwin', 'CryptoKit public verifier requires macOS')
    def test_actual_cryptokit_verifier_accepts_rfc_vector_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            info_path = directory / 'Info.plist'
            info_path.write_bytes(plistlib.dumps(fixture_info()))
            content = directory / 'empty'
            content.write_bytes(b'')
            FEED.verify_public(info_path, content, SIGNATURE)
            content.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'public key'):
                FEED.verify_public(info_path, content, SIGNATURE)
            content.write_bytes(b'')
            wrong = fixture_info()
            wrong['SUPublicEDKey'] = base64.b64encode(b'x' * 32).decode()
            info_path.write_bytes(plistlib.dumps(wrong))
            with self.assertRaisesRegex(ValueError, 'public key'):
                FEED.verify_public(info_path, content, SIGNATURE)


class FeedGenerationTests(unittest.TestCase):
    def test_xml_escapes_notes_and_selects_immutable_correct_arch_asset(self):
        sidecar = {'archive': 'Menu-Tidy-1.2.3-macos-arm64.zip', 'length': 1234, 'edSignature': SIGNATURE}
        data = FEED.make_feed('1.2.3', '42', 'stable', 'arm64', sidecar, '<not HTML> & notes', 'date')
        root = ET.fromstring(data)
        item = root.find('./channel/item')
        self.assertEqual(item.find('description').text, '<not HTML> & notes')
        self.assertEqual(item.findtext(f'{{{FEED.SPARKLE}}}version'), '42')
        self.assertEqual(item.findtext(f'{{{FEED.SPARKLE}}}minimumSystemVersion'), '13.0.0')
        self.assertEqual(item.findtext(f'{{{FEED.SPARKLE}}}hardwareRequirements'), 'arm64')
        self.assertEqual(item.find('enclosure').attrib['url'],
                         'https://github.com/cyruss648/menu-tidy/releases/download/v1.2.3/' + sidecar['archive'])
        self.assertEqual(FEED.previous_identity(data), ('1.2.3', 42))

    def args(self, directory):
        artifacts = directory / 'artifacts'
        artifacts.mkdir()
        for arch in FEED.ARCHES:
            create_package(artifacts, arch)
        info = directory / 'Info.plist'
        info.write_bytes(plistlib.dumps(fixture_info()))
        notes = directory / 'notes.md'
        notes.write_text('Release fixture notes')
        return argparse.Namespace(info=info, tag='v1.2.3', commit=COMMIT, artifacts=artifacts,
                                  feeds=directory / 'feeds', notes=notes, sign_tool=Path('/fixture/sign_update'))

    def test_signing_failure_cannot_partially_advance_feeds(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = self.args(Path(temporary))
            destination = args.feeds / 'stable'
            destination.mkdir(parents=True)
            originals = []
            for arch in FEED.ARCHES:
                path = destination / f'appcast-{arch}.xml'
                original = FEED.make_feed('1.2.2', '41', 'stable', arch,
                                         {'archive': 'old.zip', 'length': 1, 'edSignature': SIGNATURE}, 'old', 'date')
                path.write_bytes(original)
                originals.append(original)
            with patch.object(FEED, 'signer_input'), patch.object(FEED, 'verify_public'), \
                    patch.object(FEED, 'verify_feed_public', side_effect=lambda _, path: path.read_bytes()), \
                    patch.object(FEED, 'run_signer', side_effect=ValueError('controlled failure')):
                with self.assertRaisesRegex(ValueError, 'controlled failure'):
                    FEED.generate_feeds(args)
            self.assertEqual([path.read_bytes() for path in sorted(destination.iterdir())], originals)

    def test_partial_previous_architecture_pair_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = self.args(Path(temporary))
            destination = args.feeds / 'stable'
            destination.mkdir(parents=True)
            path = destination / 'appcast-arm64.xml'
            path.write_bytes(FEED.make_feed('1.2.2', '41', 'stable', 'arm64',
                             {'archive': 'old.zip', 'length': 1, 'edSignature': SIGNATURE}, 'old', 'date'))
            with patch.object(FEED, 'signer_input'), patch.object(FEED, 'verify_public'), \
                    patch.object(FEED, 'verify_feed_public', side_effect=lambda _, path: path.read_bytes()):
                with self.assertRaisesRegex(ValueError, 'regular file'):
                    FEED.generate_feeds(args)

    def test_extra_release_payload_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = self.args(Path(temporary))
            (args.artifacts / 'unexpected.txt').write_text('unexpected')
            with patch.object(FEED, 'signer_input'), patch.object(FEED, 'verify_public'):
                with self.assertRaisesRegex(ValueError, 'unexpected files'):
                    FEED.generate_feeds(args)

    def test_modified_signature_sidecar_cannot_relabel_an_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = self.args(Path(temporary))
            sidecar = next(args.artifacts.glob('*.eddsa.json'))
            data = json.loads(sidecar.read_text())
            data['length'] += 1
            sidecar.write_text(json.dumps(data))
            with patch.object(FEED, 'signer_input'), patch.object(FEED, 'verify_public'):
                with self.assertRaisesRegex(ValueError, 'sidecar'):
                    FEED.generate_feeds(args)

    def test_previous_feed_cannot_hide_extra_update_items_or_entities(self):
        for data in [b'<rss><channel><item/><item/></channel></rss>',
                     b'<!DOCTYPE rss [<!ENTITY entity "bad">]><rss/>']:
            with self.assertRaises(ValueError):
                FEED.previous_identity(data)


if __name__ == '__main__':
    unittest.main()
