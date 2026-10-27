# TVADB for iOS

<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

<p align="center">
  <img src="iosadb/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png" width="128" alt="TVADB App Icon">
</p>

<p align="center">
  A native iPhone ADB manager for Android TV, Google TV, Xiaomi TV, Fire TV, and TV boxes.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%2017%2B-1677F7">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.0-1677F7">
  <img alt="UI" src="https://img.shields.io/badge/UI-SwiftUI-00A8E0">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-00A8E0"></a>
</p>

## Why TVADB

Good ADB tools for iOS are scarce, and truly open-source options that can be maintained over the long term are even rarer. I therefore used AI to build the tool I needed, one piece at a time. If you can sign iOS apps, you can build, sign, and install TVADB yourself. You do not have to wait for a closed-source app to be updated or worry that it may disappear from the store one day. The code is public, so anyone can improve it and keep it alive—**sign it yourself if you can; open source lives forever.**

TVADB embeds the AOSP ADB core directly inside the iOS app. It does not require a Mac, a desktop ADB server, or a relay service. Once connected to a TV, it can install APKs, manage files and apps, run shell commands, inspect logs, control the TV, and capture screenshots directly from an iPhone.

> This repository contains a runnable core version that is ready for continued development. Differences that still need validation across TV brands are tracked separately as community compatibility testing rather than unfinished core work.

## UI Preview

<table>
  <tr>
    <td align="center"><img src="docs/images/device-discovery.png" width="210" alt="Device discovery"><br><sub>Device discovery</sub></td>
    <td align="center"><img src="docs/images/file-manager.png" width="210" alt="File manager"><br><sub>File manager</sub></td>
    <td align="center"><img src="docs/images/applications.png" width="210" alt="App management"><br><sub>App management</sub></td>
    <td align="center"><img src="docs/images/tv-remote.png" width="210" alt="Live screen remote"><br><sub>Live screen remote</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/shell.png" width="210" alt="ADB Shell"><br><sub>ADB Shell</sub></td>
    <td align="center"><img src="docs/images/tools.png" width="210" alt="System tools"><br><sub>System tools</sub></td>
    <td align="center"><img src="docs/images/settings.png" width="210" alt="App settings"><br><sub>App settings</sub></td>
    <td align="center"><sub>All images are native device screenshots exported with Simulator Save Screen</sub></td>
  </tr>
</table>

## Core Features

| Module | Current capabilities |
| --- | --- |
| Device discovery | Listens for `_adb._tcp`, `_adb-tls-pairing._tcp`, and `_adb-tls-connect._tcp` over Bonjour, and scans ADB TCP port 5555 on the current Wi-Fi IPv4 `/24` subnet |
| Device management | Manual setup, multiple saved devices, favorites, groups, notes, editing, recent connections, automatic reconnection, and device information |
| ADB connection | Legacy ADB TCP/RSA plus Android 11+ SPAKE2, TLS 1.3, certificate persistence, and wireless pairing-code flow |
| APK installation and inspection | APK, APKS, XAPK, and APKM; device-aware split selection and XAPK OBB deployment; icon, binary Manifest, version, SDK, ABI, V1/V2/V3/V3.1 signature, permission, and component inspection |
| File management | Local iPhone/iPad and TV browsing, recursive multi-file/folder transfer, resumable chunks, batch download/delete, rename, and folder creation; two-pane iPad layout and drag and drop |
| App management | User/system app lists with real names and icons loaded in batches from the TV's `PackageManager` by a temporary DEX helper and persistently cached; devices that reject the helper retain package names and default icons; plus search, launch, force stop, clear cache, clear data, uninstall, and complete base/split APK export |
| ADB Shell | Arbitrary commands, common commands, local command history, and favorite commands |
| TV remote | Directional controls, OK, Home, Back, Menu, Recent, volume, mute, power, a gesture D-pad, and a low-latency system mouse trackpad that prefers physical-style UHID and automatically falls back to `uinput`; drag, double-click, right/middle click, and wheel actions are supported |
| Live screen | Continuously transports H.264 over a dedicated ADB channel, decodes it in hardware with VideoToolbox, and drops stale frames to minimize latency; includes touch/mouse modes, zoom, rotation, and fullscreen shortcuts, with automatic screenshot fallback on devices that reject the video stream |
| Screenshots | Prefers `exec-out screencap` with ADB Sync `pull` fallback; fit-to-screen display, pinch to zoom, drag, double-tap zoom, and save to Photos |
| System tools | Fixed-duration MP4 screen recording; near-real-time incremental Logcat with search, Tag/PID/level filters, pause, and TXT export; device details including IP, MAC, and battery; settings, developer options, and reboot tools |
| iOS integration | Shares or imports packages from the Files app, registers APK/APKS/XAPK/APKM file types, and provides appearance, installation mode, log level, and default transfer-directory settings; Simplified Chinese and English can follow the system or switch in-app |

## Project Status

### Implemented

- ✅ Native AOSP ADB 35 core builds for iPhoneOS arm64 and Apple Silicon simulator arm64.
- ✅ ADB TCP/RSA connection and authorization, Shell, Sync file transfer, and APK installation.
- ✅ Native SPAKE2/TLS flow required for Android 11+ wireless pairing.
- ✅ Current-subnet discovery and manual IP/port connections.
- ✅ File, app, Shell, remote, screenshot, and basic system-tool interfaces.
- ✅ Near-real-time incremental Logcat with search, Tag/PID/level filters, pause, clear, and TXT export.
- ✅ Device-aware split selection for APKS/APKM/XAPK, multi-APK installation, and automatic XAPK OBB deployment.
- ✅ Recursive multi-file/folder transfer, 64-bit file sizes, chunked upload/download, and transfer resumption.
- ✅ APK icon, binary Manifest, signature, permission, Activity, Service, Receiver, Provider, and SharedUserId inspection.
- ✅ Batched, install-free helper loading and persistent caching for installed-app names/icons; default icons on devices that reject the helper; plus complete base/split APK export.
- ✅ Two-pane local/TV file management on iPad, two-way transfer, and drag-to-upload/install.
- ✅ Native system mouse trackpad (Linux UHID first to emulate a physical HID mouse, with automatic AOSP `uinput` and four-ABI helper fallbacks), using a persistent ADB control stream and pointer coalescing for lower latency, with drag, double-click, right/middle click, and wheel actions. Includes 15/30/60-second TV MP4 recording and export.
- ✅ Dedicated ADB H.264 live-screen channel with iOS VideoToolbox hardware decoding, zero playback buffering, stale-frame dropping, first-frame timeout fallback, and a screenshot compatibility mode.
- ✅ Device editing, groups and notes, Shell command favorites, version-aware installation history, and an opt-in, off-by-default connection to the last device on launch/foreground.
- ✅ Light, dark, and tinted app icons plus appearance, installation mode, default upload/download directory, and log-level settings.
- ✅ Unsigned IPA build script and one-command simulator runner.

### Community Compatibility Testing

The Android 11+ pairing path, common APKS/APKM/XAPK installation paths, ADB mouse, and screen recording are implemented. TV brands, firmware versions, pointer policies, video encoders, and third-party package generators still differ, so remaining problems are tracked as compatibility feedback rather than unfinished core features. Issues and pull requests are welcome; include the TV brand, model, Android version, package source, and sanitized logs. Never publish pairing codes, ADB private keys, or certificate private keys.

## Requirements

- macOS with a full Xcode installation.
- iOS 17 or later; the app has been built and run on the iOS 26 simulator.
- An Apple Silicon Mac to use the included arm64 simulator ADB static library.
- Installing on a physical device requires a signing certificate, private key, and provisioning profile that match your Bundle ID.
- Android TV must have Developer options and either Wireless debugging or ADB TCP enabled.

Current configuration:

| Item | Value |
| --- | --- |
| Bundle ID | `com.tvadb.ios` |
| Minimum OS | iOS 17.0 |
| Swift | 5.0 |

## Quick Start

### Xcode Simulator

Initialize the upstream ADB source after cloning:

```bash
git submodule update --init --recursive
```

Open `iosadb.xcodeproj` and choose a specific simulator from the device menu at the top of Xcode, such as `iPhone 17 Pro`. Do not select `Any iOS Device (arm64)`. Then press `⌘R`. Xcode automatically prepares the arm64 ADB static library from the compressed prebuilt archive included in the repository.

You can also build, install, and launch the app with:

```bash
./scripts/run-simulator.sh
```

To use a different simulator:

```bash
./scripts/run-simulator.sh "iPad mini (A17 Pro)"
```

The simulator does not require a development certificate or developer account, so it is useful for reviewing the UI and local logic. TV authorization, APK installation, wireless pairing, and file transfer should still be verified on a physical iPhone.

### Build an Unsigned IPA

```bash
./scripts/build-unsigned-ipa.sh
```

Output:

```text
dist/TVADB-unsigned.ipa
```

The IPA is unsigned by default. You can re-sign it with an enterprise certificate, but the certificate, private key, provisioning profile, and Bundle ID must match. Enterprise distribution does not require a separate Apple Development certificate, and simulator debugging does not require code signing.

## Connect to Android TV

### Legacy ADB TCP

Enable TCP mode from a computer or through a capability provided by the TV:

```bash
adb tcpip 5555
adb shell ip addr show wlan0
```

After TVADB opens, it scans port 5555 on the iPhone's current IPv4 `/24` subnet and uses an ADB handshake to reject unrelated open ports. You can also tap `+` in the upper-right corner and enter the TV's IP address and port manually.

### Android 11+ Wireless Pairing

1. On the TV, open **Developer options → Wireless debugging → Pair device with pairing code**.
2. On TVADB's device screen, choose the automatically discovered device or tap `+` to start manual wireless pairing.
3. Enter the pairing IP address, pairing port, and six-digit pairing code shown by the TV.
4. Enter the connection port shown on the main Wireless debugging screen and connect.

The pairing port and connection port are usually different, and they may change after Wireless debugging is turned off and on. After successful pairing, TVADB stores its ADB identity and TLS certificate in the app sandbox.

## FAQ

### The TV is not found automatically

- Make sure the iPhone has granted TVADB access to the local network.
- Make sure Wireless debugging or ADB TCP port 5555 is enabled on the TV.
- Check that the iPhone and TV are on the same routable network.
- Guest Wi-Fi, AP isolation, and corporate network policies may block device-to-device traffic.
- The Android 11+ Wireless debugging connection port is usually not 5555. Use pairing discovery or enter it manually.

### File upload or APK installation appears to do nothing

Make sure the app is still connected to the TV and select a real file in the system file picker. Files stored in iCloud must finish downloading first, and installation bundles must contain valid APK files.

### Which operations may be restricted by TV permissions?

Access to `Android/obb`, uninstalling system apps, Recovery, Bootloader, and some `settings` commands depends on the TV firmware and ADB user permissions.

### How does Mouse mode display the TV's system pointer?

TVADB temporarily uploads a lightweight helper matching the TV's CPU architecture and first tries to register a standard USB mouse report descriptor through `/dev/uhid`. This is the closest wireless-ADB equivalent to a physical HID mouse. Android 15 supports independent cursors per display, so TVADB explicitly associates the UHID physical input port with the primary display. This prevents a recognized physical mouse from being routed to `DisplayId -1`, where only a clipped shadow may appear at the top-left corner. If UHID or display association is unavailable, TVADB falls back to the firmware's AOSP `uinput` command and then the helper's direct `/dev/uinput` mode; compatibility clicks remain available if all kernel paths are restricted. Classic ADB TCP connections reuse a persistent control stream for mouse reports; transports that do not accept the stream automatically fall back to ordinary Shell commands without losing functionality. The helper installs no APK, requires no root access, and is stopped and cleaned up when the ADB session ends.

Some desktop Android emulators render their visible mouse arrow in the Windows or macOS host process instead of Android's SurfaceFlinger. ADB alone cannot ask the emulator host to display that arrow, and a virtual mouse may leave only an invisible-pointer hover shadow. TVADB automatically switches recognized emulators to coordinate-touch mode: the phone trackpad maps the whole Android display, so users can tap the matching position directly or drag the phone-side coordinate marker and tap. Clicks use Android touchscreen input, removing the stale hover shadow while keeping single-click reliable. Real TVs still prefer UHID/uinput; whether they render a native pointer depends on the TV kernel, ADB shell permissions, and vendor pointer policy.

### Does screen recording include audio?

Android `screenrecord` captures video without system or microphone audio by default. TVADB offers 15-, 30-, and 60-second recordings and pulls the completed MP4 back to the iPhone.

## Project Structure

```text
iosadb.xcodeproj/              Xcode project, shared scheme, and build settings
iosadb/
├── IOSADBApp.swift            App entry point and language environment
├── Core/
│   ├── ADBMobileClient.swift  Swift interface to the AOSP ADB static library
│   ├── ADBCommandService.swift
│   │                          App, Shell, screenshot, recording, and mouse commands
│   ├── ADBSyncService.swift   Browsing, Push/Pull, chunks, and transfer resumption
│   ├── DeviceDiscovery.swift  Bonjour and current-subnet discovery
│   ├── APKInspector.swift     APK Manifest, signature, permission, and component inspection
│   └── ...                    ADB protocol, keys, archives, and recording recovery
├── Models/                    Devices, files, apps, installation history, and global state
├── UI/                        Home, files, apps, remote, Shell, tools, and settings
├── Resources/
│   ├── Assets.xcassets/       App Icon, Accent Color, and image assets
│   ├── AndroidUInput/         arm64/armv7/x86/x86_64 UHID/uinput mouse helpers
│   └── TVADBIconHelper.dex    Android PackageManager icon helper
├── en.lproj/                  English localization
├── zh-Hans.lproj/             Simplified Chinese localization
└── Info.plist                 Permissions, document types, Bonjour, and scene settings

android-helper/                Source for the install-free DEX icon helper
android-uinput-helper/         Source for the libc-free Android UHID/uinput helper
Vendor/adb-mobile/             AOSP ADB source, libraries, headers, and licenses
Vendor/adb-prebuilt/           GitHub-friendly compressed arm64 ADB static libraries
Vendor/adb-public/             Stable public ADB header required by the app target
patches/                       iOS compatibility patches and checksums for the prebuilt ADB libraries
scripts/                       Helper, simulator, and unsigned-IPA build scripts
docs/images/                   Current README screenshots
dist/                          Locally generated unsigned IPA
README.md / README_EN.md       Chinese and English documentation
LICENSE                        MIT License
```

## Security

- Enable ADB only on local networks you trust.
- Verify the RSA authorization prompt on the TV when connecting for the first time.
- Shell, file deletion, clearing app data, and reboot commands are privileged operations.
- Never commit enterprise certificate private keys, signing passwords, GitHub tokens, or ADB private keys to the repository.

## License

TVADB's original source code is released under the permissive [MIT License](LICENSE). You may use, copy, modify, merge, publish, distribute, sublicense, and sell it, provided that the original copyright and license notice are retained.

AOSP ADB and third-party dependencies under `Vendor/` are not relicensed under this project's MIT License. They remain subject to their respective LICENSE and NOTICE files. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Third-Party Code

This project includes prebuilt static libraries for AOSP ADB and its dependencies. Complete upstream source is available through the `Vendor/adb-mobile` submodule; the compatibility patches and binary checksums used by TVADB are stored in [`patches/`](patches/README.md). Retain all applicable copyright and license notices when redistributing or publishing commercially.
