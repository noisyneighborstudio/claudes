#!/bin/zsh
# Builds Claudes.app from source and installs it to /Applications.
set -euo pipefail

if [[ -f ${0:A:h}/tray/build.sh ]]; then
  cd "${0:A:h}"
else
  # curl | zsh mode — clone first
  tmp=$(mktemp -d)
  echo "Cloning claudes…"
  git clone --depth 1 https://github.com/sethwebster/claudes "$tmp/claudes"
  cd "$tmp/claudes"
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Starting install — re-run this script after it finishes."
  xcode-select --install
  exit 1
fi

./tray/build.sh

pkill -f ClaudeTray 2>/dev/null || true
rm -rf /Applications/Claudes.app
cp -R tray/build/Claudes.app /Applications/
open /Applications/Claudes.app

echo ""
echo "✓ Installed. Look for 🤖 in the menu bar."
echo "  Optional: add Claudes to System Settings → Login Items."
echo "  Optional shell helper: source $(pwd)/shell/claudes.zsh in ~/.zshrc"
