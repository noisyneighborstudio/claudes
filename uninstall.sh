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

# Filter helper lines out via a temp file + `cat >` — writes through rc files
# that are symlinks into a dotfiles repo, which BSD `sed -i` refuses to edit.
for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
  if grep -qF '# claudes' "$rc" 2>/dev/null; then
    tmp=$(mktemp)
    grep -v '# claudes$' "$rc" > "$tmp" || true
    cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "✓ Removed shell helper line from ${rc/#$HOME/~}"
  fi
done

if [[ -f $HOME/.config/fish/conf.d/claudes.fish ]]; then
  rm "$HOME/.config/fish/conf.d/claudes.fish"
  echo "✓ Removed fish helper stub"
fi

# PATH symlink — only if it actually points into Claudes.app.
for bindir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  link="$bindir/claudes"
  if [[ -L $link && $(readlink "$link") == *Claudes.app* ]]; then
    rm "$link"
    echo "✓ Removed $link"
  fi
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
