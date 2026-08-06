#!/bin/zsh
# Builds tray/build/Claudes.app with the profile scripts embedded in Resources.
# Signing: uses a "Developer ID Application" identity if one is in the keychain
# (override with CLAUDES_SIGN_IDENTITY), otherwise falls back to ad-hoc.
set -euo pipefail
cd "${0:A:h}"

command -v swiftc >/dev/null || { echo "✗ swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2; exit 1 }

app="build/Claudes.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

echo "Compiling…"
swiftc -O main.swift -o "$app/Contents/MacOS/ClaudeTray"
swiftc -O icon-badge.swift -o "$app/Contents/Resources/icon-badge"
cp Info.plist "$app/Contents/"

# Version: explicit CLAUDES_VERSION (CI) > latest git tag (source builds) > 0.0.0.
# Self-update compares this against the latest GitHub release.
ver=${CLAUDES_VERSION:-$(git -C .. describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
ver=${ver:-0.0.0}
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ver" "$app/Contents/Info.plist"
echo "Version: $ver"
cp ../make-claude-profile.sh ../repatch-claude-profiles.sh "$app/Contents/Resources/"
cp ../shell/claudes.zsh "$app/Contents/Resources/"
chmod +x "$app/Contents/Resources/"*.sh

# App icon: build multi-res icns from claudes.png
iconset=$(mktemp -d)/claudes.iconset
mkdir -p "$iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz claudes.png --out "$iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) claudes.png --out "$iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/claudes.icns"
rm -rf "${iconset:h}"

identity=${CLAUDES_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}
if [[ -n ${identity:-} ]]; then
  echo "Signing with: $identity"
  codesign --force --options runtime --sign "$identity" "$app/Contents/Resources/icon-badge"
  codesign --force --options runtime --entitlements entitlements.plist --sign "$identity" "$app"
else
  echo "No Developer ID identity found — signing ad-hoc (fine for local use)."
  codesign --force -s - "$app/Contents/Resources/icon-badge"
  codesign --force -s - "$app"
fi
codesign -v "$app"

echo "Built $app"
echo "Install:  cp -R $app /Applications/  (then open it, optionally add to Login Items)"
