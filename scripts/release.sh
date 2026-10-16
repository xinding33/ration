#!/bin/bash
# Builds a Developer ID signed, notarized and stapled dist/Ration-VERSION.zip.
# Notary credentials: NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID (an App Store
# Connect API key), or else the "ration-notary" notarytool keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."
export RATION_SIGN_IDENTITY="${RATION_SIGN_IDENTITY:-Developer ID Application}"
bash scripts/build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/Ration.app/Contents/Info.plist)"

if [ -n "${NOTARY_KEY_ID:-}" ]; then
  CREDENTIALS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  CREDENTIALS=(--keychain-profile ration-notary)
fi
RESULT="$(xcrun notarytool submit dist/Ration.zip "${CREDENTIALS[@]}" --wait --output-format json)"
ID="$(plutil -extract id raw -o - - <<<"$RESULT")"
if [ "$(plutil -extract status raw -o - - <<<"$RESULT")" != "Accepted" ]; then
  xcrun notarytool log "$ID" "${CREDENTIALS[@]}" >&2
  exit 1
fi

xcrun stapler staple dist/Ration.app
spctl --assess --type execute --verbose=2 dist/Ration.app
ZIP="dist/Ration-$VERSION.zip"
rm dist/Ration.zip
ditto -c -k --sequesterRsrc --keepParent dist/Ration.app "$ZIP"
printf 'Notarized: %s\nsha256: %s\n' "$ZIP" "$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
