#!/bin/zsh
# Removes Claudes.app and everything install.sh / the tray wired up: shell
# helper lines (zsh/bash), the fish conf.d stub, the `claudes` PATH symlink,
# Warp launch configs, tray defaults — and un-migrates ~/.claude if `claudes
# use` turned it into a symlink, so plain `claude` keeps working afterwards.
# Profiles (cloned apps, logins, CLI configs) are listed but only removed if
# you pass --purge. Your original default config is always restored, never
# purged.
set -euo pipefail
setopt null_glob

pkill -f ClaudeTray 2>/dev/null || true
rm -rf /Applications/Claudes.app
echo "✓ Removed Claudes.app"

# Un-migrate the global profile switch: put the real ~/.claude back.
if [[ -L $HOME/.claude ]]; then
  rm "$HOME/.claude"
  if [[ -d $HOME/.claude-profiles/Default ]]; then
    mv "$HOME/.claude-profiles/Default" "$HOME/.claude"
    echo "✓ Restored ~/.claude (was a symlink; moved ~/.claude-profiles/Default back)"
  else
    echo "✓ Removed dangling ~/.claude symlink (no migrated Default to restore)"
  fi
fi

# Filter the exact installed helper lines via a temp file + `cat >`. This writes
# through rc files that are symlinks into a dotfiles repo, which BSD `sed -i`
# refuses to edit.
res="/Applications/Claudes.app/Contents/Resources"
zsh_line='[[ -f "'"$res"'/claudes.zsh" ]] && source "'"$res"'/claudes.zsh"  # claudes'
bash_line='[ -f "'"$res"'/claudes.bash" ] && . "'"$res"'/claudes.bash"  # claudes'
path_line='export PATH="$HOME/.local/bin:$PATH"  # claudes-path'
fish_line='test -f "'"$res"'/claudes.fish"; and source "'"$res"'/claudes.fish"  # claudes'
fish_path_line='fish_add_path "$HOME/.local/bin"  # claudes-path'
for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
  if grep -qF -e "$zsh_line" -e "$bash_line" -e "$path_line" "$rc" 2>/dev/null; then
    tmp=$(mktemp)
    grep -vF -e "$zsh_line" -e "$bash_line" -e "$path_line" "$rc" > "$tmp" || true
    cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "✓ Removed shell helper line from ${rc/#$HOME/~}"
  fi
done

fish_stub="$HOME/.config/fish/conf.d/claudes.fish"
if grep -qF -e "$fish_line" -e "$fish_path_line" "$fish_stub" 2>/dev/null; then
  tmp=$(mktemp)
  grep -vF -e "$fish_line" -e "$fish_path_line" "$fish_stub" > "$tmp" || true
  if [[ -s $tmp ]]; then
    cat "$tmp" > "$fish_stub"
  else
    rm "$fish_stub"
  fi
  rm -f "$tmp"
  echo "✓ Removed fish helper lines"
fi

# PATH symlinks — the CLI plus the claude-as / claude-<profile> shims, only
# where they actually point into Claudes.app.
cli_target="/Applications/Claudes.app/Contents/Resources/claudes"
shim_target="/Applications/Claudes.app/Contents/Resources/claude-as"
for bindir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  for link in "$bindir/claudes" "$bindir"/claude-*; do
    [[ -L $link ]] || continue
    target=$(readlink "$link")
    [[ $target == "$cli_target" || $target == "$shim_target" ]] || continue
    rm "$link"
    echo "✓ Removed $link"
  done
done

rm -f "$HOME/.warp/launch_configurations"/claudes-*.yaml
defaults delete dev.sethwebster.claudes 2>/dev/null || true

apps=(/Applications/Claude-*.app)
cfgs=("$HOME/.claude-profiles"/*(N))

if [[ ${1:-} == "--purge" ]]; then
  for app in $apps; do rm -rf "$app"; echo "✓ Removed $app"; done
  for d in "$HOME/Library/Application Support"/Claude-*(N); do rm -rf "$d"; echo "✓ Removed $d"; done
  rm -rf "$HOME/.claude-profiles"
  echo "✓ Removed CLI profile configs"
elif (( ${#apps} + ${#cfgs} > 0 )); then
  echo ""
  echo "Profiles left in place (remove with: ./uninstall.sh --purge):"
  for app in $apps; do echo "  $app"; done
  (( ${#cfgs} > 0 )) && echo "  ~/.claude-profiles/"
fi
