"""Validate a downloaded unsigned IPA before any delivery; never uploads it."""
import argparse
import hashlib
import plistlib
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("ipa", type=Path)
parser.add_argument("--commit", required=True, help="expected full or abbreviated Git commit")
parser.add_argument("--version", required=True)
parser.add_argument("--minimum-build", type=int, required=True, help="highest previously distributed build")
args = parser.parse_args()

with zipfile.ZipFile(args.ipa) as archive:
    bad = archive.testzip()
    if bad:
        raise SystemExit("IPA has a corrupt ZIP member")
    names = set(archive.namelist())
    plists = [name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2]
    if len(plists) != 1:
        raise SystemExit("IPA must contain exactly one top-level app bundle")
    root = plists[0][:-len("Info.plist")]
    info = plistlib.loads(archive.read(plists[0]))
    required = ["iLampa", "lampa_bridge.js", "www/index.html", "Assets.car", "Settings.bundle/Root.plist"]
    if any(root + item not in names for item in required):
        raise SystemExit("IPA is missing a required app, runtime, asset or recovery resource")
    if info.get("CFBundleIdentifier") != "com.steelsnake.ilampa":
        raise SystemExit("Unexpected bundle identifier")
    if info.get("CFBundleShortVersionString") != args.version:
        raise SystemExit("Unexpected marketing version")
    try:
        build = int(info.get("CFBundleVersion", ""))
    except (ValueError, TypeError):
        raise SystemExit("Invalid build number")
    if build <= args.minimum_build:
        raise SystemExit("Build number does not exceed the known distributed maximum")
    sha = info.get("ILAMPA_GIT_COMMIT", "")
    if not sha or len(sha) < 7 or not args.commit.lower().startswith(sha.lower()):
        raise SystemExit("Embedded commit does not match expected commit")

print(f"Verified bundle com.steelsnake.ilampa, version {args.version}, build {build}, commit {sha}")
print("SHA-256:", hashlib.sha256(args.ipa.read_bytes()).hexdigest())
print("This verifies archive and metadata, not signing, installation, or playback.")
