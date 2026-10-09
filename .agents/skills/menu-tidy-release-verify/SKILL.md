---
name: menu-tidy-release-verify
description: Publish and safely install a Menu Tidy release when asked to commit, push, publish, or update the local app. Covers signed assets, Sparkle feeds, and runtime verification.
---

# Menu Tidy release and verified installation

## When to use

Use within this Menu Tidy repository when the user asks to release a version, push and publish, update `/Applications/Menu Tidy.app`, or verify a published artifact. Do not use for a source-only build, a preview without authorization to publish, or a release in a different checkout.

## Inputs and context

Resolve the repository root with `git rev-parse --show-toplevel` and run repository commands there. This skill lives at `.agents/skills/menu-tidy-release-verify/`; do not install or copy it into a user-wide skill directory. Accept the release version as an input, or derive the next version and increasing build number from the current metadata and published feeds.

1. Confirm `pwd`, `git rev-parse --show-toplevel`, current branch, `git status --short`, and `git rev-list --left-right --count main...origin/main`.
2. Read [the release guide](../../../docs/RELEASING.md), [the release script](../../../scripts/release.sh), and the current [version metadata](../../../Resources/Info.plist) before changing version metadata.
3. Determine whether the user authorizes commit, push/tag/release, and local app replacement. Treat these as distinct side effects.
4. Inspect Sparkle configuration before branch cleanup. `updates` is a service/feed branch, not an ordinary development branch.

## Procedure

1. Preserve unrelated existing work as requested; keep the release worktree clean before invoking the release script.
2. Update exact version/build metadata, changelog, and release documentation. Run `./scripts/check.sh --full` and record the result.
3. Commit and push `main`; verify exact remote commit and ahead/behind. If a connection failure is transient, retry once or with a bounded retry plan, then check remote refs.
4. Wait for the exact commit's arm64 and x86_64 GitHub Actions jobs. Use `gh run view <run-id> --json status,conclusion,jobs`; if it intermittently returns EOF, poll `gh api repos/cyruss648/menu-tidy/actions/runs/<run-id>` with bounded retries.
5. Run `./scripts/release.sh "$release_version"` only after its preconditions are met. Confirm the versioned GitHub Release is public and its stable/prerelease status matches the version channel and that the signed release/feed job completed.
6. Verify both architecture Sparkle feeds for the release channel and the complete public release asset set before touching the installed app: architecture ZIPs and SHA-256/metadata/EdDSA sidecars, checksum, EdDSA, designated requirement, deep/strict signatures, architecture, version/build, identity/update key, and binary hash.
7. For local installation, normal-quit Menu Tidy; require no running process and no `NativeVisibility`, `NativeSystemVisibility`, `HiddenItems`, or `ActiveJournal` journals. Stage the verified app, make a same-filesystem backup, atomically replace `/Applications/Menu Tidy.app` using [the verified-bundle installer](../../../scripts/install-bundle.py), and retain the backup. Install the verified public release bundle; `scripts/install.sh` rebuilds locally and is not a substitute for public-artifact verification.
8. Verify installation separately: installed version/build, binary hash, `codesign` deep/strict result, actual launch/UI state, and semantic preservation of `nativeTrayChoices.v1`, `itemRules.v1`, and `itemDrafts.v1`. Check persisted draft count if the release affects drafts.
9. If cleaning branches, verify containment first. Keep `main` and `updates` when the updater feed depends on `updates`.

## Efficiency plan

- Cache the exact commit, CI run IDs, release URL, and receipt locations as soon as each is known; query only the latest state thereafter.
- Use the project scripts and receipts rather than recreating verification logic.
- Do not download/install until remote CI, signed feed publication, and release asset presence are all green.
- Stop and report when an authorized side effect is missing; do not infer permission to publish or replace the local application.

## Pitfalls and fixes

- Tag exists but signed release/feed job is incomplete -> wait; tagging is not release completion.
- `procNotFound`, CUA timeout, or stale AX index after app transition -> re-query fresh process/app state; use signature/hash/version evidence rather than stale UI handles.
- `AssertionError: 1 drafts remain` after a draft-related release -> inspect the exact persisted record after restart, not just the current UI.
- `LibreSSL SSL_connect: SSL_ERROR_SYSCALL` or GitHub API EOF -> retry boundedly and verify remote refs/run status; do not mistake transient transport/status errors for release failure.
- Self-signed artifact -> state that it is not Apple-notarized; Apple-Silicon desktop acceptance does not prove Intel desktop behavior.

## Verification checklist

- [ ] Full local gate passed for the exact release commit.
- [ ] `main` is clean and aligned with `origin/main`.
- [ ] Both architecture CI jobs and signed publish/feed job passed.
- [ ] Release is public, matches the version channel, and has the expected eight assets.
- [ ] Public archive/feed signatures, hashes, identity, architecture, and version/build verified.
- [ ] Backup exists before replacement; no process or recovery journal was active.
- [ ] Installed hash/signature/version and preserved preference fields verified independently.
- [ ] Report distinguishes package verification, installation, and runtime acceptance.
