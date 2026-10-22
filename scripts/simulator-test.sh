#!/usr/bin/env bash
# Runs the UI tests on an iPhone simulator and copies their screenshots to ./test-output/.
# Needs a generated project (scripts/configure.sh). Usage: scripts/simulator-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devs=[d for rt,ds in json.load(sys.stdin)["devices"].items() if "iOS" in rt for d in ds if d["name"].startswith("iPhone")]
pro=[d for d in devs if "Pro" in d["name"] and "Max" not in d["name"]]
print((pro or devs)[-1]["udid"])')
echo "simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
rm -rf build/test.xcresult test-output
mkdir -p test-output
set +e
xcodebuild test -project PWAShell.xcodeproj -scheme PWAShell -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build/sim -resultBundlePath build/test.xcresult \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= 2>&1 | tee build/test.log | grep -E "error:|Test Case|\*\* TEST|XCTAssert" 
STATUS=${PIPESTATUS[0]}
set -e
xcrun xcresulttool export attachments --path build/test.xcresult --output-path test-output >/dev/null 2>&1 || true
# name the files after their attachment names
if [[ -f test-output/manifest.json ]]; then
  python3 - <<'P'
import json, os
m = json.load(open("test-output/manifest.json"))
for test in m:
    for a in test.get("attachments", []):
        src = os.path.join("test-output", a["exportedFileName"])
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        if os.path.exists(src):
            os.rename(src, os.path.join("test-output", name.replace("/", "_")))
P
fi
ls -la test-output
exit "$STATUS"
