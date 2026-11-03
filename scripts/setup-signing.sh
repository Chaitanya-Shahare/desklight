#!/bin/sh
# One-time: creates a self-signed code-signing identity in a dedicated keychain so
# rebuilt DeskLight.app keeps the same signature (macOS keeps the Bluetooth permission).
set -eu
KC="$HOME/Library/Keychains/desklight-signing.keychain-db"
PW="desklight"
NAME="DeskLight Local Signing"
[ -f "$KC" ] && { echo "Already set up: $KC"; exit 0; }
TMP=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:$PW
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"   # no auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
rm -rf "$TMP"
# codesign only finds identities in the user search list.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
echo "Created $KC"
