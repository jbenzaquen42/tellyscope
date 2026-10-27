# Tellyscope for iOS (experimental)

This iOS app is based on TVADB and provides an unsigned build for evaluating ADB connections to Android TV devices. The project targets iOS 17+. It is experimental: physical-device and TV compatibility testing has not been completed. The Fire TV Cube 3 is expected to use classic ADB TCP on port 5555; use the TCL TV's actual debugging mode, which may require Android's Wireless Debugging pairing flow.

## Build

On an Apple Silicon Mac with Xcode 26.6, run from the repository root:

```bash
swift test --package-path ios/TellyscopeCore
bash ios/scripts/build-unsigned-ipa.sh
```

The workflow runs these steps on `macos-26` for pull requests touching `ios/` and on manual dispatch. It uploads the unsigned IPA, SHA-256 checksum, and JSON provenance receipt. CI has no signing secrets and does not produce an installable signed app.

To install on a physical iPhone, sign the IPA with a certificate and provisioning profile matching `app.tellyscope.ios` using your sideloading tool. Keep private keys and signing credentials out of this repository.

## License and source

Tellyscope is GPL-3.0-only. This app derives from [TVADB](https://github.com/wy164519317/tvadb) at the commit and native binary provenance documented in [UPSTREAM.md](UPSTREAM.md). Preserve the imported upstream MIT notice and all embedded dependency licenses when redistributing; the native ADB archives are inherited binaries and CI does not rebuild them.
