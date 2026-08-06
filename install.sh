#!/bin/zsh
# Installs Claudes.app: prefers the latest signed GitHub release; falls back to
# building from source (requires Xcode Command Line Tools).
# Force a source build with: CLAUDES_FROM_SOURCE=1 ./install.sh
set -euo pipefail

REPO="sethwebster/claudes"

install_from_release() {
  local tmp url
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | /usr/bin/python3 -c "import json,sys; r=json.load(sys.stdin); print(next((a['browser_download_url'] for a in r.get('assets',[]) if a['name']=='Claudes.zip'), ''))" 2>/dev/null) || return 1
  [[ -n $url ]] || return 1
  echo "Installing from latest release…"
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/Claudes.zip" || return 1
  ditto -xk "$tmp/Claudes.zip" "$tmp" || return 1
  [[ -d "$tmp/Claudes.app" ]] || return 1
  # Signed but not notarized; installed by script, so clear the download quarantine.
  xattr -dr com.apple.quarantine "$tmp/Claudes.app" 2>/dev/null || true
  pkill -f ClaudeTray 2>/dev/null || true
  rm -rf /Applications/Claudes.app
  ditto "$tmp/Claudes.app" /Applications/Claudes.app
  rm -rf "$tmp"
}

install_from_source() {
  if [[ -f ${0:A:h}/tray/build.sh ]]; then
    cd "${0:A:h}"
  else
    local tmp
    tmp=$(mktemp -d)
    echo "Cloning $REPO…"
    git clone "https://github.com/$REPO" "$tmp/claudes"   # full clone: tags stamp the version
    cd "$tmp/claudes"
  fi
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required for source builds. Starting install — re-run this script after it finishes."
    xcode-select --install
    exit 1
  fi
  ./tray/build.sh
  pkill -f ClaudeTray 2>/dev/null || true
  rm -rf /Applications/Claudes.app
  cp -R tray/build/Claudes.app /Applications/
}

if [[ ${CLAUDES_FROM_SOURCE:-0} == 1 ]]; then
  install_from_source
elif ! install_from_release; then
  echo "No release available — building from source…"
  install_from_source
fi

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
echo "✓ Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Claudes.app/Contents/Info.plist 2>/dev/null | sed 's/^/v/'). Look for the Claudes icon in the menu bar."
echo "  Optional: add Claudes to System Settings → Login Items."