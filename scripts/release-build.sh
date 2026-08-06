#!/bin/zsh
# CI release build: stamp version, build (signs if a Developer ID identity is
# in the keychain), notarize + staple when notary credentials are present,
# and produce Claudes.zip for the GitHub release asset.
set -euo pipefail
ver=${1:?usage: release-build.sh <version>}
cd "${0:A:h}/.."

CLAUDES_VERSION=$ver ./tray/build.sh

if [[ -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_KEY_ISSUER:-} && -n ${NOTARY_KEY_P8:-} ]]; then
  echo "Notarizing…"
  echo "$NOTARY_KEY_P8" > notary.p8
  ditto -c -k --keepParent tray/build/Claudes.app Claudes.zip
  xcrun notarytool submit Claudes.zip --key notary.p8 \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER" --wait
  xcrun stapler staple tray/build/Claudes.app
  rm -f notary.p8 Claudes.zip
else
  echo "Notary credentials not set — skipping notarization (in-app self-update still works; direct downloads will hit Gatekeeper until secrets are added)."
fi

ditto -c -k --keepParent tray/build/Claudes.app Claudes.zip
echo "Release artifact: Claudes.zip (v$ver)"
