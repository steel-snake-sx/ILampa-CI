"""Read-only IPA validation; no archive extraction or signing claims."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import struct
import zipfile


def validate(ipa: Path, checksum: Path, root: Path, build: str) -> dict:
    with ipa.open("rb") as file:
        digest = hashlib.file_digest(file, "sha256").hexdigest()
    expected = checksum.read_text(encoding="utf-8-sig").split()[0].lower()
    assert digest == expected, "Downloaded IPA does not match the CI checksum"
    prefix = "Payload/iLampa.app/"
    with zipfile.ZipFile(ipa) as archive:
        assert archive.testzip() is None, "Archive CRC check failed"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        assert info["CFBundleIdentifier"] in ["com.steelsnake.ilampa", "online.lampa.ilampa"]
        assert str(info["CFBundleVersion"]) == build
        assert info["MinimumOSVersion"] == "18.0"
        executable = archive.read(prefix + info["CFBundleExecutable"])
        magic, cpu = struct.unpack("<II", executable[:8])
        assert magic == 0xFEEDFACF and cpu == 0x0100000C, "Not a thin arm64 Mach-O executable"
        resources = {}
        for bundled, source in [
            ("lampa_bridge.js", "iLampa/Resources/lampa_bridge.js"),
            ("www/app.min.js", "iLampa/Resources/www/app.min.js"),
            ("www/index.html", "iLampa/Resources/www/index.html"),
        ]:
            actual = archive.read(prefix + bundled).replace(b"\r\n", b"\n")
            current = (root / source).read_bytes().replace(b"\r\n", b"\n")
            assert actual == current, f"Bundled {bundled} does not match this working tree"
            resources[bundled] = hashlib.sha256(actual).hexdigest()
        assert prefix + "embedded.mobileprovision" not in archive.namelist(), "Unexpected provisioned artifact"
        return {"ipa": str(ipa.resolve()), "bytes": ipa.stat().st_size, "sha256": digest,
                "version": info["CFBundleShortVersionString"], "build": str(info["CFBundleVersion"]),
                "bundle_id": info["CFBundleIdentifier"], "minimum_ios": info["MinimumOSVersion"],
                "architecture": "arm64", "crc": "passed", "resources_match_worktree": resources,
                "provisioning_profile": "absent"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("checksum", type=Path)
    parser.add_argument("--build", default="15")
    args = parser.parse_args()
    print(json.dumps(validate(args.ipa, args.checksum, Path(__file__).resolve().parents[1], args.build), indent=2))
