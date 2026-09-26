#!/usr/bin/env python3
"""Validate release archives, sign updates and advance separate Sparkle channels.

Secrets only enter the official pinned sign_update binary through stdin. Its
output is captured even on error, because upstream error text can include a key.
The app's public key independently verifies both archives and complete appcasts.
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)
ARCHES = ('arm64', 'x86_64')
CHANNELS = ('stable', 'preview')
REPOSITORY = 'cyruss648/menu-tidy'
VERSION = re.compile(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\Z')
SIGNATURE_BLOCK = re.compile(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n\Z')


def fail(message):
    raise ValueError(message)


def decoded_base64(value, size):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        fail('Invalid signing data encoding')
    if len(data) != size or base64.b64encode(data).decode() != value:
        fail('Invalid signing data size or encoding')
    return data


def version_parts(value):
    match = VERSION.fullmatch(value)
    if not match:
        fail('Application version must be a canonical semantic version')
    prerelease = match[4]
    if prerelease and any(part.isdigit() and len(part) > 1 and part.startswith('0')
                          for part in prerelease.split('.')):
        fail('Numeric prerelease identifiers must not have leading zeros')
    return tuple(int(part) for part in match.groups()[:3]), prerelease


def compare_versions(first, second):
    first_core, first_pre = version_parts(first)
    second_core, second_pre = version_parts(second)
    if first_core != second_core:
        return (first_core > second_core) - (first_core < second_core)
    if first_pre == second_pre:
        return 0
    if first_pre is None or second_pre is None:
        return 1 if first_pre is None else -1
    for left, right in zip(first_pre.split('.'), second_pre.split('.')):
        if left == right:
            continue
        if left.isdigit() and right.isdigit():
            return (int(left) > int(right)) - (int(left) < int(right))
        if left.isdigit() != right.isdigit():
            return -1 if left.isdigit() else 1
        return (left > right) - (left < right)
    return (len(first_pre.split('.')) > len(second_pre.split('.'))) - (len(first_pre.split('.')) < len(second_pre.split('.')))


def release_identity(info, tag, commit):
    version = info['CFBundleShortVersionString']
    _, prerelease = version_parts(version)
    if tag != 'v' + version:
        fail('Release tag does not exactly match application version')
    build = info['CFBundleVersion']
    if not isinstance(build, str) or not re.fullmatch(r'[1-9][0-9]*', build):
        fail('Build must be a positive monotonically increasing integer')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        fail('Release commit must be a full SHA-1')
    if info['LSMinimumSystemVersion'] not in ('13.0', '13.0.0'):
        fail('Update minimum macOS must match the supported macOS 13 baseline')
    if info['CFBundleIdentifier'] != 'dev.hdh.MenuTidy':
        fail('Unexpected bundle identifier')
    decoded_base64(info['SUPublicEDKey'], 32)
    if info.get('SURequireSignedFeed') is not True or info.get('SUVerifyUpdateBeforeExtraction') is not True:
        fail('App must require signed feeds and verification before extraction')
    return version, build, 'preview' if prerelease else 'stable'


def feed_url(channel, arch):
    return f'https://raw.githubusercontent.com/{REPOSITORY}/updates/{channel}/appcast-{arch}.xml'


def read_info(path):
    return plistlib.loads(path.read_bytes())


def regular_file(path):
    if path.is_symlink() or not path.is_file():
        fail('Release input must be a regular file: ' + path.name)


def load_package(directory, info, tag, commit, arch):
    version, build, channel = release_identity(info, tag, commit)
    if arch not in ARCHES:
        fail('Unsupported architecture')
    name = f'Menu-Tidy-{version}-macos-{arch}.zip'
    archive = directory / name
    for path in (archive, Path(str(archive) + '.sha256'), Path(str(archive) + '.metadata.json')):
        regular_file(path)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum = Path(str(archive) + '.sha256').read_text().strip().split()
    if checksum != [digest, name]:
        fail('Archive checksum or checksum filename mismatch')
    metadata = json.loads(Path(str(archive) + '.metadata.json').read_text())
    required = {
        'version': version, 'build': build, 'architecture': arch,
        'minimumMacOS': info['LSMinimumSystemVersion'],
        'bundleIdentifier': info['CFBundleIdentifier'], 'commit': commit,
        'archive': name, 'sha256': digest, 'sparklePublicKey': info['SUPublicEDKey'],
        'sparkleFeedURL': feed_url(channel, arch),
    }
    if any(metadata.get(key) != value for key, value in required.items()) or metadata.get('dirty') is not False:
        fail('Package metadata does not match this release')
    if not re.search(r'certificate leaf = H"[0-9A-Fa-f]{40}"', metadata.get('designatedRequirement', '')):
        fail('Package lacks a certificate-pinned signing identity')
    with zipfile.ZipFile(archive) as zipped:
        names = zipped.namelist()
        if len(names) != len(set(names)):
            fail('Archive contains duplicate entries')
        info_name = 'Menu Tidy.app/Contents/Info.plist'
        binary_name = 'Menu Tidy.app/Contents/MacOS/MenuTidy'
        for member in (info_name, binary_name):
            entry = zipped.getinfo(member)
            if stat.S_ISLNK(entry.external_attr >> 16):
                fail('Archive identity files must not be symlinks')
        embedded = plistlib.loads(zipped.read(info_name))
        for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleIdentifier',
                    'LSMinimumSystemVersion', 'SUPublicEDKey', 'SURequireSignedFeed',
                    'SUVerifyUpdateBeforeExtraction'):
            if embedded.get(key) != info.get(key):
                fail('Archived Info.plist differs from release configuration')
        if embedded.get('SUFeedURL') != feed_url(channel, arch):
            fail('Archived update channel or architecture feed is incorrect')
        if hashlib.sha256(zipped.read(binary_name)).hexdigest() != metadata.get('binarySHA256'):
            fail('Archived executable hash does not match package metadata')
    return archive, metadata


def signer_input():
    # Do not include the secret or tool stderr in exception messages.
    value = os.environ.get('SPARKLE_PRIVATE_KEY', '').strip()
    if not value:
        fail('SPARKLE_PRIVATE_KEY is required; refusing an unsigned update')
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        fail('SPARKLE_PRIVATE_KEY is not valid signing material')
    # Official Sparkle 2.10 common_cli/Secret.swift: new seed or legacy keypair.
    if len(raw) not in (32, 96) or '\n' in value or '\r' in value:
        fail('SPARKLE_PRIVATE_KEY is not valid signing material')
    return (value + '\n').encode()


def run_signer(tool, path, verify_signature=None, verify_feed=False):
    args = [str(tool), '--ed-key-file', '-']
    if verify_signature is not None or verify_feed:
        args += ['--verify', str(path)]
        if verify_signature is not None:
            args.append(verify_signature)
    else:
        args += ['-p', str(path)]
    environment = os.environ.copy()
    environment.pop('SPARKLE_PRIVATE_KEY', None)
    result = subprocess.run(args, input=signer_input(), capture_output=True, env=environment, check=False)
    if result.returncode:
        fail('Official Sparkle signing or verification failed')
    return result.stdout.decode().strip()


def verify_public(info_path, path, signature):
    decoded_base64(signature, 64)
    environment = os.environ.copy()
    environment.pop('SPARKLE_PRIVATE_KEY', None)
    result = subprocess.run(['/usr/bin/swift', str(ROOT / 'scripts/verify-update-signature.swift'),
                             str(info_path), str(path), signature], capture_output=True, env=environment, check=False)
    if result.returncode:
        fail('Update is not signed by the public key embedded in the app')


def signed_feed_content(data):
    match = SIGNATURE_BLOCK.search(data)
    if not match or data.count(b'<!-- sparkle-signatures:') != 1:
        fail('Missing or ambiguous official Sparkle feed signature')
    content = data[:match.start()]
    if len(content) != int(match[2]):
        fail('Signed feed byte count is incorrect')
    return content, match[1].decode()


def verify_feed_public(info_path, path):
    content, signature = signed_feed_content(path.read_bytes())
    with tempfile.TemporaryDirectory(prefix='menu-tidy-feed-verify-') as temporary:
        content_path = Path(temporary) / 'content'
        content_path.write_bytes(content)
        verify_public(info_path, content_path, signature)
    return content


def sign_archive(args):
    info = read_info(args.info)
    archive, _ = load_package(args.artifacts, info, args.tag, args.commit, args.arch)
    signature = run_signer(args.sign_tool, archive)
    decoded_base64(signature, 64)
    run_signer(args.sign_tool, archive, verify_signature=signature)
    verify_public(args.info, archive, signature)
    sidecar = {
        'archive': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
        'length': archive.stat().st_size, 'edSignature': signature,
        'publicKey': info['SUPublicEDKey'],
    }
    Path(str(archive) + '.eddsa.json').write_text(json.dumps(sidecar, indent=2) + '\n')
    print('Signed and independently verified ' + archive.name)


def previous_identity(content):
    if b'<!DOCTYPE' in content or b'<!ENTITY' in content:
        fail('Feed must not contain document types or entities')
    root = ET.fromstring(content)
    items = root.findall('./channel/item')
    if root.tag != 'rss' or len(items) != 1:
        fail('Expected exactly one current update per architecture feed')
    item = items[0]
    version = item.findtext(f'{{{SPARKLE}}}shortVersionString', '')
    version_parts(version)
    build = item.findtext(f'{{{SPARKLE}}}version', '')
    if not re.fullmatch(r'[1-9][0-9]*', build):
        fail('Previous feed build is invalid')
    return version, int(build)


def check_advancement(previous, version, build, channel):
    # One integer sequence across both channels prevents accidental downgrade
    # when a preview user later moves back to a newer stable release.
    if any(int(build) <= old_build for _, old_build in previous.values()):
        fail('Build must increase beyond every previously published channel')
    if channel in previous and compare_versions(version, previous[channel][0]) <= 0:
        fail('Version must increase within its update channel')


def make_feed(version, build, channel, arch, sidecar, notes, date):
    rss = ET.Element('rss', {'version': '2.0'})
    feed = ET.SubElement(rss, 'channel')
    ET.SubElement(feed, 'title').text = f'Menu Tidy {channel} ({arch})'
    ET.SubElement(feed, 'link').text = f'https://github.com/{REPOSITORY}'
    ET.SubElement(feed, 'description').text = 'Menu Tidy application updates'
    item = ET.SubElement(feed, 'item')
    ET.SubElement(item, 'title').text = f'Menu Tidy {version}'
    ET.SubElement(item, 'link').text = f'https://github.com/{REPOSITORY}/releases/tag/v{version}'
    ET.SubElement(item, 'pubDate').text = date
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '13.0.0'
    if arch == 'arm64':
        ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
    ET.SubElement(item, 'description', {f'{{{SPARKLE}}}format': 'plain-text'}).text = notes
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{REPOSITORY}/releases/download/v{version}/{sidecar["archive"]}',
        'length': str(sidecar['length']), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': sidecar['edSignature'],
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding='utf-8', xml_declaration=True) + b'\n'


def read_published_identities(info_path, feeds):
    previous = {}
    for previous_channel in CHANNELS:
        paths = [feeds / previous_channel / f'appcast-{arch}.xml' for arch in ARCHES]
        if any(path.exists() for path in paths):
            identities = []
            for path in paths:
                regular_file(path)
                identities.append(previous_identity(verify_feed_public(info_path, path)))
            if identities[0] != identities[1]:
                fail('Published architecture feeds disagree on version or build')
            if ('preview' if version_parts(identities[0][0])[1] else 'stable') != previous_channel:
                fail('Published feed is in the wrong channel')
            previous[previous_channel] = identities[0]
    return previous


def generate_feeds(args):
    info = read_info(args.info)
    version, build, channel = release_identity(info, args.tag, args.commit)
    signer_input()  # Fail before writing output when CI signing is not configured.
    expected = set()
    packages = {}
    requirements = set()
    for arch in ARCHES:
        archive, metadata = load_package(args.artifacts, info, args.tag, args.commit, arch)
        expected.update(archive.name + suffix for suffix in ('', '.sha256', '.metadata.json', '.eddsa.json'))
        sidecar_path = Path(str(archive) + '.eddsa.json')
        regular_file(sidecar_path)
        sidecar = json.loads(sidecar_path.read_text())
        required = {'archive': archive.name, 'length': archive.stat().st_size,
                    'sha256': metadata['sha256'], 'publicKey': info['SUPublicEDKey']}
        if any(sidecar.get(key) != value for key, value in required.items()):
            fail('Archive signing sidecar does not match release payload')
        verify_public(args.info, archive, sidecar['edSignature'])
        packages[arch] = sidecar
        requirements.add(metadata['designatedRequirement'])
    if {path.name for path in args.artifacts.iterdir()} != expected:
        fail('Release payload contains missing or unexpected files')
    if len(requirements) != 1:
        fail('Architectures must use identical code-signing requirements')
    previous = read_published_identities(args.info, args.feeds)
    check_advancement(previous, version, build, channel)
    notes = args.notes.read_text()
    if not notes.strip():
        fail('Release notes must not be empty')
    date = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    # Finish both signed feeds in scratch before replacing either channel file.
    with tempfile.TemporaryDirectory(prefix='menu-tidy-feeds-') as temporary:
        completed = []
        for arch in ARCHES:
            path = Path(temporary) / f'appcast-{arch}.xml'
            path.write_bytes(make_feed(version, build, channel, arch, packages[arch], notes, date))
            run_signer(args.sign_tool, path)
            run_signer(args.sign_tool, path, verify_feed=True)
            verify_feed_public(args.info, path)
            completed.append(path)
        destination = args.feeds / channel
        destination.mkdir(parents=True, exist_ok=True)
        for path in completed:
            (destination / path.name).write_bytes(path.read_bytes())
    print(f'Prepared signed {channel} feeds for {version} build {build}; nothing published')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('sign', 'generate'))
    parser.add_argument('--info', type=Path, default=ROOT / 'Resources/Info.plist')
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--sign-tool', type=Path, required=True)
    parser.add_argument('--arch', choices=ARCHES)
    parser.add_argument('--feeds', type=Path)
    parser.add_argument('--notes', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'sign':
            if not args.arch:
                parser.error('sign requires --arch')
            sign_archive(args)
        else:
            if not args.feeds or not args.notes:
                parser.error('generate requires --feeds and --notes')
            generate_feeds(args)
    except (ValueError, KeyError, OSError, ET.ParseError, zipfile.BadZipFile):
        # JSON, plist and upstream signer errors must not echo untrusted material.
        print('Update generation failed; metadata, signing, or version advancement validation did not pass.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
