#!/bin/bash
# Manual, test-only verification. No device archive, IPA, signing service or upload.
set -euo pipefail
bash scripts/prepare-simulator-audio.sh
SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; xs=[x for k in sorted(d,reverse=True) if "iOS" in k for x in d[k] if x["name"].startswith("iPhone")]; print(xs[0]["udid"] if xs else "")')
if [ -z "$SIMULATOR_ID" ]; then echo "No available iPhone simulator" >&2; exit 1; fi
mkdir -p build/concurrency-tests
xcodebuild -version > build/concurrency-tests/environment.log
xcrun swift --version >> build/concurrency-tests/environment.log
git rev-parse HEAD >> build/concurrency-tests/environment.log
xcrun simctl list devices available >> build/concurrency-tests/environment.log
xcrun simctl list runtimes >> build/concurrency-tests/environment.log
node tests/unit/test_bridge_runtime.js | tee build/concurrency-tests/bridge-contract.log
node tests/unit/test_legacy_settings_contract.js | tee build/concurrency-tests/storage-contract.log
node tests/runtime/legacy_settings_queue_race.test.js | tee build/concurrency-tests/queue-contract.log
node tests/runtime/legacy_settings_bridge.test.js | tee build/concurrency-tests/settings-contract.log
node tests/runtime/metadata_bridge.test.js | tee build/concurrency-tests/metadata-contract.log
# Record a real app process sample if the AVKit UI test stops responding.
# This is diagnostic collection, not a timeout-based test success/failure decision.
OUT="$PWD/build/concurrency-tests"
(
  last=-1
  while sleep 20; do
    [ -f "$OUT/xcodebuild.log" ] || continue
    grep -q '\[AVKitUIProbe\]' "$OUT/xcodebuild.log" || continue
    size=$(wc -c < "$OUT/xcodebuild.log" | tr -d ' ')
    if [ "$size" = "$last" ]; then
      ps -ax -o pid,ppid,state,command > "$OUT/processes.log"
      for pid in $(pgrep -f '/iLampa.app/iLampa' || true); do
        sample "$pid" 5 -file "$OUT/sample-$pid.log" > "$OUT/sample-status-$pid.log" 2>&1 || true
      done
      break
    fi
    last=$size
  done
) &
MONITOR=$!
trap 'kill "$MONITOR" 2>/dev/null || true' EXIT
set +e
xcodebuild test -project iLampa.xcodeproj -scheme iLampa -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/concurrency-tests/DerivedData \
  -resultBundlePath build/concurrency-tests/Concurrency.xcresult \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
  -only-testing:iLampaRuntimeTests \
  -only-testing:iLampaUITests/iLampaUITests/testLegacySettingsAppearInProductionPluginDetail \
  -only-testing:iLampaUITests/iLampaUITests/testPlayerSeekingPauseResumeAndReopen \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  AD_HOC_CODE_SIGNING_ALLOWED=YES 2>&1 | tee build/concurrency-tests/xcodebuild.log
status=${PIPESTATUS[0]}
kill "$MONITOR" 2>/dev/null || true
trap - EXIT
log show --style compact --last 15m --predicate 'process == "iLampa" OR process == "coreaudiod" OR process == "SimAudioProcessorService"' > "$OUT/app-system.log" 2>&1 || true
set -e
if [ -d build/concurrency-tests/Concurrency.xcresult ]; then
  xcrun xcresulttool get test-results summary --path "$OUT/Concurrency.xcresult" > "$OUT/summary.log" 2>&1 || true
  xcrun xcresulttool get test-results tests --path "$OUT/Concurrency.xcresult" > "$OUT/tests.log" 2>&1 || true
  xcrun xcresulttool export attachments --path "$OUT/Concurrency.xcresult" --output-path "$OUT/attachments" > "$OUT/attachment-export.log" 2>&1 || true
  if [ -d "$OUT/attachments" ]; then
    ditto -c -k --keepParent "$OUT/attachments" "$OUT/attachments.zip"
  fi
  ditto -c -k --keepParent build/concurrency-tests/Concurrency.xcresult build/concurrency-tests/Concurrency.xcresult.zip
fi
exit "$status"
