# Embedded ADB build patches

TVADB links a prebuilt `libadb-full.a` for iPhoneOS arm64 and Apple Silicon
Simulator arm64. The archives are stored in `Vendor/adb-prebuilt` so a normal
GitHub clone can build without downloading files larger than GitHub's 100 MB
per-file limit.

The static libraries were built from `wsvn53/adb-mobile` commit
`8a1d2136d74535e651b591d09ab87dc9f7ef2ec4` and its pinned submodules. The
patches in this directory record the local iOS compatibility changes used by
the shipped binaries:

- `adb-mobile-porting.patch`: adb-mobile build scripts and output fixes.
- `aosp-adb-ios.patch`: embedded AOSP ADB client portability changes.
- `aosp-libbase-ios.patch`: Android libbase portability change.
- `protobuf-ios.patch`: iOS protobuf build configuration.
- `abseil-ios.patch`: Apple Clang compatibility configuration.

Prebuilt archive SHA-256:

```text
addee382f85a4a40b3af4f10c2b5f4ce65082a7114f896bd72ba25e70f1ef247  libadb-full-iphoneos-arm64.zip
0e809d784c5354c700d7151ee538281812b9de912b8550efd1ca1f0f07901f90  libadb-full-iphonesimulator-arm64.zip
```

The TVADB application source is MIT licensed. Embedded AOSP, BoringSSL,
protobuf, Abseil, Brotli, LZ4, Zstandard, and other third-party components
retain their respective upstream licenses.
