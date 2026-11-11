#!/bin/bash
# One manually triggered checkpoint. Never signs, installs on a device or uploads.
set -uo pipefail
OUT="$PWD/build/controlled-verification"
mkdir -p "$OUT"
git rev-parse HEAD | tee "$OUT/commit.txt"
xcodebuild -version | tee "$OUT/xcode.txt"

{
  node tests/unit/test_suite_master.js
  a=$?
  node tests/unit/test_bridge_runtime.js
  b=$?
  node --check iLampa/Resources/lampa_bridge.js
  c=$?
  node --check iLampa/Resources/www/app.min.js
  d=$?
  [ "$a" -eq 0 ] && [ "$b" -eq 0 ] && [ "$c" -eq 0 ] && [ "$d" -eq 0 ]
} 2>&1 | tee "$OUT/javascript.log"
JS_STATUS=${PIPESTATUS[0]}

# Packaging retains a verified IPA even if later simulator tests fail.
bash scripts/device-diagnostic-package.sh 2>&1 | tee "$OUT/release-compiler-and-package.log"
PACKAGE_STATUS=${PIPESTATUS[0]}

SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; xs=[x for k in sorted(d,reverse=True) if "iOS" in k for x in d[k] if x["name"].startswith("iPhone")]; print(xs[0]["udid"] if xs else "")')
TEST_STATUS=1
if [ -n "$SIMULATOR_ID" ] && [ -d iLampa.xcodeproj ]; then
  printf 'Simulator: %s\n' "$SIMULATOR_ID" | tee "$OUT/simulator.txt"
  xcodebuild -project iLampa.xcodeproj -scheme iLampa -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    -derivedDataPath build/ControlledSimulatorDerivedData \
    -resultBundlePath "$OUT/targeted.xcresult" \
    -only-testing:iLampaRuntimeTests/DiagnosticsLogTests \
    -only-testing:iLampaRuntimeTests/MediaDetailResolutionIntentTests \
    -only-testing:iLampaRuntimeTests/PlaybackSelectionGateTests \
    -only-testing:iLampaRuntimeTests/RealWebKitBootstrapTests \
    -only-testing:iLampaRuntimeTests/PlayerStateIntegrationTests \
    -only-testing:iLampaRuntimeTests/PlaybackIntegrationEvidenceTests \
    -only-testing:iLampaRuntimeTests/ProviderRecoveryTests \
    -only-testing:iLampaUITests/LampaRuntimePresentationTests \
    -only-testing:iLampaUITests/iLampaUITests/testPlayerSeekingPauseResumeAndReopen \
    -only-testing:iLampaUITests/iLampaUITests/testSourceResolutionHonestState \
    -only-testing:iLampaUITests/iLampaUITests/testSourcesManagementAndDiagnosticsConsole \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 240 -maximum-test-execution-time-allowance 240 \
    CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$OUT/targeted.log"
  TEST_STATUS=${PIPESTATUS[0]}
else
  printf 'No available iPhone simulator or generated project; native tests not run.\n' | tee "$OUT/targeted.log"
fi

ARCHIVE_STATUS=0
if [ -d "$OUT/targeted.xcresult" ]; then
  xcrun xcresulttool get test-results summary --path "$OUT/targeted.xcresult" > "$OUT/summary.txt" 2>&1 || true
  ditto -c -k --keepParent "$OUT/targeted.xcresult" "$OUT/targeted.xcresult.zip" || ARCHIVE_STATUS=$?
else
  printf 'No xcresult bundle was produced.\n' | tee "$OUT/xcresult-missing.txt"
  ARCHIVE_STATUS=1
fi
printf 'JavaScript: %s\nRelease/package: %s\nNative tests: %s\nResult archive: %s\n' \
  "$JS_STATUS" "$PACKAGE_STATUS" "$TEST_STATUS" "$ARCHIVE_STATUS" | tee "$OUT/status.txt"
[ "$JS_STATUS" -eq 0 ] && [ "$PACKAGE_STATUS" -eq 0 ] && [ "$TEST_STATUS" -eq 0 ] && [ "$ARCHIVE_STATUS" -eq 0 ]
