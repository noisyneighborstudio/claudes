#!/bin/zsh
# Removes Claudes.app. Profiles (cloned apps, logins, CLI configs) are listed
# but only removed if you pass --purge.
set -euo pipefail

pkill -f ClaudeTray 2>/dev/null || true
rm -rf /Applications/Claudes.app
echo "✓ Removed Claudes.app"

if grep -qF '# claudes' "$HOME/.zshrc" 2>/dev/null; then
  sed -i '' '/# claudes$/d' "$HOME/.zshrc"
  echo "✓ Removed shell helper line from ~/.zshrc"
fi

setopt null_glob
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
