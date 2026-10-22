#!/usr/bin/env bash
# Runs the UI tests on an iPhone simulator with a Dynamic Island (an iPhone Pro), against the stub server and, for
# the sign-in test, the real site and copies their screenshots, UI snapshots and the app's log to
# ./test-output/. These show the configured site and app: CI encrypts them before uploading.
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
mkdir -p test-output build
# the stub server the app tests run against (StubServer/)
(cd StubServer && npm install --no-audit --no-fund --silent)
node StubServer/server.mjs 8787 > test-output/stub.log 2>&1 &
STUB=$!
trap 'kill $STUB 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf http://127.0.0.1:8787/healthz >/dev/null && break; sleep 1; done
xcrun simctl addmedia "$UDID" UITests/test-photo.jpg || true
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
import json, os, re
m = json.load(open("test-output/manifest.json"))
for test in m:
    for a in test.get("attachments", []):
        src = os.path.join("test-output", a["exportedFileName"])
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        if not os.path.exists(src):
            continue
        if name.startswith("Debug description"):
            os.remove(src)
            continue
        name = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
        os.rename(src, os.path.join("test-output", name))
P
fi
xcrun simctl spawn "$UDID" log show --last 30m --style compact \
  --predicate 'eventMessage CONTAINS "PWAShell" OR (process == "PWAShell" AND messageType == error)' > test-output/app-log.txt 2>&1 || true
# host classes and error codes only (see ShellViewController.hostClass): safe for a public log
grep -o "PWAShell .*" test-output/app-log.txt | tail -n 40 || true
echo "test-output: $(find test-output -type f | wc -l) files (encrypted upload; names can carry the bundle id)"
exit "$STATUS"
