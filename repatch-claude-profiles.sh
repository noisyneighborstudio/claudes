#!/bin/zsh
# repatch-claude-profiles.sh — run after Claude.app auto-updates.
# Re-clones each Claude-<Name>.app from the freshly updated /Applications/Claude.app
# and re-applies the profile patches. Login/data is untouched (it lives in
# ~/Library/Application Support/Claude-<Name>, outside the bundle).
set -euo pipefail

here=${0:A:h}
[[ -d /Applications/Claude.app ]] || { echo "✗ Claude Desktop is not installed; nothing to repatch against." >&2; exit 1 }

setopt null_glob
apps=(/Applications/Claude-*.app)
if (( ${#apps} == 0 )); then
  echo "No Claude-*.app profiles found; nothing to repatch."
  exit 0
fi

failed=0
skipped=0
for app in $apps; do
  name=${${app:t:r}#Claude-}
  if pgrep -qf "user-data-dir=$HOME/Library/Application Support/Claude-$name"; then
    echo "⏭  Skipping $name — instance is running. Quit it and re-run."
    (( skipped++ )) || true
    continue
  fi
  echo "Repatching $name…"
  rm -rf "$app"
  if ! "$here/make-claude-profile.sh" "$name"; then
    echo "✗ Repatch failed for $name" >&2
    (( failed++ )) || true
  fi
done

echo ""
if (( failed > 0 )); then
  echo "✗ Done with $failed failure(s)." >&2
  exit 1
fi
(( skipped > 0 )) && echo "Done — $skipped profile(s) skipped (still running)." || echo "✓ All profiles repatched."
