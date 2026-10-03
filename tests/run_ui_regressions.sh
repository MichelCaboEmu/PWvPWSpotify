#!/usr/bin/env bash
set -euo pipefail
STAGE=$(mktemp -d)
APP="$STAGE/PWUIRegression.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-ios16.0-simulator" \
  overlays/spotipw/Downloads/PWSpotifyVisuals.swift overlays/spotipw/Downloads/PWTrackMenuHeader.swift \
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
import subprocess,sys
p=subprocess.run(['xcrun','simctl','launch','--console','--terminate-running-process',sys.argv[1],'pw.ui.regression'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
print(p.stdout)
if 'UI PASS:' not in p.stdout or 'UI FAIL:' in p.stdout: sys.exit(1)
PY
