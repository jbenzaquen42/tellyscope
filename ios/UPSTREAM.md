# iOS source and binary provenance

`ios/` starts from [wy164519317/tvadb](https://github.com/wy164519317/tvadb), pinned at `1fa69380f63f6906874e3cbfa7644bd94f7de02c`. The app code and patches were imported from that revision and adapted in this GPL-3.0-only Tellyscope repository. Retain the upstream MIT notice for its original portions and the root GPL license for the Tellyscope derivative; embedded ADB components keep their own licenses in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The checked-in `Vendor/adb-prebuilt` archives are inherited upstream binaries from `wsvn53/adb-mobile` commit `8a1d2136d74535e651b591d09ab87dc9f7ef2ec4`. Their SHA-256 values are recorded and enforced by `scripts/prepare-adb-prebuilt.sh` before extraction. CI packages these binaries; it does not rebuild them from source.
