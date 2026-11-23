# Release summaries

English summaries of the bundled release history. Full implementation details and the original validation records are available in the repository changelog. Historical validation applies only to the version, hardware, and scenarios stated in those records.

## [Unreleased]

## [0.7.33] - 2026-11-23

- Fixed macOS 27 tray disconnections after display switches when native hidden assessment and old menu-bar connection evidence became invalid. Menu Tidy now delays assessment release, waits for menu-bar rebuilding, and uses bounded 2 / 5 / 12-second retries; still-running missing icons remain visible and enter low-frequency discovery.
- A display switch during reconnect cancels the invalidated attempt without consuming a retry. Saved categories are restored after rediscovery. Independent display recovery no longer interrupts a click waiting during unlock recovery, while ordinary open tray panels close on switch so they cannot retain an old screen reference.

Automated regression tests cover assessment release after display changes, late inventory, scan failure, repeated changes, interrupted reconnect, and panel closing. This Mac passed a BetterDisplay disconnect/reconnect check for the external display. A physical cable unplug/replug still needs a separate check. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.32] - 2026-11-21

- Fixed macOS 27 startup recovery and native menu-bar rebuilds reapplying hidden assessment too early, which could make saved hidden icons appear during recovery or be hidden against the replacement process.
- Temporarily release native hidden assessment during recovery, re-read the menu-bar inventory, then restore the saved classifications. Successful recovery also clears stale failed-owner entries so old failures do not block later retries.

Automated regression coverage includes native hidden-assessment release during recovery, inventory rebuilding, and failed-owner queue cleanup. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.31] - 2026-11-19

- Fixed a macOS 27 issue where clicking Retry after switching from an external monitor to the built-in display could empty the tray. Menu Tidy can rediscover icons that temporarily fall outside the menu bar area, match them to their current application processes, and keep their saved categories.
- Discard scan results from the previous display layout and rescan once consecutive display changes settle. A display change during unlock recovery keeps a waiting tray click queued until the rescan completes.

Automated regression tests cover icon rediscovery after Retry, consecutive display changes, and clicks queued during unlock recovery. Physical monitor reconnection and disconnection remain to be verified with an external display. Packages use the project's self-signed release certificate and have no Apple notarization.

## [0.7.30] - 2026-11-17

- Added a separate, opt-in “Automatically install and reopen when idle” option. With automatic checks and downloads enabled, a verified update can install and reopen Menu Tidy after five seconds of app inactivity.
- Installation waits while the desktop is locked, the tray or context menu is open, an icon operation is running, or recovery is incomplete. Normal termination and icon restoration remain required.
- Failed restoration pauses automatic attempts and keeps an explicit “Install and Reopen” retry. Disabling idle installation preserves any installation already scheduled for normal quit.
- Versions through 0.7.29 must install a newer version once using the existing updater before this option becomes available.

Validation and release/installation evidence are recorded separately in the idle update installation report. Releases retain the project signing identity and are not Apple-notarized.

## [0.7.29] - 2026-11-17

- Move running applications whose menu bar icons are disabled into Offline and Saved Records, labeled “No menu bar icon currently.” Keep their saved categories and exclude them from current icon counts and batch actions.
- Reconnect an icon enabled again in the same application process using its saved category. Previous successful connection attempts no longer block rediscovery; failed attempts retain their retry limits and confirmed hidden inventory remains protected.
- Stop showing a warning solely because a tray action opens no new menu or window. Screenshot, toggle, and no-op behaviors still receive exactly one native action.
- Keep warnings for rejected actions, missing permissions, and failed hiding restoration. Preserve temporary visibility while a target interface is still open or its state cannot be confirmed.

Verification: the full local gate for both fixes passed 110 Python, 540 Swift core, and 199 application integration tests, including absent icons, same-process rediscovery, actions without popups, real failures, and lock-screen recovery. The final version gate, dual architecture public packages, signed feeds, and installed third-party application acceptance are recorded separately in the repository's icon absence and quiet actions report. Uses the project's self-signed release identity and is not Apple notarized.

## [0.7.28] - 2026-11-16

- Reduce management rows from 79 pt to 48 pt and remove repeated automatic-apply hints. Normal rows center the name; processing, failures, and pending confirmation share a compact detail line.
- Remove the oversized blank area in Software Update caused by separate invisible placeholders for waiting and error messages.
- Share a compact two-line area for update results, last-check time, waiting reasons, and error summaries. Full text is available in update status details without expanding the settings card.
- Keep delayed activity indicators and a stable Check for Updates action. Real failures remain visible through warning text and an icon.

Verification: native layout regression covers narrow and wide cards, idle, waiting, checking, long errors, and recovery. Full gate, public package verification, and installed-app acceptance are recorded separately in the compact settings layout report. Uses the project's self-signed release identity and is not Apple notarized.

## [0.7.27] - 2026-11-16

- Stop treating missing optional original images as persistent “Needs attention” errors. The tray remains usable with app icons or names; snapshot gaps, offline records, and disabled screen recording no longer become global failures.
- Move original image counts to an explicit “View Original Image Status” action on the permissions page. They no longer appear automatically in the status bar or status details, or ask users to expand system overflow for normal use.
- Skip screenshot polling and background capture for entries that already have app icons. Grouped application sources only request fallback images for the displayed entry, reducing unnecessary reads.
- Image checks no longer clear independent operation errors or carry preparation issues across later checks. Grouping, permission recovery, and native menu failures retain their recovery actions.
- Correct the permission description to explain that verified original images may be cached locally.

Verification: the local full gate, dual architecture publication, and native acceptance of the installed public package are recorded separately in the repository's optional image status report. Uses the project's self-signed release identity and is not Apple notarized.

## [0.7.26] - 2026-11-16

- Delay transient activity indicators by 350 milliseconds so quick operations do not flash a loading message. Cancellation remains available immediately.
- Keep progress, results, and warning summaries in a fixed bottom status bar. Full explanations and recovery actions open in Status details without inserting content into the list.
- Reserve space for row details, actions, batch counts, search clearing, permission checks, and update feedback to preserve list height and reading position during refreshes and retries.
- Reuse the tray footer for progress and errors. Full error details and retry actions open in a popover; automatic collapse pauses while reading it, and retry dismisses it normally.
- Update the software update section immediately when the interface language changes.

Verification: the local full gate passed 110 Python, 540 Swift core, and 185 application integration tests. Native window regression tests cover delayed loading, scroll position, retries, and tray error popovers. The isolated preview was checked in Chinese and English, light and dark appearances, and permission feedback states. Public packages for both architectures, signed feeds, and installed-app acceptance are recorded separately; simulated preview data does not establish production acceptance. Uses the project's self-signed release identity and is not Apple notarized.

## [0.7.25] - 2026-11-16

- Recover when an icon is visible in the menu bar but Menu Tidy keeps waiting for discovery. An orderly relaunch requires repeated denied reads for the same application process and independent confirmation that the original icon is readable. Automatic recovery is limited to once per boot, with an explicit reconnect action available.
- Treat ordinary icon absence, including an icon disabled inside its application, as a neutral “No icon” state. Preserve its category, exclude it from outstanding and attention counts, and keep low-frequency discovery so an icon enabled later in the same process reconnects automatically.
- Fix successful connection attempts blocking rediscovery after startup recovery releases their confirmed hiding state. Ordinary automatic connections wait for the startup recovery window, and rejected connections retain their retry restrictions.
- Isolate an expired system icon source during startup batch application so other applications with valid process identities can continue. A changed application process still stops the old request.

Verification: the local full gate passed 110 Python, 540 Swift core, and 180 application integration tests. Native macOS arm64 candidate acceptance confirmed automatic category restoration for Sogou and other icons, a neutral state for the intentionally disabled mail icon, zero attention items, and unchanged categories, rules, and drafts. The tag workflow validates both architecture packages and signed feeds. Intel desktop interaction, a system cold boot, and the complete fault-triggered automatic relaunch path remain unverified. Uses the project's self-signed release identity and is not Apple notarized.

## [0.7.24] - 2026-11-15

- Preserve observed tray inventory for the exact owner process when native assessment removes its AX nodes; discard geometry and replace retained inventory when fresh nodes appear.
- Show running applications with missing icons as waiting for discovery, including them in outstanding counts rather than reporting them as protected system items.

## [0.7.23] - 2026-11-15

Extended startup tray protection to saved tray applications that launch or relaunch after Menu Tidy has already started.

- A saved application set to collapse or always hide now remains visible and receives persistent discovery retries as soon as its current process launches, until its status item is observed or the process exits.
- Boot login items, delayed login agents, and application relaunches now share the same persistent discovery path instead of falling back to a one-time retry window.
- Added regression coverage for runtime launches, persistent discovery, and process exit cleanup.

Verification: the full gate, dual architecture builds, signed feeds, public Release, and local installation acceptance will run after commit. Uses the project's self-signed release identity and is not Apple notarized.

## [0.7.22] - 2026-11-15

Fixed a gap after bounded startup recovery retries where a running application that created its status item later had no further discovery opportunity, leaving its saved tray choice unapplied or inconsistent.

- Running startup applications that are still absent from the accessibility inventory now receive low-frequency discovery retries until their current status item is observed or the process exits.
- The startup window still uses fast retries; after it ends, the application remains visible so Menu Tidy cannot hide an unconfirmed item again.
- Added persistent discovery regression coverage for the shared startup path used by BLEUnlock, WhatCable, Atoll, InputLock, MenuPiP, Mos, Bob, JetBrains Toolbox, and other login-launched tray applications.

Verification: the full gate, dual architecture builds, signed feeds, public Release, and local installation acceptance will run after commit. Uses the project's self-signed release identity and is not Apple notarized.

## [0.7.21] - 2026-11-15

Fixed startup recovery reapplying a saved hidden choice after its retry window ended even though the application was still running and its status item had not entered the AX inventory, which could make the icon disappear completely.

- Saved applications that are running but temporarily absent from the accessibility inventory remain visible until their status item is observed or the application exits.
- A bounded follow-up discovery remains scheduled for these applications; the saved visible, collapsible, or always hidden choice is reapplied only after the status item is found.
- Added regression coverage for applications that remain unobserved after the startup retry window, covering the shared path used by BLEUnlock, WhatCable, and other login launched tray applications.

Verification: startup recovery integration tests passed; the full gate, dual architecture builds, signed feeds, and public installation verification will run before release. Uses the project's self signed release identity and is not Apple notarized.

## [0.7.20] - 2026-11-15

Fixed macOS 27 startup recovery rehiding running native tray applications when their status items were created after the first accessibility scan.

- Startup recovery now keeps its protection active and retries within a bounded backoff window when a saved running application is still missing from the AX inventory.
- Saved native hiding choices are reapplied only after the inventory becomes complete or the bounded retries establish that an application has no discoverable status item.
- Added regression coverage for late status item creation across BLEUnlock, WhatCable, and other login launched tray applications.

Verification: full gate, dual architecture public release, signed feeds, and public artifact installation are recorded after completion. Uses the project's self signed release identity and is not Apple notarized.

## [0.7.19] - 2026-11-14

Fixed macOS 27 native tray applications being reported as “exited or unreadable” after restart or login recovery while MenuBarAgent rebuilt their accessibility nodes.

- The native assessment backend now confirms application visibility with the exact bundle identifier and current process launch epoch, allowing a transiently missing or recreated AX node to complete confirmation.
- After a successful application-level hide, a status item temporarily absent from the AX inventory no longer becomes a failed batch during the final scan; a real exit, process replacement, or identity change still remains pending.
- Added regression coverage for AX node replacement, native batch confirmation, and startup recovery so BLEUnlock, WhatCable, and other login-launched tray applications do not regain false error cards after restart.

Verification: full gate, dual-architecture public release, signed feeds, and public artifact installation are recorded after completion. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.18] - 2026-11-14

Fixed multiple native tray applications disappearing or falling back to “offline and retained records” after restart or login when their startup order differs.

- Every new Menu Tidy process and every desktop resume after locking now performs one protected native tray rebind and settle scan instead of relying only on macOS or Menu Tidy version changes.
- Every saved hidden or collapsible application stays discoverable during its bounded post-launch window. Once its new process identity is observed, only that application is hidden again; an application that has not started or has no status item remains an offline record with its saved choice.
- Added regression coverage for multiple startup orders, recovery with unchanged version markers, and temporarily releasing a saved hidden application during launch discovery.

Verification: full gate, dual-architecture public release, signed feeds, and public artifact installation are recorded after completion. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.17] - 2026-11-14

Fixed macOS 27 native tray applications such as BLEUnlock falling back to “offline and retained records” when the application was running but MenuBarAgent had not yet provided actionable geometry.

- A successful startup recovery scan now records the release as recovered even when part of the running application inventory is absent from that AX round, preventing an endless startup retry loop.
- Running saved applications receive a safe identity fallback row. It preserves the application-level visibility choice and disables movement until macOS confirms an actionable menu bar identity; a later refresh replaces it with the normal item automatically.
- Added startup recovery and list regression coverage for a partial AX inventory.

Verification: focused startup recovery integration tests passed; the full gate and public release installation evidence are recorded with the release. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.16] - 2026-11-14

Fixed the third macOS 27 native tray recovery attempt releasing its display assessment without running the corresponding scan, which could return BLEUnlock and similar icons to offline records when the recovery window ended.

- A pending recovery scan now runs before the retry exhaustion check, so the third post-release MenuBarAgent AX scan is executed after its settle delay.
- Added a boundary regression test for the third startup recovery scan.

Verification: `./scripts/check.sh --full` passed before release. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.15] - 2026-11-14

Fixed upgrades from `0.7.14` or earlier skipping one native tray recovery when the macOS environment version had not changed, which left saved hidden applications such as BLEUnlock in offline records.

- Include the application version and build in the startup recovery marker so each upgrade runs one native assessment release, settle wait, and rediscovery pass.
- Keep the current macOS environment marker to avoid repeating recovery within the same release; record the new release marker only after recovery succeeds.
- Added regression coverage for a release change with an unchanged environment that still preserves saved bundle identifiers as discovery hints.

Verification: `./scripts/check.sh --full` passed before release. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.14] - 2026-11-14

Fixed startup recovery scanning the MenuBarAgent accessibility tree before it settled after releasing the native tray display assessment on macOS 27, which could make saved hidden applications such as BLEUnlock appear undiscovered and become hidden again.

- Wait for the MenuBarAgent AX tree to settle before scanning after releasing the native assessment.
- Keep recovery protection and bounded retry state active while the delayed scan is pending, so an incomplete tray inventory cannot trigger re-hiding.
- Added startup recovery coverage for the delayed post-release scan to prevent BLEUnlock and similar applications from falling back to offline-only records after a system upgrade or restart.

Verification: `./scripts/check.sh --full` passed before release. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.13] - 2026-11-14

Fixed startup recovery reapplying saved hidden choices before the macOS 27 native tray scan completed, which made BLEUnlock and similar items disappear from MenuBarAgent again.

- Pause re-hiding saved applications from native assessment release through the recovery scan.
- Reapply the saved tray classifications after a successful scan; failed recovery remains discoverable during bounded retries.
- Added a native assessment intent regression test so persisted choices cannot mask recovery discovery.

Verification: `./scripts/check.sh --full` passed before release. Uses the project's self-signed release identity and is not Apple-notarized.

## [0.7.12] - 2026-11-14

Fixed the startup recovery path ending before discovery when native tray rebinding fails, which could leave applications such as BLEUnlock undiscovered.

- Run one protected menu bar scan after a failed rebind. The scan still requires a live process and a current menu bar identity.
- Keep bounded retries for the failed rebind; a successful scan never reports the failed native write as recovered.
- Added an integration regression test covering discovery after a failed startup rebind.

Verification: `./scripts/check.sh --full` passed before release. Uses the project's self-signed release identity and is not Apple-notarized.

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
