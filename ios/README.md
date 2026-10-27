# Tellyscope for iOS (experimental)

This iOS app is based on TVADB and provides an unsigned build for evaluating ADB connections to Android TV devices. The project targets iOS 17+. It is experimental: physical-device and TV compatibility testing has not been completed. The Fire TV Cube 3 is expected to use classic ADB TCP on port 5555; use the TCL TV's actual debugging mode, which may require Android's Wireless Debugging pairing flow.

## Build

On an Apple Silicon Mac with Xcode 26.6, run from the repository root:

```bash
swift test --package-path ios/TellyscopeCore
bash ios/scripts/build-unsigned-ipa.sh
```

The workflow runs on `macos-26` for pull requests touching `ios/`, pushes to `codex/ios-port`, and manual dispatch. It tests the safety core and IPA verifier, builds for simulator and device, and captures a launch screenshot on iPhone 13 mini. It uploads the unsigned IPA, SHA-256 checksum, screenshot, and JSON provenance receipt. CI has no signing secrets and does not produce an installable signed app.

To install on a physical iPhone, sign the IPA with a certificate and provisioning profile matching `app.tellyscope.ios` using your sideloading tool. Keep private keys and signing credentials out of this repository.

## First device check

Enable ADB debugging on the Fire TV Cube, then add its IP with port 5555 and accept the authorization prompt on the TV. On the TCL Google TV, use its actual network-debugging endpoint or Wireless Debugging pairing and connection ports. Start with app listing and the remote on each TV.

For manual disable and undo, open **Tools > Safe debloat & undo**. The app records a baseline and pending change before disabling, checks the TV serial and current Home, and verifies the result. History is separate for each TV; restore excludes apps disabled before this app's changes. TVs without a trustworthy readable serial cannot use this feature. Curated suggestions, launcher switching, and additional Tellyscope tweaks are not ported yet. The inherited advanced shell and other TVADB tools do not use the guided debloat guard.

## License and source

Tellyscope is GPL-3.0-only. This app derives from [TVADB](https://github.com/wy164519317/tvadb) at the commit and native binary provenance documented in [UPSTREAM.md](UPSTREAM.md). Preserve the imported upstream MIT notice and all embedded dependency licenses when redistributing; the native ADB archives are inherited binaries and CI does not rebuild them.
