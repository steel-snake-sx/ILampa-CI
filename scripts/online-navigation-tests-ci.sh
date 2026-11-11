#!/bin/bash
set -euo pipefail

SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; xs=[x for k in sorted(d,reverse=True) if "iOS" in k for x in d[k] if x["name"].startswith("iPhone")]; print(xs[0]["udid"] if xs else "")')
if [ -z "$SIMULATOR_ID" ]; then
  echo "No available iPhone simulator" >&2
  exit 1
fi
mkdir -p build/online-navigation-tests
set +e
xcodebuild test \
  -project iLampa.xcodeproj -scheme iLampa -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/online-navigation-tests/DerivedData \
  -resultBundlePath build/online-navigation-tests/Navigation.xcresult \
  -only-testing:iLampaRuntimeTests/RealWebKitBootstrapTests \
  -only-testing:iLampaRuntimeTests/PlaybackSelectionGateTests \
  -only-testing:iLampaRuntimeTests/MediaDetailResolutionIntentTests \
  -only-testing:iLampaRuntimeTests/OnlineModStatusTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  AD_HOC_CODE_SIGNING_ALLOWED=YES 2>&1 | tee build/online-navigation-tests/xcodebuild.log
status=${PIPESTATUS[0]}
set -e
if [ -d build/online-navigation-tests/Navigation.xcresult ]; then
  ditto -c -k --keepParent build/online-navigation-tests/Navigation.xcresult build/online-navigation-tests/Navigation.xcresult.zip
fi
exit "$status"
