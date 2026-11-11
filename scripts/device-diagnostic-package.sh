#!/bin/bash
# Manual device-diagnostic workflow only. Does not sign, upload or install.
set -euo pipefail
OUT="$PWD/build/device-diagnostic"
mkdir -p "$OUT"
COMMIT=$(git rev-parse HEAD)
# Derive the package identity from the current project, not the old 2.0.1 release.
VERSION=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ {print $2; exit}' project.yml)
BASE_BUILD=$(awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
MINIMUM_BUILD=${ILAMPA_RELEASE_MINIMUM_BUILD:-2009}
RUN_NUMBER=${BUILD_NUMBER:-1}
test -n "$VERSION"
[[ "$BASE_BUILD" =~ ^[0-9]+$ && "$RUN_NUMBER" =~ ^[0-9]+$ && "$MINIMUM_BUILD" =~ ^[0-9]+$ ]]
BUILD=${ILAMPA_RELEASE_BUILD_NUMBER:-$((BASE_BUILD + RUN_NUMBER))}
if [ "$BUILD" -le "$MINIMUM_BUILD" ] && [ -z "${ILAMPA_RELEASE_BUILD_NUMBER:-}" ]; then
  BUILD=$((MINIMUM_BUILD + RUN_NUMBER))
fi
[[ "$BUILD" =~ ^[0-9]+$ ]]
test "$BUILD" -gt "$MINIMUM_BUILD"
printf 'Packaging iLampa %s (%s) from commit %s\n' "$VERSION" "$BUILD" "$COMMIT"
if [ -n "${ILAMPA_VERIFIED_COMMIT:-}" ]; then
  test "$COMMIT" = "$ILAMPA_VERIFIED_COMMIT"
fi
export COMMIT BUILD VERSION BASE_BUILD
python3 - <<'PY'
import os, pathlib
p = pathlib.Path('project.yml')
s = p.read_text()
replacements = {
    f'CURRENT_PROJECT_VERSION: "{os.environ["BASE_BUILD"]}"': f'CURRENT_PROJECT_VERSION: "{os.environ["BUILD"]}"',
    f'CFBundleVersion: "{os.environ["BASE_BUILD"]}"': f'CFBundleVersion: "{os.environ["BUILD"]}"',
    'ILAMPA_GIT_COMMIT: ""': f'ILAMPA_GIT_COMMIT: "{os.environ["COMMIT"]}"',
}
for old, new in replacements.items():
    if s.count(old) != 1:
        raise SystemExit(f'Expected one occurrence of {old!r}, found {s.count(old)}')
    s = s.replace(old, new)
p.write_text(s)
PY
xcodegen generate
xcodebuild archive -project iLampa.xcodeproj -scheme iLampa -configuration Release \
  -archivePath "$OUT/iLampa.xcarchive" \
  -destination 'generic/platform=iOS' -derivedDataPath build/DeviceDiagnosticDerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  AD_HOC_CODE_SIGNING_ALLOWED=YES
APP="$OUT/iLampa.xcarchive/Products/Applications/iLampa.app"
test -d "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist")" = iLampa
test "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist")" = 18.0
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$APP/Info.plist")" = AppIcon
test -f "$APP/Assets.car"
test ! -e "$APP/embedded.mobileprovision"
test "$(lipo -archs "$APP/iLampa")" = arm64
if codesign -dv "$APP" > "$OUT/codesign.txt" 2>&1; then
  echo 'Expected an unsigned app; codesign reports a signature' >&2
  exit 1
fi
cmp iLampa/Resources/lampa_bridge.js "$APP/lampa_bridge.js"
cmp iLampa/Resources/www/index.html "$APP/www/index.html"
file "$APP/iLampa" | tee "$OUT/architecture.txt"
mkdir -p "$OUT/staging/Payload"
ditto "$APP" "$OUT/staging/Payload/iLampa.app"
(cd "$OUT/staging" && zip -q -r -y "$OUT/iLampa-unsigned.ipa" Payload)
python3 scripts/verify-release-ipa.py "$OUT/iLampa-unsigned.ipa" --commit "$COMMIT" --version "$VERSION" --minimum-build "$MINIMUM_BUILD" | tee "$OUT/verification.txt"
mkdir -p "$OUT/extracted"
ditto -x -k "$OUT/iLampa-unsigned.ipa" "$OUT/extracted"
PACKAGED="$OUT/extracted/Payload/iLampa.app"
test "$(lipo -archs "$PACKAGED/iLampa")" = arm64
cmp "$APP/iLampa" "$PACKAGED/iLampa"
test ! -e "$PACKAGED/embedded.mobileprovision"
test "$(/usr/libexec/PlistBuddy -c 'Print :ILAMPA_GIT_COMMIT' "$PACKAGED/Info.plist")" = "$COMMIT"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PACKAGED/Info.plist")" = "$BUILD"
printf 'Source commit: %s\nCFBundleVersion: %s\n' "$COMMIT" "$BUILD" | tee "$OUT/identity.txt"
shasum -a 256 "$OUT/iLampa-unsigned.ipa" | tee "$OUT/sha256.txt"
ditto -c -k --keepParent "$OUT/iLampa.xcarchive" "$OUT/iLampa.xcarchive.zip"
