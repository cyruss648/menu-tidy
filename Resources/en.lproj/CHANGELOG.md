# Release summaries

English summaries of the bundled release history. Full implementation details and the original validation records are available in the repository changelog. Historical validation applies only to the version, hardware, and scenarios stated in those records.

## [Unreleased]

## [0.7.11] - 2026-11-14

Fixed discovery of native tray applications such as BLEUnlock when a macOS environment change occurs before startup rebinding has been queued.

- Continue using saved non-visible application bundle identifiers as scan hints when the saved macOS environment marker is missing or differs from the current system.
- Scanning still requires a live application process and a current menu bar identity; the environment hint never creates an online icon or promotes an offline record.
- Added a startup ordering regression test for an environment change observed after startup rebinding was evaluated.

Verification: `./scripts/check.sh --full` passed before release. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.10] - 2026-11-14

Fixed rediscovery of native tray items after a macOS upgrade while Menu Tidy is already running, including applications such as BLEUnlock.

- Record the macOS startup environment and schedule a delayed native tray rebind when that environment changes, with bounded retries while system state settles.
- Use saved non-visible application bundle identifiers as startup discovery hints. The scanner still verifies a live process and a current menu bar identity before publishing an item.
- Apply startup tray choices after native rebinding completes, preserving existing classifications, drafts, and saved tray choices.

Verification: `./scripts/check.sh --full` passed 109 Python tests, 530 core Swift tests, 152 application integration tests, and the warnings-as-errors build. Release signing uses the project's self-signed identity and is not Apple-notarized.

## [0.7.9] - 2026-11-10

Restore automatic discovery when an accessory application's launch notification is missing.

- Observe changes to the system running application list and enqueue the existing bounded discovery retries for each new process lifetime.
- Unchanged membership does not restart exhausted attempts. Departure removes old retries, and shutdown releases the observation.
- Keep hidden-source identity discovery and native-menu exit recovery, without adding periodic accessibility scans.

Verification, upgrade, and desktop acceptance are recorded in the launch discovery report. Uses the existing self-signed release identity and is not Apple-notarized.

## [0.7.8] - 2026-11-10

- Fixed discovery of newly launched hidden applications while Menu Tidy is already running.
- Direct status items in a currently managed application's own extras root can supply identity without usable on-screen geometry. Such geometry never authorizes clicks or proves visibility or placement.
- Added bounded read-only discovery retries during the first 15 seconds after launch. Discovery stops on success, process exit, or exhaustion and waits for active native operations.
- Saved classifications and drafts remain intact. Added regression coverage for hidden-source boundaries, delayed status creation, bounded retries, and reconnection. Full checks passed 109 Python tests, 529 core Swift tests, and 147 application integration tests. In-app upgrade and installed desktop acceptance are recorded separately. Signing uses the project's self-signed identity without Apple notarization.

## [0.7.7] - 2026-11-10

- Fixed a recovery error that prevented other tray icons from opening after quitting an application from its native menu.
- Confirmed process exit ends observation of the old menu and releases temporary visibility ownership. Saved classifications remain available for rediscovery after relaunch.
- Added coverage for quitting, replacement process epochs, exit during cleanup, and opening another icon afterward. Uncertain menu states and actual restoration failures retain recovery protection.
- Full checks passed 109 Python tests, 520 core Swift tests, and 143 application integration tests. In-app upgrade and installed Maccy interaction acceptance are recorded separately after publication. Release signing uses the project's self-signed identity without Apple notarization.

## [0.7.6] - 2026-11-04

- Localized dynamic status, progress, warnings, recovery details, and nested application errors. Stored messages follow language changes; external application names and system data remain unchanged.
- Added English resources and offline summaries for every historical version, corrected format argument forwarding, and applied the selected language to date formatting.
- Added localization gates for bare Chinese literals, missing/duplicate translations, empty or untranslated English values, format placeholders, and release history coverage. Commit, push, CI, and packaging checks validate the complete source/catalog relationship.
- Theme and language changes update existing windows and tray views, preserving scroll positions and presentation state. Automated native window tests cover these transitions; installed visual acceptance remained unavailable while the desktop was locked. Release signing continues to use the project's self-signed identity without Apple notarization.

## [0.7.5] - 2026-11-04

- Fixed returning from Light to System appearance and expanded English translations for the settings, tray, update controls, and menus. Dynamic model messages still had gaps; those are addressed by the subsequent localization work.

## [0.7.4] - 2026-11-04

- Added configurable update checks at 5, 10, or 30 minutes, or 1, 6, or 24 hours, with a 30-minute default. Menu Tidy schedules intervals below Sparkle's one-hour minimum.

## [0.7.3] - 2026-11-04

- Fixed rediscovery and reconnection of hidden applications after a Homebrew update restarts their processes. Original tray choices are preserved while the new process is discovered. Automated regression coverage does not establish acceptance of every installed Homebrew update scenario.

## [0.7.2] - 2026-11-03

- Tray icons now prefer native application icons, then verified menu bar snapshots, then name markers. Updated source tooltips and documentation; screen recording remains an optional enhancement.

## [0.7.1] - 2026-10-29

- Refined the Warm Paper visual design with a warm white icon, charcoal organization bars, and a muted teal tray marker. Settings and tray surfaces share light and dark palettes. Installed visual acceptance remained separate from source, build, and preview checks.

## [0.7.0] - 2026-10-29

- Redesigned the app icon and management interface. Added persistent System, Light, and Dark themes and Chinese/English preferences across settings, the tray, and menus. Source and package checks passed; installed interactions still required separate acceptance.

## [0.6.19] - 2026-10-29

- Fixed original-image refresh for third-party icons hidden by the native macOS 27 backend. Each app is temporarily revealed, identified, captured, and hidden again independently. Identity, geometry, display, and process checks remain in place. Intel, older macOS, and final installed Clash Verge capture required separate acceptance.

## [0.6.18] - 2026-10-29

- Added a persistent PNG cache for verified tray images. Cache entries include identity, dimensions, display layout, appearance, and age checks. Cache failures do not change rules, drafts, or native tray choices.

## [0.6.17] - 2026-10-29

- Fixed lingering native visibility assertions after forgetting apps or changing groups. Reconciled persistent choices with runtime ownership and released assertions when no hidden targets remain. Recorded installed checks covered macOS 27 on Apple Silicon; other platforms and modules required separate acceptance.

## [0.6.16] - 2026-10-27

- Added the macOS 27 MenuBarClientCore assessment backend to control application-level visibility. Individual temporary reveals keep other apps hidden. Existing rules, drafts, and system icon recovery records are preserved. Unavailable or unconfirmed backend results remain pending.

## [0.6.15] - 2026-10-16

- Fixed recovery after locking from a tray menu and the first click after unlocking. Preserved classifications, rules, and drafts. Recorded native acceptance covered the tested Apple Silicon session; Intel and older macOS remained outside that evidence.

## [0.6.14] - 2026-10-15

- Paused maintenance, reconnection, and image capture while the desktop is locked or inactive. After unlocking, refresh once before reconciling pending work. Confirmed results and user drafts survive interrupted operations and duplicate session notifications.

## [0.6.13] - 2026-10-15

- Added periodic background reconciliation and native multi-application batches. Preserved display choices, rules, and drafts while reusing serialized operation and recovery boundaries.

## [0.6.12] - 2026-10-15

- Fixed native hiding for Atoll and duplicate pending counts for a single application. Old sources with matching choices are consumed only after all current application icons are actually confirmed.

## [0.6.11] - 2026-10-14

- Fixed duplicate settings rows for Clash Verge and Live Activities. Preserved classifications, rules, and drafts.

## [0.6.10] - 2026-10-14

- Fixed item counts increasing after repeated refreshes, stale names, inconsistent row spacing, and large blank regions in the management list.

## [0.6.9] - 2026-10-09

- Fixed the independent tray opening on the primary display after clicking its menu bar control on a secondary display.

## [0.6.8] - 2026-10-09

- Fixed incomplete tray sizing on its first opening, including layouts that previously corrected themselves only after pointer movement. Preserved existing classifications and preferences.

## [0.6.7] - 2026-10-08

- Added a delayed startup attempt to refresh and apply pending choices, approximately 30 seconds after launch. Busy operations defer the attempt; failed scans do not apply stale lists. Each launch attempts reconciliation once.

## [0.6.6] - 2026-10-04

- Made menu bar scanning layered and incremental. Slow or timed-out owners retain the last successful list. Scan failures and skipped image verification are reported separately. Added owner scheduling, process lifetime, and snapshot reconciliation regressions.

## [0.6.5] - 2026-10-02

- Preserved mixed legacy choices during automatic connection, restored offline application choices to the saved list, and restarted auto-collapse delays after long operations. Installation now stages and verifies a fresh bundle before atomic replacement and rollback.

## [0.6.4] - 2026-10-01

- Added increasing retry delays for missing images, scheduled maintenance only when needed, reduced unnecessary view publications, and released closed settings views after 30 seconds while preserving presentation choices. Recorded resource measurements were specific to the tested macOS 27 Apple Silicon setup.

## [0.6.3] - 2026-09-30

- Fixed verified ownership matching for helper processes such as WPS Office Service. Added bulk deletion and undo for unlinked drafts. Removed duplicate session drafts after confirmation and supported underscores in real application identifiers.

## [0.6.2] - 2026-09-30

- Added offline in-app release history, GitHub releases, and issue reporting links to update settings.

## [0.6.1] - 2026-09-30

- Fixed scanning across multiple displays and added verified AirDrop and input source tray identities and independent recovery. Clash Verge opens its application window by default; native icon actions remain separately available. Recorded native acceptance covered the stated macOS 27 dual-display environment.

## [0.6.0] - 2026-09-29

- Unified icon management and failure retries. In-app updates preserve display choices and update preferences.

## [0.5.0] - 2026-09-27

- Introduced a Windows-style independent tray for everyday operations and redesigned hiding and recovery on macOS 27. Separate Apple Silicon and Intel packages were provided.

## [0.4.1] - Unreleased diagnostic version

- Historical diagnostic implementation from September 24, 2026, build 11. This version was not published as a GitHub Release. Its simulated drag path was superseded by the background architecture in 0.5.0; its validation does not establish acceptance of later versions.

## [0.4.0] - 2026-09-23

- Added native ⌘-drag grouping with temporary Always Hidden and Collapse boundaries. Clicking the Menu Tidy control finishes arrangement and collapses the menu bar.

## [0.3.1] - 2026-09-23

- Fixed CI signing identity discovery by adding the dedicated temporary keychain to the user search list.

## [0.3.0] - 2026-09-23

- The signing release job for this tag failed and produced no downloadable GitHub Release. Source and CI records are retained; the next public release used 0.3.1.

## [0.2.3] - 2026-09-23

- Historical summary predating this repository's public Git history. Distinguished native menu bar hosts from actual application owners during macOS 27 scanning, removed mirrored duplicates, and protected the system overflow recovery control.
