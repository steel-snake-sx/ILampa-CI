#!/bin/bash
# Shared command construction/capture. Sourcing this file executes no tests.
native_blockers_command() {
  local name="$1" scheme="$2" selection="$3"
  XCODEBUILD_COMMAND=(
    xcodebuild test -project iLampa.xcodeproj -scheme "$scheme" -configuration Debug
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID"
    -derivedDataPath "$OUT/DerivedData" -resultBundlePath "$OUT/$name/Result.xcresult"
    -parallel-testing-enabled NO
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180
    "-only-testing:$selection"
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
    AD_HOC_CODE_SIGNING_ALLOWED=YES
  )
}

native_blockers_capture() {
  local logfile="$1"
  shift
  local -a statuses
  # A conditional pipeline suppresses errexit/ERR handling until BOTH statuses
  # have been captured. Do not log, declare locals or run traps in between.
  if "$@" 2>&1 | tee "$logfile"; then
    statuses=("${PIPESTATUS[@]}")
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  XCODEBUILD_STATUS=${statuses[0]}
  TEE_STATUS=${statuses[1]}
  # Callers explicitly inspect both statuses, after preserving diagnostics.
  return 0
}

native_blockers_shutdown() {
  local state
  state=$(xcrun simctl list devices -j | python3 -c 'import json,sys; xs=[d for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["udid"]==sys.argv[1]]; assert len(xs)==1; print(xs[0]["state"])' "$SIMULATOR_ID")
  case "$state" in
    Booted) xcrun simctl shutdown "$SIMULATOR_ID" ;;
    Shutdown) ;;
    *) echo "Unexpected simulator state: $state" >&2; return 1 ;;
  esac
}
