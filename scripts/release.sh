#!/bin/sh
# Builds a universal (arm64 + x86_64) DeskLight.app and zips it for a GitHub release.
# Usage: scripts/release.sh 0.1.0   → dist/DeskLight-0.1.0.zip + its SHA-256
set -eu
VERSION="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DeskLight"

APP=dist/DeskLight.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

KC="$HOME/Library/Keychains/desklight-signing.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p desklight "$KC"
  ID=$(security find-certificate -c "DeskLight Local Signing" -Z "$KC" | awk '/SHA-1/{print $3}')
  codesign --force --sign "$ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

ZIP="dist/DeskLight-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
lipo -archs "$APP/Contents/MacOS/DeskLight"
shasum -a 256 "$ZIP"
