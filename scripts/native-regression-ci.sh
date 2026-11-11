#!/bin/bash
# Full manual gate: every native test in both generated schemes, no exclusions.
set -Eeuo pipefail
source scripts/native-blockers-command.sh
OUT="$PWD/build/native-regression"
mkdir -p "$PWD/build"
mkdir "$OUT"
trap 'printf "line=%s status=%s\n" "$LINENO" "$?" >> "$OUT/failure.log"' ERR
test "${ILAMPA_NATIVE_REGRESSION_AUTHORIZED:-NO}" = YES
test "$(git rev-parse HEAD)" = "${ILAMPA_APPROVED_SOURCE_COMMIT:?}"
test -z "$(git status --porcelain --untracked-files=no)"
brew install xcodegen > "$OUT/xcodegen-install.log" 2>&1
test "$(xcodegen --version)" = 'Version: 2.46.0'
xcodegen generate > "$OUT/xcodegen-generate.log" 2>&1
git diff HEAD > "$OUT/generated-diff.log"
test -z "$(git status --porcelain --untracked-files=no)"
{ git rev-parse HEAD; xcodebuild -version; xcrun simctl list runtimes; system_profiler SPAudioDataType; } > "$OUT/environment.log"
grep -q '^Xcode 26.6$' "$OUT/environment.log"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; xs=[r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["version"]=="26.5" and "SimRuntime.iOS-" in r["identifier"]]; assert len(xs)==1; print(xs[0])')
SIMULATOR_ID=$(xcrun simctl create 'iLampa complete native regression' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")
echo "$SIMULATOR_ID" > "$OUT/simulator-id.log"
cleanup() {
  local status="$?"
  echo "$status" > "$OUT/runner-exit-status.log"
  if [ -n "${MONITOR:-}" ]; then kill "$MONITOR" 2>/dev/null || true; fi
  xcrun simctl shutdown "$SIMULATOR_ID" 2>/dev/null || true
  for name in AVPlayerControl AVKitControl iLampa; do
    if [ -d "$OUT/$name" ] && [ ! -f "$OUT/$name.evidence.zip" ]; then
      ditto -c -k --keepParent "$OUT/$name" "$OUT/$name.evidence.zip" || true
    fi
  done
}
trap cleanup EXIT
FAILED=0
for scheme in AVPlayerControl AVKitControl iLampa; do
  phase="$OUT/$scheme"
  mkdir "$phase"
  command=(xcodebuild test -project iLampa.xcodeproj -scheme "$scheme" -configuration Debug
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath "$OUT/DerivedData"
    -resultBundlePath "$phase/Result.xcresult" -parallel-testing-enabled NO
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES AD_HOC_CODE_SIGNING_ALLOWED=YES)
  printf '%q ' "${command[@]}" > "$OUT/$scheme.command.log"
  native_blockers_capture "$OUT/$scheme.enumeration-build.log" "${command[@]}" \
    -enumerate-tests -test-enumeration-style flat -test-enumeration-format text \
    -test-enumeration-output-path "$OUT/$scheme.enumeration.log"
  printf 'command=%s tee=%s\n' "$XCODEBUILD_STATUS" "$TEE_STATUS" > "$OUT/$scheme.enumeration-status.log"
  test "$XCODEBUILD_STATUS" -eq 0
  test "$TEE_STATUS" -eq 0
  if [ -d "$phase/Result.xcresult" ]; then mv "$phase/Result.xcresult" "$phase/Enumeration.xcresult"; fi
  expected=$(python3 scripts/validate-native-blockers-command.py full-enumeration "$scheme" "$OUT/$scheme.enumeration.log")
  echo "$expected" > "$OUT/$scheme.expected-count.log"
  # Enumeration starts the host; reboot before the actual full-suite invocation.
  native_blockers_shutdown
  xcrun simctl boot "$SIMULATOR_ID"
  xcrun simctl bootstatus "$SIMULATOR_ID" -b > "$phase/boot.log" 2>&1
  (
    last=-1
    while sleep 20; do
      [ -f "$OUT/$scheme.log" ] || continue
      size=$(wc -c < "$OUT/$scheme.log" | tr -d ' ')
      if [ "$size" = "$last" ]; then
        apps="$(pgrep -x iLampa || true) $(pgrep -f '/AVPlayerControlHost.app/AVPlayerControlHost|/AVKitControlHost.app/AVKitControlHost' || true)"
        if [ -z "${apps// /}" ]; then continue; fi
        ps -ax -o pid,ppid,state,command > "$phase/processes.log"
        for pid in $apps $(pgrep -f SimAudioProcessorService || true) $(pgrep -x coreaudiod || true); do
          sample "$pid" 5 -file "$phase/sample-$pid.log" 2>/dev/null || true
        done
        break
      fi
      last=$size
    done
  ) &
  MONITOR=$!
  native_blockers_capture "$OUT/$scheme.log" "${command[@]}"
  echo "$XCODEBUILD_STATUS" > "$phase/xcodebuild-status.log"
  echo "$TEE_STATUS" > "$phase/tee-status.log"
  if [ "$XCODEBUILD_STATUS" -ne 0 ] || [ "$TEE_STATUS" -ne 0 ]; then FAILED=1; fi
  kill "$MONITOR" 2>/dev/null || true
  MONITOR=''
  log show --style compact --last 60m --predicate 'process == "iLampa" OR process == "AVPlayerControlHost" OR process == "coreaudiod" OR process == "SimAudioProcessorService"' > "$phase/host-system.log" 2>&1 || true
  xcrun simctl spawn "$SIMULATOR_ID" log show --style compact --last 60m --predicate 'process == "iLampa" OR process == "AVPlayerControlHost" OR process == "mediaserverd" OR process == "audiomxd"' > "$phase/guest-system.log" 2>&1 || true
  if [ -d "$phase/Result.xcresult" ]; then
    xcrun xcresulttool get test-results summary --path "$phase/Result.xcresult" > "$phase/summary.json" 2> "$phase/summary-error.log" || true
    xcrun xcresulttool get test-results tests --path "$phase/Result.xcresult" > "$phase/tests.json" 2> "$phase/tests-error.log" || true
    xcrun xcresulttool export attachments --path "$phase/Result.xcresult" --output-path "$phase/attachments" > "$phase/attachment-export.log" 2>&1 || true
    xcrun xcresulttool export diagnostics --path "$phase/Result.xcresult" --output-path "$phase/diagnostics" > "$phase/diagnostic-export.log" 2>&1 || true
    ditto -c -k --keepParent "$phase/Result.xcresult" "$OUT/$scheme.xcresult.zip"
  fi
  if ! python3 scripts/validate-native-blockers-command.py summary "$phase/summary.json" "$expected"; then FAILED=1; fi
  ditto -c -k --keepParent "$phase" "$OUT/$scheme.evidence.zip"
  native_blockers_shutdown
done
echo "Complete native gate: $FAILED" | tee "$OUT/result.log"
exit "$FAILED"
