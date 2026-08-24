#!/bin/zsh
# Installs Claudes.app: prefers the latest signed GitHub release; falls back to
# building from source (requires Xcode Command Line Tools).
# Force a source build with: CLAUDES_FROM_SOURCE=1 ./install.sh
set -euo pipefail

REPO="noisyneighborstudio/claudes"

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

# Shell helpers: tab completion for claudes / claude-as, for every shell the
# user actually has (zsh, bash, fish). The commands themselves go on PATH
# below. Sourced from the installed app so there's one stable path; the guards
# make the lines inert if Claudes is ever removed.
res="/Applications/Claudes.app/Contents/Resources"

zsh_line='[[ -f "'"$res"'/claudes.zsh" ]] && source "'"$res"'/claudes.zsh"  # claudes'
if [[ -w $HOME/.zshrc || ! -e $HOME/.zshrc ]] && ! grep -qF '# claudes' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n%s\n' "$zsh_line" >> "$HOME/.zshrc"
  echo "✓ Shell helper added to ~/.zshrc"
fi

bash_line='[ -f "'"$res"'/claudes.bash" ] && . "'"$res"'/claudes.bash"  # claudes'
for rc in "$HOME/.bash_profile" "$HOME/.bashrc"; do
  [[ -f $rc && -w $rc ]] || continue
  grep -qF '# claudes' "$rc" 2>/dev/null && continue
  printf '\n%s\n' "$bash_line" >> "$rc"
  echo "✓ Shell helper added to ${rc/#$HOME/~}"
done

if [[ -d $HOME/.config/fish ]]; then
  mkdir -p "$HOME/.config/fish/conf.d"
  printf 'test -f "%s/claudes.fish"; and source "%s/claudes.fish"  # claudes\n' "$res" "$res" \
    > "$HOME/.config/fish/conf.d/claudes.fish"
  echo "✓ Shell helper added to ~/.config/fish/conf.d/claudes.fish"
fi

# `claudes` CLI on PATH for every shell (bash/fish/scripts), not just zsh.
cli_src="/Applications/Claudes.app/Contents/Resources/claudes"
linked_bin=""
for bindir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  [[ $bindir == "$HOME/.local/bin" ]] && mkdir -p "$bindir" 2>/dev/null
  if [[ -d $bindir && -w $bindir ]]; then
    dest="$bindir/claudes"
    if [[ -e $dest || -L $dest ]] && [[ ! -L $dest || $(readlink "$dest") != "$cli_src" ]]; then
      echo "✗ $dest exists and isn't owned by Claudes; leaving it unchanged." >&2
      break
    fi
    ln -sf "$cli_src" "$bindir/claudes"
    linked_bin="$bindir"
    echo "✓ claudes CLI linked at $bindir/claudes"
    break
  fi
done

if [[ $linked_bin == "$HOME/.local/bin" && :$PATH: != *":$HOME/.local/bin:"* ]]; then
  path_line='export PATH="$HOME/.local/bin:$PATH"  # claudes-path'
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [[ $rc == "$HOME/.zshrc" || -f $rc ]] || continue
    [[ -w $rc || ! -e $rc ]] || continue
    grep -qF '# claudes-path' "$rc" 2>/dev/null && continue
    printf '\n%s\n' "$path_line" >> "$rc"
    echo "✓ ~/.local/bin added to ${rc/#$HOME/~}"
  done
  fish_stub="$HOME/.config/fish/conf.d/claudes.fish"
  if [[ -f $fish_stub ]] && ! grep -qF '# claudes-path' "$fish_stub"; then
    printf 'fish_add_path "$HOME/.local/bin"  # claudes-path\n' >> "$fish_stub"
    echo "✓ ~/.local/bin added to fish PATH"
  fi
  export PATH="$HOME/.local/bin:$PATH"
fi

# claude-as / claude-<profile> as real executables, so apps, editors and
# scripts that never source a shell rc can pin a profile too.
"$cli_src" shims || echo "✗ Couldn't create profile commands — run 'claudes shims' once a PATH dir is writable." >&2

echo ""
echo "✓ Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Claudes.app/Contents/Info.plist 2>/dev/null | sed 's/^/v/'). Look for the Claudes icon in the menu bar."
echo "  Optional: add Claudes to System Settings → Login Items."
