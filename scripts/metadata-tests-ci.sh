#!/bin/bash
set -euo pipefail

# No archive, IPA, upload, push or remote plugin fetch is performed here.
SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; xs=[x for k in sorted(d,reverse=True) if "iOS" in k for x in d[k] if x["name"].startswith("iPhone")]; xs.sort(key=lambda x: 0 if x["name"] == "iPhone XS" else 1); print(xs[0]["udid"] if xs else "")')
if [ -z "$SIMULATOR_ID" ]; then
  echo "No available iPhone simulator" >&2
  exit 1
fi
mkdir -p build/metadata-tests
node tests/runtime/metadata_bridge.test.js | tee build/metadata-tests/javascript.log
set +e
xcodebuild test \
  -project iLampa.xcodeproj -scheme iLampa -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/metadata-tests/DerivedData \
  -resultBundlePath build/metadata-tests/Metadata.xcresult \
  -only-testing:iLampaRuntimeTests/PluginNativeCapabilityTests \
  -only-testing:iLampaRuntimeTests/RealWebKitBootstrapTests/testManagedMetadataProviderInRealWebKit \
  -only-testing:iLampaUITests/iLampaUITests/testMetadataPluginAppearsInProductionDetailAndCleansUp \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  AD_HOC_CODE_SIGNING_ALLOWED=YES 2>&1 | tee build/metadata-tests/xcodebuild.log
status=${PIPESTATUS[0]}
set -e
if [ -d build/metadata-tests/Metadata.xcresult ]; then
  # Includes XCTest results and keepAlways UI screenshot attachments.
  ditto -c -k --keepParent build/metadata-tests/Metadata.xcresult build/metadata-tests/Metadata.xcresult.zip
fi
exit "$status"
