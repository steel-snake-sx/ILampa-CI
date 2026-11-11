#!/bin/bash
set -euo pipefail
SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; xs=[x for k in sorted(d,reverse=True) if "iOS" in k for x in d[k] if x["name"].startswith("iPhone")]; print(xs[0]["udid"] if xs else "")')
if [ -z "$SIMULATOR_ID" ]; then echo "No available iPhone simulator" >&2; exit 1; fi
mkdir -p build/legacy-settings-tests
node tests/unit/test_legacy_settings_contract.js | tee build/legacy-settings-tests/contract.log
node tests/runtime/legacy_settings_bridge.test.js | tee build/legacy-settings-tests/bridge.log
set +e
xcodebuild test -project iLampa.xcodeproj -scheme iLampa -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/legacy-settings-tests/DerivedData \
  -resultBundlePath build/legacy-settings-tests/LegacySettings.xcresult \
  -only-testing:iLampaRuntimeTests/LegacyPluginSettingTests \
  -only-testing:iLampaRuntimeTests/RealWebKitBootstrapTests/testLegacySettingsInRealWebKit \
  -only-testing:iLampaRuntimeTests/RealWebKitBootstrapTests/testUnmodifiedHeadFilterLegacyRegistrationInRealWebKit \
  -only-testing:iLampaUITests/iLampaUITests/testLegacySettingsAppearInProductionPluginDetail \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  AD_HOC_CODE_SIGNING_ALLOWED=YES 2>&1 | tee build/legacy-settings-tests/xcodebuild.log
status=${PIPESTATUS[0]}
set -e
if [ -d build/legacy-settings-tests/LegacySettings.xcresult ]; then
  ditto -c -k --keepParent build/legacy-settings-tests/LegacySettings.xcresult build/legacy-settings-tests/LegacySettings.xcresult.zip
fi
exit "$status"
