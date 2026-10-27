# iPhone research and port plan

Research date: October 27, 2026. Scope: an iPhone app that manages Android/Google TV over Wi-Fi and can be built on GitHub Actions and sideloaded. This is a source review and implementation plan; no iOS build or physical-device test was performed.

## Recommendation

Try an existing app before committing to a full Tellyscope port:

1. For immediate use, **atvTools** already offers the main TV-management functions on iOS.
2. For open-source ownership and a sideloadable IPA, **TVADB** is the closest obtainable application. Evaluate its existing release, then fork it if Tellyscope's protected debloat lists and persistent undo are needed.
3. If TVADB's embedded native library cannot be built or maintained acceptably, evaluate **iADB's ADBCore** as the transport for a smaller new SwiftUI app. Do not write another ADB protocol or cryptographic implementation first.

This changes the approach from rewriting the Android app to reusing an iOS application and porting the missing product behavior. Connection technology already exists; integration, safety behavior, and hardware qualification remain real work.

## Existing alternatives and reusable projects

| Project | What I verified | Fit and limitation |
| --- | --- | --- |
| [atvTools](https://atvtools.app/) / [App Store](https://apps.apple.com/us/app/atvtools/id1661419573) | Official site and US listing describe APK/bundle installation, files, remote, shell, CPU/RAM/network/storage, and app disable/enable. US listing showed $0.99 during research. | Best immediate-use alternative. I did not locate a reusable source repository or evidence of Tellyscope-style protected lists and baseline-aware restore. TV compatibility needs testing. |
| [TVADB](https://github.com/wy164519317/tvadb) | Cloned source, MIT application license, SwiftUI views, embedded AOSP ADB bridge, six-digit pairing, file services, app management, and build scripts. iOS 17+. | Best application base. Main missing Tellyscope behavior is guided safe debloating and its history/undo model. Broad upstream feature claims are not our hardware verification. |
| [iADB / ADBCore](https://github.com/h33h/iadb-ios) | Current clone is a standalone MIT Swift package with discovery, RSA/TLS, SPAKE2 pairing, shell v2, streaming file transfer, and protocol/crypto/stream tests. | Promising native Swift transport fallback. Current checkout has no app UI or IPA target. Search results describe an older app layout; use the actual current source. |
| [SwiftADB](https://github.com/akshaynexus/SwiftADB) | Current package contains ADB transport and SPAKE2 pairing source and tests. Package actually requires iOS 16 and Swift 6, differing from the README's older requirements. Files carry dual-license SPDX notices. | Secondary reference. Its TLS key-export function returns zero-filled material when export fails; this needs correction and interoperability testing before adoption. No standalone LICENSE file appeared in the checkout. |
| [adb-mobile](https://github.com/wsvn53/adb-mobile) | Native AOSP-derived library, C API, iOS build scripts, submodules; README identifies ADB 35.0.2. | Practical native transport already used by TVADB. Building the complete dependency tree is more involved than adding a Swift package. |
| [scrcpy-mobile](https://github.com/wsvn53/scrcpy-mobile) | MIT wrapper source, pairing-code flow, key management, native dependencies and Xcode project. [App Store listing](https://apps.apple.com/us/app/scrcpy-remote/id1629352527) exists. | Useful mirroring/control reference. Less direct than TVADB for a maintenance/debloat app. Store description focuses on VNC, so repository ADB behavior should not be assumed identical to the shipping store app. |

An indexed result for `maxduke/adbtv` looked unusually close to the requirement, but both live repository access and Git clone failed with repository-not-found. Exclude it from the implementation dependency chain.

### Obtainable IPA now

[TVADB v1.3 release](https://github.com/wy164519317/tvadb/releases/tag/v1.3) publishes `TVADB-1.3-unsigned.ipa`, 16,691,915 bytes. GitHub's asset metadata reports SHA-256:

```text
b370daea10268d5004a8f7f1177672e0870842e1a1a0d04ac2135b3d721404f4
```

The release notes describe installation verification fixes and an iPhoneOS arm64 build. Those are the author's receipts, not tests performed here. The asset was not downloaded or inspected. It needs signing with the user's sideloading setup before installation.

### Source snapshots inspected

| Repository | Commit |
| --- | --- |
| Local Tellyscope | `d20b0a24f3d1358adee5b9e78bdf7490a7ee5ee2` |
| TVADB | `1fa69380f63f6906874e3cbfa7644bd94f7de02c` |
| iADB / ADBCore | `22902f6231c413f2d90accee68f0e59f1c9ea360` |
| SwiftADB | `1044bec57ee3aef4b7c556fce2e76b24257769e5` |
| adb-mobile | `8a1d2136d74535e651b591d09ab87dc9f7ef2ec4` |
| scrcpy-mobile | `cdbc6ac7d9d2eca1d1cada5281a8f46d800d5b09` |

## Target hardware: Fire TV Cube 3 and TCL Google TV

The user identified these two targets during research. Treat them as separate acceptance devices and keep their saved identities, baselines and histories separate.

| Device | Connection plan | Device-specific checks |
| --- | --- | --- |
| Fire TV Cube, 3rd generation | Start with classic TCP/RSA at its IP on port 5555 after enabling ADB debugging. Amazon identifies model `AFTGAZL` as Fire OS 7 / Android 9, so Android 11 six-digit pairing is not the expected starting path. | Read actual firmware, ABI and package capabilities before selecting APKs or debloat suggestions. Do not apply Android 9-incompatible tweaks or assume Play Store launcher installation. Launcher replacement is a separate firmware-dependent check, not an initial acceptance promise. |
| TCL Google TV | Inspect the actual model, Android release and debugging options. Use Bonjour plus six-digit pairing if offered; keep manual IP/port entry for a network-debugging endpoint if provided. | TCL brand alone is insufficient to choose a debloat list. Verify model/firmware matching; otherwise show conservative unticked suggestions. Qualify discovery, pairing-port changes, reboot/reconnect and Home rollback on this TV independently. |

Sources: [Amazon device identification](https://developer.amazon.com/docs/device-specs/identify-fire-tv-devices.html), [Amazon network ADB setup](https://developer.amazon.com/docs/fire-tv/connecting-adb-to-device.html), and [Android wireless-debugging documentation](https://developer.android.com/tools/adb#wireless-android11-command-line). The TCL's exact model/firmware remains unknown, so no model-specific compatibility is claimed.

Prioritize the Cube's simpler classic connection first, then qualify the TCL's actual debugging mode. Both devices must pass read-only connection and identity checks before any debloat changes. On the Cube specifically, keep Amazon Home and essential account/network/update components protected and do not add root, exploits, or update-blocking as part of this port.

The current [Tellyscope device-list index](https://github.com/man15h/tellyscope-devices/blob/main/index.json) contains 72 TCL entries, but no entry matching Cube, Gazelle or `AFTGAZL` in its metadata. That means the Cube needs conservative manual review or a newly validated model-specific list; borrowing a Fire TV Stick list is not sufficient. List-feed contents can change, so repeat this check during implementation.

## What must be ported from Tellyscope

Tellyscope's `:adb` module is Kotlin/JVM, not Kotlin Multiplatform. `Connector.kt` uses Kadb, Java sockets/security, and Okio; the Android UI and data layer also use Android-specific services. A new iOS packaging target alone cannot compile this code.

| Feature | Reuse on iOS | Tellyscope work still required |
| --- | --- | --- |
| Classic ADB and wireless pairing | TVADB `iosadb/Core/ADBMobileClient.swift`, `ADBMobileShim.h`, native patches | Preserve identity, authorization waiting/denial, stale pairing-port handling, cancellation and reconnect semantics from `Connector.kt`, `ConnectionPrompt.kt`, `DeviceLink.kt`. |
| Discovery and saved TVs | TVADB `DeviceDiscovery.swift`, `DeviceRecord.swift`, `AppModel.swift` | Match persistent TV identity, distinguish pairing/connect endpoints, handle permission denial and manual connection. |
| Remote, files, APKs and screenshots | Existing TVADB UI and services | Verify behavior; retain existing validation/error handling. Do not rewrite working features for visual parity. |
| Protected app changes | Port `adb/.../Protected.kt`, `Actions.kt` | Shared guard for current Home, essential services and user-only uninstall; enforce at execution, not just in the UI. |
| Suggested debloating | Port `data/DeviceLists.kt` semantics and reuse its JSON feed | Schema/package/path validation, checksum verification, offline cache, conservative model matching and unticked ambiguous suggestions. |
| Baseline and undo | Port `data/HistoryBook.kt` semantics | Durable per-TV baseline, completed/failed/unknown outcomes, verified undo and restore only changes made by this app. |
| Launcher changes and tweaks | Port `Actions.kt`, `HomeServices.kt`, `Tweaks.kt`, launcher data | Verify the new Home before leaving the old launcher disabled; retain rollback and explicit accessibility-service consent. |
| Statistics and access management | Port relevant `Commands.kt`, `Parsers.kt`, `NetworkStats.kt`, `Peripherals.kt`, `Access.kt` behavior | Native models, parsing fixtures, capability handling and safe confirmations. |
| On-TV helpers | Reuse Android helper source where needed | Helpers execute on the TV, not iOS. Existing TVADB label/icon support may avoid adding Tellyscope's helper; only reuse its key helper if required for remote parity. |

For a TVADB fork, add the debloat/history functionality beside its existing UI and command services. Reuse its connection and file infrastructure. Keep new domain logic independent of views so the safety tests do not require a TV.

If instead preserving Tellyscope as the product/repository is essential, add an isolated `ios/` SwiftUI target and reuse the chosen transport/selected services there. That costs more UI integration than a TVADB fork. Leave the Android Gradle targets intact. A Kotlin Multiplatform migration would introduce another large task without eliminating the platform-specific connection and file work; do not start there.

## GitHub build and IPA delivery

TVADB already provides [build-unsigned-ipa.sh](https://github.com/wy164519317/tvadb/blob/1fa69380f63f6906874e3cbfa7644bd94f7de02c/scripts/build-unsigned-ipa.sh): it builds the `TVADB` scheme for `iphoneos` with signing disabled and packages the app under `Payload/`.

Add a manual GitHub Actions workflow in the selected fork:

1. Check out the pinned app source. Record runner architecture, Xcode, SDK, dependency revisions, and source SHA.
2. Use an Apple Silicon runner: upstream ships arm64 simulator libraries, so an Intel simulator runner is a poor fit. GitHub currently lists `macos-26` as an arm64 hosted runner. Explicitly select an installed Xcode version and fail if it is unavailable. [GitHub runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)
3. Verify the vendored ADB archive checksums, then run simulator build/tests and the unsigned IPA script. Check bundle identifier, device architecture, required resources and ZIP integrity.
4. Upload the IPA, checksum, source/dependency manifest and test/build logs as one identifiable artifact set.
5. Sign locally with the user's sideloading tool. If signing in CI is preferred, add matching certificate/profile secrets and a temporary keychain using [GitHub's Xcode signing workflow](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications). An unsigned IPA is a build artifact; it cannot be installed directly as-is.

TVADB's [native patch manifest](https://github.com/wy164519317/tvadb/blob/1fa69380f63f6906874e3cbfa7644bd94f7de02c/patches/README.md) records its library source pin and compatibility patches. Both checked-in archive hashes matched that manifest in this research. Matching hashes verifies file identity, not that binaries were rebuilt from source. Before treating a maintained fork as reproducible, rebuild the library from the recorded sources/patches and validate it separately. The existing preparation script extracts archives but does not check their hashes itself.

ADBCore's fallback workflow uses `xcode-27`; its package specifies Swift tools 6.4. Confirm the selected runner supplies that toolchain before adopting it. Do not silently lower the package's requirements.

Use `NSLocalNetworkUsageDescription` and declare the specific Bonjour ADB services. Prefer Apple Bonjour APIs over custom raw multicast. Verify permission denial and first-run permission prompts on an actual iPhone; the simulator does not implement local-network privacy. [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## Implementation sequence and completion checks

### 1. Qualify the existing app

Build the pinned unmodified TVADB source on GitHub and sideload it. Test the user's actual TV and record its model/firmware and connection mode. Use read-only probes first. Prove classic TCP or six-digit pairing as appropriate, persistent authorization after app restart, remote keys, foreground reconnect, file round-trip hashes, and an APK install with package-manager verification.

Exit: a reproducible IPA and a working iPhone-to-TV session. A green GitHub job alone does not pass this stage. If it fails, isolate a connection/build issue before replacing the app or transport.

### 2. Add safe manual disable/enable with durable history

Port package validation, essential-package/current-Home protection and baseline/history behavior. Save the baseline before sending a mutation. Record pending intent before dispatch; after a disconnect reconcile package state instead of assuming success or blindly retrying. Verify the resulting enabled/disabled state before marking an operation complete.

Port focused fixtures from `ProtectedTest.kt`, `HistoryBookTest.kt` and `DebloatStateTest.kt`. Cover pre-disabled packages, app restart, partial batch failure, unknown Home, wrong TV identity, and undo after reconnect. A baseline write failure must stop the change. UI confirmations must name affected apps; restore must exclude packages already disabled before this app's changes.

Exit: disable and undo one nonessential test package across app restart, plus passing guard/history tests. Batch operations remain unavailable until these rules hold.

### 3. Add curated debloat lists

Implement validated list loading/model selection/cache and the review screen. Use fixtures from `DeviceListsTest.kt`; cover checksum failure, offline cache, invalid package/path/schema, ambiguous model and protected packages appearing in a remote list. No remote list may relax built-in protection.

Exit: preview a matching list, apply a reviewed subset, verify results and restore only this app's changes on the same TV.

### 4. Close the remaining feature gaps

Add launcher switch/rollback, DNS and animation tweaks with previous values, additional telemetry and access management as separate small changes. Port relevant existing tests, including Home-switch and pairing-port cases. Reuse existing TVADB APK/file functionality and verify large transfers, cancellation, split installs and iCloud imports. Build Tellyscope's on-TV DEX helper in an Ubuntu Android job only if actually required, then package it as an iOS resource with a source/hash receipt.

Check narrow iPhone layout, Dynamic Type, VoiceOver labels, 44-point touch targets, long package names, safe areas and horizontal overflow. Interrupt a transfer/change by backgrounding or dropping Wi-Fi and verify honest recovery; do not assume unlimited background runtime.

Exit: each claimed feature has a test or physical-device receipt. Keep model-specific capabilities explicit rather than claiming all Android/Fire TV firmware is supported.

## Boundaries and open decisions

- Targets are the Fire TV Cube 3 and a TCL Google TV. The TCL's exact model/firmware, iPhone iOS version and Hermes sideloading/signing method remain needed for exact qualification and delivery choices. Research does not establish those prior Hermes settings.
- Keep original licenses and notices with reused code. Tellyscope is GPL-3.0-only; TVADB and ADBCore application/package code is MIT, and native dependencies retain separate upstream licenses. Preserve Tellyscope's license on copied/adapted code and provide its corresponding source when distributing the derivative. Do not relabel that code MIT.
- Start with manual CI dispatch and artifact delivery. App Store submission, auto-updates, screen-mirroring improvements, a cross-platform rewrite and unrelated visual redesign are outside this port's initial scope.
- No application code, GitHub repository, release, signing asset or TV setting was changed by this research. No third-party binary was executed, no iOS tests were run, and the source review is not a full security audit.
