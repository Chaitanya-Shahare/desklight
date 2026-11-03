#!/bin/sh
# Builds DeskLight.app into ./build. Usage: scripts/build-app.sh [--install]
set -eu
cd "$(dirname "$0")/.."
swift build -c release
APP=build/DeskLight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DeskLight" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
KC="$HOME/Library/Keychains/desklight-signing.keychain-db"
if [ -f "$KC" ]; then
  # Stable identity → macOS keeps Bluetooth permission across rebuilds.
  security unlock-keychain -p desklight "$KC"
  # Self-signed (untrusted) identities must be selected by SHA-1, not name.
  ID=$(security find-certificate -c "DeskLight Local Signing" -Z "$KC" | awk '/SHA-1/{print $3}')
  codesign --force --sign "$ID" "$APP"
else
  echo "warning: ad-hoc signing; run scripts/setup-signing.sh to stop repeated Bluetooth prompts"
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/DeskLight.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/DeskLight.app"
fi
