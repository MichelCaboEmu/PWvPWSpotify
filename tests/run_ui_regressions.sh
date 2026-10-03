#!/usr/bin/env bash
set -euo pipefail
STAGE=$(mktemp -d)
APP="$STAGE/PWUIRegression.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-ios16.0-simulator" \
  overlays/spotipw/Downloads/PWSpotifyVisuals.swift overlays/spotipw/Downloads/PWTrackMenuHeader.swift overlays/spotipw/Downloads/PWTrackMenuLayout.swift \
  tests/ui_regressions.swift -o "$APP/PWUIRegression"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>pw.ui.regression</string><key>CFBundleExecutable</key><string>PWUIRegression</string><key>CFBundleName</key><string>PWUIRegression</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1</string><key>LSRequiresIPhoneOS</key><true/><key>UIDeviceFamily</key><array><integer>1</integer></array><key>UILaunchScreen</key><dict/></dict></plist>
PLIST
codesign --force --sign - "$APP"
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if x["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
python3 - "$DEVICE" <<'PY'
import pathlib,subprocess,sys,time
device=sys.argv[1]
container=subprocess.check_output(['xcrun','simctl','get_app_container',device,'pw.ui.regression','data'],text=True,timeout=30).strip()
result=pathlib.Path(container)/'Documents'/'ui-result.txt'
result.unlink(missing_ok=True)
# Do not attach simctl's console pipe: on a cold runner it can remain attached
# after the app exits. The app records its actual assertions atomically instead.
p=subprocess.run(['xcrun','simctl','launch','--terminate-running-process',device,'pw.ui.regression'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=180)
print(p.stdout,flush=True)
if p.returncode: sys.exit(p.returncode)
deadline=time.monotonic()+180
last='UI has not started its assertions'
while time.monotonic()<deadline:
    if result.exists():
        message=result.read_text()
        if message!=last: print(message,flush=True); last=message
        if message.startswith('UI PASS:'): sys.exit(0)
        if message.startswith('UI FAIL:'): sys.exit(1)
    time.sleep(1)
print('UI TIMEOUT: '+last,flush=True)
subprocess.run(['xcrun','simctl','terminate',device,'pw.ui.regression'],timeout=30,check=False)
sys.exit(1)
PY
