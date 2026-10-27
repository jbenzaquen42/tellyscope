# Third-party notices

TVADB application code is distributed under the repository's MIT License.
The embedded ADB static library is built from the
[adb-mobile](https://github.com/wsvn53/adb-mobile) project and includes code
from the Android Open Source Project and its dependencies.

Third-party components retain their original licenses, including:

- Android Open Source Project / ADB — Apache License 2.0.
- BoringSSL — ISC-style and component-specific licenses.
- Protocol Buffers — BSD 3-Clause License.
- Abseil — Apache License 2.0.
- Brotli — MIT License.
- LZ4 — BSD 2-Clause License.
- Zstandard — BSD 3-Clause and GPLv2 dual licensing.

The complete upstream source and license files are available through the
`Vendor/adb-mobile` Git submodule and its recursively pinned submodules.
TVADB-specific compatibility patches and binary checksums are documented in
[`patches/README.md`](patches/README.md).
