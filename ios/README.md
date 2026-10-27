# Tellyscope for iOS (experimental)

This is the SwiftUI port of Tellyscope's screens and TV-management workflows. TVADB supplies the ADB connection, transfer, APK and icon-reading implementation underneath; its generic app shell is no longer the entry point. The project targets iOS 17+. The earlier transport build connected successfully on the user's TV; new mutation paths still require device qualification. The Fire TV Cube 3 uses classic ADB TCP on port 5555; use the TCL TV's actual debugging mode.

The main navigation follows Android Tellyscope: **Overview, Apps, Files, Tweaks**. Overview shows reported storage, CPU, memory, temperature and network values, with Install, Debloat and Send actions. Debloat uses the same checksummed community model lists and conservative matching rules. Apps has Running/Installed/Disabled filters and guarded changes. Files uses Downloads/Movies with collision-safe upload names. The remote has the Tellyscope D-pad, text input and a per-TV four-app dock. Tweaks includes reversible Private DNS/animation changes, cache cleanup, screenshots, and verified launcher switching with rollback and explicit accessibility consent. History provides app restore and settings/Home undo. Advanced exposes available process/network/access/peripheral information; unsupported readings remain unavailable.

## Build

On an Apple Silicon Mac with Xcode 26.6, run from the repository root:

```bash
./gradlew :app:dexLabelHelper
# Copy app/build/generated/labelHelper/assets/label-helper.jar into ios/iosadb/Resources/.
swift test --package-path ios/TellyscopeCore
bash ios/scripts/build-unsigned-ipa.sh
```

The helper is built from the original Android Java source and runs only on the TV. Picture-only screen off is supported only when the TV exposes the required Android 13-or-older display API; it never substitutes TV sleep for picture-only control.

The workflow runs on `macos-26` for pull requests touching `ios/`, pushes to `codex/ios-port`, and manual dispatch. It tests the safety core and IPA verifier, builds for simulator and device, and captures a launch screenshot on iPhone 13 mini. It uploads the unsigned IPA, SHA-256 checksum, screenshot, and JSON provenance receipt. CI has no signing secrets and does not produce an installable signed app.

To install on a physical iPhone, sign the IPA with a certificate and provisioning profile matching `app.tellyscope.ios` using your sideloading tool. Keep private keys and signing credentials out of this repository.

## First device check

Version 0.2.1 bundles a narrowly matched [TCL G05 US AR71 profile](../docs/devices/tcl-g05-us-ar71.md), based on a read-only inspection. It supplies 29 optional suggestions and 18 protected packages even offline. Nothing is preselected; disabling and reboot behavior on the inspected TV remain untested.

Enable ADB debugging on the Fire TV Cube, then add its IP with port 5555 and accept the authorization prompt on the TV. On the TCL Google TV, use its actual network-debugging endpoint or Wireless Debugging pairing and connection ports. Start with app listing and the remote on each TV.

Open **Overview > Debloat** to review the TV's model list, choose a different list, or pick apps manually. The app records a baseline and pending change before disabling, checks the TV serial and current Home, and verifies the result. History is separate for each TV; Restore excludes apps disabled before this app's changes. Apps already disabled can be explicitly enabled from Apps. TVs without a trustworthy readable serial cannot use mutations. Launcher replacement depends on firmware permissions, especially on Fire TV; failed verification triggers rollback. Advanced access management currently provides the manual TV-side revoke path, not automated key revocation or debugging-prompt approval.

## License and source

Tellyscope is GPL-3.0-only. This app derives from [TVADB](https://github.com/wy164519317/tvadb) at the commit and native binary provenance documented in [UPSTREAM.md](UPSTREAM.md). Preserve the imported upstream MIT notice and all embedded dependency licenses when redistributing; the native ADB archives are inherited binaries and CI does not rebuild them.
