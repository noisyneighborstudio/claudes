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

# Shell helper: per-profile commands (claude-work, claude-expo, …) + claude-as.
# Sourced from the installed app so there's one stable path; the guard makes the
# line inert if Claudes is ever removed.
helper_line='[[ -f "/Applications/Claudes.app/Contents/Resources/claudes.zsh" ]] && source "/Applications/Claudes.app/Contents/Resources/claudes.zsh"  # claudes'
if [[ -w $HOME/.zshrc || ! -e $HOME/.zshrc ]] && ! grep -qF '# claudes' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n%s\n' "$helper_line" >> "$HOME/.zshrc"
  echo "✓ Shell helper added to ~/.zshrc (new shells get claude-<profile> commands)"
fi

echo ""
echo "✓ Installed. Look for 🤖 in the menu bar."
echo "  Optional: add Claudes to System Settings → Login Items."
