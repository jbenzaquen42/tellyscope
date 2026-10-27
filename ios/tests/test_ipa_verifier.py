import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).parents[1] / "scripts" / "verify-unsigned-ipa.py"
SPEC = importlib.util.spec_from_file_location("ipa_verifier", SCRIPT)
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class IpaVerifierTest(unittest.TestCase):
    def test_valid_unsigned_arm64_ipa_gets_checksum_and_provenance(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / "dist" / "TVADB-unsigned.ipa"
            ipa.parent.mkdir()
            info = {
                "CFBundleExecutable": "TVADB",
                "CFBundleIdentifier": verifier.EXPECTED_BUNDLE_ID,
                "MinimumOSVersion": "17.0",
            }
            macho = bytes.fromhex("cffaedfe0c000001") + bytes(64)
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/", b"")
                archive.writestr("Payload/TVADB.app/Info.plist", plistlib.dumps(info))
                archive.writestr("Payload/TVADB.app/TVADB", macho)
                archive.writestr("Payload/TVADB.app/Assets.car", b"assets")
                archive.writestr("Payload/TVADB.app/en.lproj/Localizable.strings", b"strings")

            with patch("sys.argv", [str(SCRIPT), str(ipa)]), patch.object(verifier.platform, "machine", return_value="arm64"), patch.object(verifier.subprocess, "check_output", side_effect=["source-sha", "Xcode 26.6\nBuild version 17F113", "26.5"]):
                verifier.main()

            self.assertTrue(ipa.with_suffix(".ipa.sha256").is_file())
            provenance = ipa.with_suffix(".ipa.provenance.json").read_text(encoding="utf-8")
            self.assertIn(verifier.UPSTREAM_COMMIT, provenance)
            self.assertIn('"signed": false', provenance)


if __name__ == "__main__":
    unittest.main()
