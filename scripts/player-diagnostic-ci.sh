#!/bin/bash
# Explicitly invoked diagnostic run only; no distribution or signing.
set -uo pipefail
mkdir -p build/player-diagnostics
OUT="$PWD/build/player-diagnostics"
SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; xs=[x for k in sorted(d,reverse=True) if "iOS" in k for x in d[k] if x["name"].startswith("iPhone")]; print(xs[0]["udid"] if xs else "")')
if [ -z "$SIMULATOR_ID" ]; then echo 'No available iPhone simulator' >&2; exit 1; fi
xcodebuild -version > "$OUT/environment.txt" 2>&1
xcrun simctl list devices available >> "$OUT/environment.txt" 2>&1
echo "Selected simulator: $SIMULATOR_ID" >> "$OUT/environment.txt"

# A quiet log is only a candidate stall, not proof of an app hang. Capture a
# sample while xcodebuild is still running, if the simulator app PID is visible.
(
  last=-1
  while sleep 45; do
    size=$(wc -c < "$OUT/targeted.log" | tr -d ' ')
    if [ "$size" = "$last" ]; then
      date > "$OUT/candidate-stall.txt"
      echo 'No xcodebuild log growth for one monitor interval; not proof of a hang.' >> "$OUT/candidate-stall.txt"
      ps -ax -o pid,ppid,state,command > "$OUT/processes.txt"
      xcrun simctl spawn "$SIMULATOR_ID" launchctl list > "$OUT/simulator-processes.txt" 2>&1 || true
      pids=$(pgrep -f '/iLampa.app/iLampa' || true)
      for pid in $pids; do
        sample "$pid" 5 -file "$OUT/sample-$pid.txt" >> "$OUT/candidate-stall.txt" 2>&1 || true
      done
      break
    fi
    last=$size
  done
) &
MONITOR=$!
trap 'kill "$MONITOR" 2>/dev/null || true' EXIT
xcodebuild -project iLampa.xcodeproj -scheme iLampa -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/PlayerDiagnosticDerivedData \
  -resultBundlePath "$OUT/player.xcresult" \
  -only-testing:iLampaRuntimeTests/PlayerStateIntegrationTests \
  -only-testing:iLampaRuntimeTests/RealWebKitBootstrapTests \
  -only-testing:iLampaUITests/iLampaUITests/testPlayerSeekingPauseResumeAndReopen \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 240 \
  -maximum-test-execution-time-allowance 240 CODE_SIGNING_ALLOWED=NO \
  test 2>&1 | tee "$OUT/targeted.log"
STATUS=${PIPESTATUS[0]}
kill "$MONITOR" 2>/dev/null || true
trap - EXIT

if [ -d "$OUT/player.xcresult" ]; then
  xcrun xcresulttool get test-results summary --path "$OUT/player.xcresult" > "$OUT/summary.json" 2> "$OUT/summary-error.txt" || true
  xcrun xcresulttool get test-results tests --path "$OUT/player.xcresult" > "$OUT/tests.json" 2> "$OUT/tests-error.txt" || true
  xcrun xcresulttool export attachments --path "$OUT/player.xcresult" --output-path "$OUT/attachments" > "$OUT/attachments-export.txt" 2>&1 || true
  ditto -c -k --keepParent "$OUT/player.xcresult" "$OUT/player.xcresult.zip" || true
fi
if ! ditto -c -k --keepParent "$OUT" build/player-diagnostics.zip; then
  echo 'Could not package diagnostic artifacts' >&2
  exit 1
fi
exit "$STATUS"
