#!/usr/bin/env python3
"""Read-only release identity and signed remote-feed checks before creating a tag.

This checks release metadata, not desktop acceptance. Actual installed-app tests
remain a prerequisite for invoking the release script. No private key is needed.
"""

import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('menu_tidy_update_feed', ROOT / 'scripts/generate-update-feed.py')
FEED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FEED)
REF = 'refs/heads/updates'


def run_git(root, *arguments):
    environment = os.environ.copy()
    environment['GIT_TERMINAL_PROMPT'] = '0'
    environment.pop('SPARKLE_PRIVATE_KEY', None)
    try:
        return subprocess.run(['git', '-C', str(root), *arguments], capture_output=True,
                              env=environment, check=False, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('Git could not complete the read-only release preflight') from None


def git_output(root, *arguments):
    result = run_git(root, *arguments)
    if result.returncode:
        # Credential helpers and remote errors may include private URL data.
        raise ValueError('Git could not read release or update-branch metadata')
    return result.stdout


def validate_local(root, tag):
    commit = git_output(root, 'rev-parse', 'HEAD').decode().strip()
    info_path = root / 'Resources/Info.plist'
    info = FEED.read_info(info_path)
    return FEED.release_identity(info, tag, commit)


def copy_remote_feeds(root, directory):
    """Copy only four allowed blobs without checking out remote code or hooks."""
    result = run_git(root, 'ls-remote', '--exit-code', 'origin', REF)
    if result.returncode == 2 and not result.stdout.strip():
        return False
    if result.returncode != 0:
        raise ValueError('Cannot read the updates branch; network/auth failures are not a first release')
    if not re.fullmatch(rb'[0-9a-f]{40}\trefs/heads/updates\n?', result.stdout):
        raise ValueError('Unexpected updates branch reference')
    remote = git_output(root, 'remote', 'get-url', 'origin').decode().strip()
    # Never place a credential-bearing HTTPS URL into subprocess arguments.
    if not remote or remote.startswith('-') or any(character in remote for character in '\n\r\0'):
        raise ValueError('Invalid origin URL')
    parsed_remote = urlsplit(remote)
    if parsed_remote.password is not None or (parsed_remote.scheme in ('http', 'https')
                                              and parsed_remote.username is not None):
        raise ValueError('Use a Git credential helper instead of credentials embedded in origin URLs')
    with tempfile.TemporaryDirectory(prefix='menu-tidy-feed-source-') as temporary:
        scratch = Path(temporary)
        git_output(scratch, 'init', '--bare', '--quiet')
        git_output(scratch, 'fetch', '--quiet', '--depth=1', '--no-tags', remote, REF)
        entries = git_output(scratch, 'ls-tree', '-r', '-z', 'FETCH_HEAD')
        allowed = {f'{channel}/appcast-{arch}.xml' for channel in FEED.CHANNELS for arch in FEED.ARCHES}
        for entry in entries.split(b'\0'):
            if not entry:
                continue
            header, name_bytes = entry.split(b'\t', 1)
            name = name_bytes.decode('utf-8', errors='replace')
            if name in FEED.CHANNELS:
                raise ValueError('Published update channel must be a directory')
            if name not in allowed:
                continue
            mode, kind, _ = header.split()
            if kind != b'blob' or mode not in (b'100644', b'100755'):
                raise ValueError('Published update feeds must be regular files')
            content = git_output(scratch, 'show', f'FETCH_HEAD:{name}')
            target = directory / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
    return True


def check_release(root, tag, local_only=False):
    version, build, channel = validate_local(root, tag)
    if local_only:
        return version, build, channel
    with tempfile.TemporaryDirectory(prefix='menu-tidy-release-preflight-') as temporary:
        feeds = Path(temporary)
        exists = copy_remote_feeds(root, feeds)
        previous = FEED.read_published_identities(root / 'Resources/Info.plist', feeds)
        if exists and not previous:
            raise ValueError('Existing updates branch has no feeds; cannot prove version advancement')
        FEED.check_advancement(previous, version, build, channel)
    return version, build, channel


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--local-only', action='store_true', help='Validate local identity without accessing the remote')
    args = parser.parse_args()
    try:
        version, build, channel = check_release(ROOT, args.tag, args.local_only)
    except (ValueError, KeyError, OSError, FEED.ET.ParseError):
        print('Release preflight failed: local identity or signed remote-feed advancement is invalid; '
              'no tag was created or pushed.', file=sys.stderr)
        return 1
    scope = 'Local identity' if args.local_only else 'Local identity and signed remote-feed advancement'
    print(f'{scope} verified for {version} build {build} ({channel}); no tag created or pushed')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
