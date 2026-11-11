#!/bin/bash
# NEW authorization required. Eight explicit test executions, no retries, no IPA.
set -Eeuo pipefail
source scripts/native-blockers-command.sh
OUT="$PWD/build/native-blockers"
mkdir -p "$PWD/build"
# Reserve the entire output directory, including early preflight failures.
# Never overwrite evidence from a previous attempt on this host/commit.
if ! mkdir "$OUT"; then
  echo "Refusing to overwrite existing native-blockers output: $OUT" >&2
  exit 1
fi
STAGE=authorization
cleanup() {
  local status="$1"
  echo "$status" > "$OUT/runner-exit-status.log"
  if [ -n "${MONITOR:-}" ]; then kill "$MONITOR" 2>/dev/null || true; fi
  if [ -n "${SIMULATOR_ID:-}" ]; then xcrun simctl shutdown "$SIMULATOR_ID" 2>/dev/null || true; fi
}
trap 'cleanup "$?"' EXIT
# Record the stage/line, not arbitrary command contents or environment secrets.
trap 'printf "Failure: stage=%s line=%s status=%s\n" "$STAGE" "$LINENO" "$?" | tee -a "$OUT/preflight.log" >&2' ERR
echo "stage=$STAGE" > "$OUT/preflight.log"
if [ -z "${ILAMPA_APPROVED_SOURCE_COMMIT:-}" ]; then
  echo "Set the separately approved full source SHA in ILAMPA_APPROVED_SOURCE_COMMIT" | tee -a "$OUT/preflight.log" >&2
  exit 1
fi
test "${ILAMPA_NATIVE_BLOCKERS_AUTHORIZED:-NO}" = YES
[[ "$ILAMPA_APPROVED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
git rev-parse HEAD > "$OUT/source-commit.log"
test "$(cat "$OUT/source-commit.log")" = "$ILAMPA_APPROVED_SOURCE_COMMIT"
require_clean_source() {
  local phase="$1"
  git status --porcelain --untracked-files=no > "$OUT/$phase-status.log"
  git diff --no-ext-diff --no-textconv HEAD > "$OUT/$phase-diff.log"
  if [ -s "$OUT/$phase-status.log" ]; then
    echo "Tracked source changed at $phase; refusing to run tests" | tee -a "$OUT/preflight.log" >&2
    cat "$OUT/$phase-status.log" >&2
    return 1
  fi
}
STAGE=before-generation
echo "stage=$STAGE" >> "$OUT/preflight.log"
require_clean_source "$STAGE"
STAGE=pipeline-status-selfcheck
echo "stage=$STAGE" >> "$OUT/preflight.log"
# Exercise status capture on the runner's own Bash, not just a developer shell.
# This is a deliberately failing shell command, NOT a native test/retry.
native_blockers_capture "$OUT/pipeline-selfcheck.log" bash -c 'echo "Expected shell status probe: 65"; exit 65'
printf 'command=%s tee=%s\n' "$XCODEBUILD_STATUS" "$TEE_STATUS" > "$OUT/pipeline-selfcheck-status.log"
test "$XCODEBUILD_STATUS" -eq 65
test "$TEE_STATUS" -eq 0
STAGE=install-xcodegen
echo "stage=$STAGE" >> "$OUT/preflight.log"
brew install xcodegen 2>&1 | tee "$OUT/xcodegen-install.log"
STAGE=xcodegen-version
echo "stage=$STAGE" >> "$OUT/preflight.log"
xcodegen --version > "$OUT/xcodegen-version.log" 2>&1
# Fail closed if Homebrew supplies a different generator; do not silently drift.
test "$(cat "$OUT/xcodegen-version.log")" = "Version: 2.46.0"
STAGE=generate-project
echo "stage=$STAGE" >> "$OUT/preflight.log"
xcodegen generate 2>&1 | tee "$OUT/xcodegen-generate.log"
STAGE=after-generation
echo "stage=$STAGE" >> "$OUT/preflight.log"
require_clean_source "$STAGE"
STAGE=environment
echo "stage=$STAGE" >> "$OUT/preflight.log"
{
  git rev-parse HEAD
  xcodebuild -version
  xcrun swift --version
  sw_vers
  xcrun simctl list runtimes
  xcrun simctl list devices available
} > "$OUT/environment.log"
grep -q '^Xcode 26.6$' "$OUT/environment.log"
system_profiler SPAudioDataType > "$OUT/host-audio-before.log"
if command -v SwitchAudioSource >/dev/null; then
  SwitchAudioSource -a -f json > "$OUT/host-audio-devices.log"
  for type in input output system; do
    SwitchAudioSource -c -t "$type" >> "$OUT/host-audio-defaults.log"
  done
fi
# Host defaults are inventory, NOT proof of Simulator Audio I/O mapping. Never
# install drivers, switch routes, mute the player, or substitute a runtime here.
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; xs=[r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["version"]=="26.5" and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; assert len(xs)==1, xs; print(xs[0])')
SIMULATOR_ID=$(xcrun simctl create "iLampa native blockers" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")
echo "$SIMULATOR_ID" > "$OUT/simulator-id.log"

# Build/validate all eight commands before executing ANY test body. Enumeration
# asks this exact Xcode CLI to list the filtered tests, not run them. It validates
# the actual generated scheme, destination, flags and one-test selection.
STAGE=command-preflight
echo "stage=$STAGE" >> "$OUT/preflight.log"
python3 scripts/validate-native-blockers-command.py list --phases "${ILAMPA_NATIVE_BLOCKERS_PHASES:-}" > "$OUT/command-plan.log"
while IFS=$'\t' read -r name scheme selection; do
  STAGE="command-preflight-$name"
  mkdir "$OUT/$name"
  native_blockers_command "$name" "$scheme" "$selection"
  python3 scripts/validate-native-blockers-command.py command \
    --out "$OUT" --simulator "$SIMULATOR_ID" --phase "$name" --record -- "${XCODEBUILD_COMMAND[@]}"
  native_blockers_capture "$OUT/$name.enumeration-build.log" "${XCODEBUILD_COMMAND[@]}" \
    -enumerate-tests -test-enumeration-style flat -test-enumeration-format text \
    -test-enumeration-output-path "$OUT/$name.enumeration.log"
  printf 'xcodebuild=%s tee=%s\n' "$XCODEBUILD_STATUS" "$TEE_STATUS" > "$OUT/$name.enumeration-status.log"
  # Enumeration may create a result bundle even though no tests ran. Preserve it
  # separately; the real test command must still get a fresh Result.xcresult.
  if [ -d "$OUT/$name/Result.xcresult" ]; then
    mv "$OUT/$name/Result.xcresult" "$OUT/$name/Enumeration.xcresult"
    ditto -c -k --keepParent "$OUT/$name/Enumeration.xcresult" "$OUT/$name.enumeration.xcresult.zip"
  fi
  test "$XCODEBUILD_STATUS" -eq 0
  test "$TEE_STATUS" -eq 0
  python3 scripts/validate-native-blockers-command.py enumeration "$name" "$OUT/$name.enumeration.log" > "$OUT/$name.enumeration-validation.json"
done < "$OUT/command-plan.log"

# Native discovery launches the host and may leave this simulator booted.
# Restore the recorded simulator to shutdown before the first real execution.
native_blockers_shutdown

run_test() {
  local name="$1" scheme="$2" selection="$3"
  STAGE="$name"
  local phase="$OUT/$name"
  native_blockers_command "$name" "$scheme" "$selection"
  python3 scripts/validate-native-blockers-command.py command \
    --out "$OUT" --simulator "$SIMULATOR_ID" --phase "$name" -- "${XCODEBUILD_COMMAND[@]}"
  xcrun simctl boot "$SIMULATOR_ID"
  xcrun simctl bootstatus "$SIMULATOR_ID" -b > "$phase/boot.log" 2>&1
  xcrun simctl io "$SIMULATOR_ID" help > "$phase/simctl-io-help.log" 2>&1 || true
  # These read-only inventories expose guest preferences when present; no
  # undocumented routing key is written or treated as a verified actual route.
  xcrun simctl spawn "$SIMULATOR_ID" defaults read com.apple.audio > "$phase/guest-audio-preferences.log" 2>&1 || true
  (
    last=-1
    while sleep 20; do
      [ -f "$OUT/$name.log" ] || continue
      size=$(wc -c < "$OUT/$name.log" | tr -d ' ')
      if [ "$size" = "$last" ]; then
        # Do not consume the only app sample while xcodebuild is still compiling.
        apps="$(pgrep -x iLampa || true) $(pgrep -f '/AVPlayerControlHost.app/AVPlayerControlHost|/AVKitControlHost.app/AVKitControlHost' || true)"
        if [ -z "${apps// /}" ]; then continue; fi
        ps -ax -o pid,ppid,state,command > "$phase/processes.log"
        for pid in $apps $(pgrep -f SimAudioProcessorService || true) $(pgrep -x coreaudiod || true); do
          sample "$pid" 5 -file "$phase/sample-$pid.log" > "$phase/sample-status-$pid.log" 2>&1 || true
        done
        break
      fi
      last=$size
    done
  ) &
  MONITOR=$!
  native_blockers_capture "$OUT/$name.log" "${XCODEBUILD_COMMAND[@]}"
  local status="$XCODEBUILD_STATUS"
  echo "$XCODEBUILD_STATUS" > "$phase/xcodebuild-status.log"
  echo "$TEE_STATUS" > "$phase/tee-status.log"
  if [ "$TEE_STATUS" -ne 0 ]; then status=1; fi
  kill "$MONITOR" 2>/dev/null || true
  MONITOR=""
  log show --style compact --last 8m --predicate 'process == "iLampa" OR process == "AVPlayerControlHost" OR process == "coreaudiod" OR process == "SimAudioProcessorService"' > "$phase/host-system.log" 2>&1 || true
  xcrun simctl spawn "$SIMULATOR_ID" log show --style compact --last 8m --predicate 'process == "iLampa" OR process == "AVPlayerControlHost" OR process == "mediaserverd" OR process == "audiomxd"' > "$phase/guest-system.log" 2>&1 || true
  if [ -d "$phase/Result.xcresult" ]; then
    xcrun xcresulttool get test-results summary --path "$phase/Result.xcresult" > "$phase/summary.json" 2> "$phase/summary-error.log" || true
    xcrun xcresulttool get test-results tests --path "$phase/Result.xcresult" > "$phase/tests.json" 2> "$phase/tests-error.log" || true
    xcrun xcresulttool export attachments --path "$phase/Result.xcresult" --output-path "$phase/attachments" > "$phase/attachment-export.log" 2>&1 || true
    xcrun xcresulttool export diagnostics --path "$phase/Result.xcresult" --output-path "$phase/diagnostics" > "$phase/diagnostic-export.log" 2>&1 || true
    ditto -c -k --keepParent "$phase/Result.xcresult" "$OUT/$name.xcresult.zip"
  fi
  # A process crash, empty selection, skipped test, or failed assertion is NOT a
  # passing phase, even if a restarted host later emits a success line.
  if ! python3 scripts/validate-native-blockers-command.py summary "$phase/summary.json" 1
  then status=1; fi
  echo "$status" > "$phase/result-status-before-packaging.log"
  ditto -c -k --keepParent "$phase" "$OUT/$name.evidence.zip"
  if ! python3 scripts/validate-native-blockers-command.py artifacts "$OUT" "$name" > "$OUT/$name.artifact-validation.log" 2>&1; then
    cat "$OUT/$name.artifact-validation.log" >&2
    status=1
  fi
  echo "$status" > "$OUT/$name.phase-status.log"
  native_blockers_shutdown
  if [ "$status" -ne 0 ]; then FAILED=1; fi
}

FAILED=0
# Each invocation starts a new host and reboots the SAME recorded simulator.
# Independent Settings evidence is still collected if media fails; no phase is
# retried and any failure remains fatal to this request's overall result.
while IFS=$'\t' read -r name scheme selection; do
  run_test "$name" "$scheme" "$selection"
done < "$OUT/command-plan.log"
system_profiler SPAudioDataType > "$OUT/host-audio-after.log"
echo "Overall focused result: $FAILED (0=passed, 1=failed)" | tee "$OUT/result.log"
exit "$FAILED"
