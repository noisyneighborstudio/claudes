#!/bin/zsh
# Builds tray/build/Claudes.app with the profile scripts embedded in Resources.
# Signing: uses a "Developer ID Application" identity if one is in the keychain
# (override with CLAUDES_SIGN_IDENTITY), otherwise falls back to ad-hoc.
set -euo pipefail
cd "${0:A:h}"

command -v swift >/dev/null || { echo "✗ swift not found. Install Xcode Command Line Tools: xcode-select --install" >&2; exit 1 }

app="build/Claudes.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"

echo "Compiling…"
swift build --package-path .. -c release --product ClaudeTray
bin_dir=$(swift build --package-path .. -c release --show-bin-path)
cp "$bin_dir/ClaudeTray" "$app/Contents/MacOS/ClaudeTray"
sparkle_framework=$(find ../.build -type d -name Sparkle.framework -print -quit)
[[ -n $sparkle_framework ]] || { echo "✗ Sparkle.framework was not produced" >&2; exit 1; }
ditto "$sparkle_framework" "$app/Contents/Frameworks/Sparkle.framework"
swiftc -O icon-badge.swift -o "$app/Contents/Resources/icon-badge"
cp Info.plist "$app/Contents/"

# Version: explicit CLAUDES_VERSION (CI) > latest git tag (source builds) > 0.0.0.
# Sparkle uses these values when comparing entries in the selected appcast.
ver=${CLAUDES_VERSION:-$(git -C .. describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
ver=${ver:-0.0.0}
build_ver=${CLAUDES_BUILD_VERSION:-1}
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ver" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_ver" "$app/Contents/Info.plist"
if [[ -n ${CLAUDES_SPARKLE_PUBLIC_KEY:-} ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $CLAUDES_SPARKLE_PUBLIC_KEY" "$app/Contents/Info.plist"
elif [[ ${CLAUDES_RELEASE_BUILD:-0} == 1 ]]; then
  echo "✗ CLAUDES_SPARKLE_PUBLIC_KEY is required for release builds" >&2
  exit 1
fi
echo "Version: $ver ($build_ver)"
cp ../make-claude-profile.sh ../repatch-claude-profiles.sh ../claudes "$app/Contents/Resources/"
cp ../shell/claudes.zsh ../shell/claudes.bash ../shell/claudes.fish ../shell/claude-as "$app/Contents/Resources/"
chmod +x "$app/Contents/Resources/"*.sh "$app/Contents/Resources/claudes" "$app/Contents/Resources/claude-as"

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
  sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  for nested in \
    "$sparkle/XPCServices/Downloader.xpc" \
    "$sparkle/XPCServices/Installer.xpc" \
    "$sparkle/Autoupdate" \
    "$sparkle/Updater.app" \
    "$app/Contents/Frameworks/Sparkle.framework" \
    "$app/Contents/Resources/icon-badge"
  do
    codesign --force --timestamp --options runtime --sign "$identity" "$nested"
  done
  codesign --force --timestamp --options runtime --entitlements entitlements.plist --sign "$identity" "$app"
else
  echo "No Developer ID identity found — signing ad-hoc (fine for local use)."
  codesign --force -s - "$app/Contents/Frameworks/Sparkle.framework"
  codesign --force -s - "$app/Contents/Resources/icon-badge"
  codesign --force -s - "$app"
fi
codesign -v "$app"

echo "Built $app"
echo "Install:  cp -R $app /Applications/  (then open it, optionally add to Login Items)"
