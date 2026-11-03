#!/bin/bash
# Builds build/Embertrail.app and runs the self-test. ./build.sh --install also copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Embertrail.app
TARGET="$(uname -m)-apple-macos14.0"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$TARGET" Sources/*.swift -o "$APP/Contents/MacOS/Embertrail"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources/Art"
cp Resources/Art/*.png "$APP/Contents/Resources/Art/"
"$APP/Contents/MacOS/Embertrail" --selftest
codesign --force --sign - "$APP"
echo "built $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Embertrail || true
  rm -rf /Applications/Embertrail.app
  cp -R "$APP" /Applications/
  echo "installed /Applications/Embertrail.app"
fi
