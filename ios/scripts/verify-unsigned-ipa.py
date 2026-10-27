#!/usr/bin/env python3
"""Validate the unsigned arm64 IPA and write adjacent checksum/provenance receipts."""

import hashlib
import json
import os
import platform
import plistlib
import struct
import subprocess
import sys
import zipfile
from pathlib import Path


UPSTREAM_COMMIT = "1fa69380f63f6906874e3cbfa7644bd94f7de02c"
ADB_MOBILE_COMMIT = "8a1d2136d74535e651b591d09ab87dc9f7ef2ec4"
EXPECTED_BUNDLE_ID = "app.tellyscope.ios"


def require(condition, message):
    if not condition:
        raise SystemExit(f"IPA verification failed: {message}")


def is_arm64_macho(data):
    if len(data) < 8:
        return False
    magic = data[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        endian = "<" if magic == b"\xcf\xfa\xed\xfe" else ">"
        return struct.unpack(endian + "I", data[4:8])[0] == 0x0100000C
    if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
        endian = "<" if magic in (b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca") else ">"
        count = struct.unpack(endian + "I", data[4:8])[0]
        width = 32 if magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca") else 20
        return any(struct.unpack(endian + "I", data[8 + width * index:12 + width * index])[0] == 0x0100000C for index in range(count))
    return False


def main():
    require(len(sys.argv) == 2, "usage: verify-unsigned-ipa.py <ipa>")
    ipa = Path(sys.argv[1]).resolve()
    require(ipa.is_file(), f"missing IPA: {ipa}")
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    with zipfile.ZipFile(ipa) as archive:
        names = set(archive.namelist())
        prefix = "Payload/TVADB.app/"
        plist_path = prefix + "Info.plist"
        require(plist_path in names, "Payload/TVADB.app/Info.plist is missing")
        info = plistlib.loads(archive.read(plist_path))
        executable_name = info.get("CFBundleExecutable")
        executable_path = prefix + str(executable_name or "")
        require(executable_name and executable_path in names, "app executable is missing")
        require(is_arm64_macho(archive.read(executable_path)), "app executable does not contain arm64")
        require(info.get("CFBundleIdentifier") == EXPECTED_BUNDLE_ID, "unexpected bundle identifier")
        require(prefix + "Assets.car" in names or any(name.startswith(prefix + "Assets.car/") for name in names), "compiled app assets are missing")
        require(any(name.startswith(prefix + "en.lproj/") for name in names), "English localization resources are missing")
        require(not any(name.startswith(prefix + "_CodeSignature/") for name in names), "IPA is signed; expected unsigned output")
        require(prefix + "embedded.mobileprovision" not in names, "provisioning profile found in unsigned IPA")
        require(all(name == "Payload/" or name.startswith(prefix) for name in names), "unexpected files outside the app payload")

    repo = ipa.parent.parent
    source_sha = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).strip().splitlines()
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True).strip()
    ios_root = Path(__file__).parents[1]
    archives = {
        "iphoneos_arm64": "libadb-full-iphoneos-arm64.zip",
        "iphonesimulator_arm64": "libadb-full-iphonesimulator-arm64.zip",
    }
    receipt = {
        "ipa": ipa.name,
        "sha256": digest,
        "bundle_id": info["CFBundleIdentifier"],
        "minimum_ios": info.get("MinimumOSVersion"),
        "executable": executable_name,
        "architecture": "arm64",
        "signed": False,
        "repository_commit": source_sha,
        "upstream": "https://github.com/wy164519317/tvadb",
        "upstream_commit": UPSTREAM_COMMIT,
        "adb_mobile_commit": ADB_MOBILE_COMMIT,
        "native_archive_sha256": {
            key: hashlib.sha256((ios_root / "Vendor/adb-prebuilt" / filename).read_bytes()).hexdigest()
            for key, filename in archives.items()
        },
        "runner_architecture": platform.machine(),
        "xcode": xcode,
        "iphoneos_sdk": sdk,
    }
    require(receipt["runner_architecture"] == "arm64", "expected Apple Silicon runner")
    checksum_path = ipa.with_suffix(ipa.suffix + ".sha256")
    checksum_path.write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
    provenance_path = ipa.with_suffix(ipa.suffix + ".provenance.json")
    provenance_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Verified unsigned arm64 IPA: {ipa}")
    print(f"SHA-256: {digest}")
    print(f"Provenance: {provenance_path}")


if __name__ == "__main__":
    main()
