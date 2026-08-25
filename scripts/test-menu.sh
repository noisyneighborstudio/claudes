#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

source_file=tray/main.swift

require_text() {
  if ! grep -Fq "$1" "$source_file"; then
    echo "Missing menu contract: $1" >&2
    exit 1
  fi
}

require_order() {
  first=$(grep -nF "$1" "$source_file" | head -1 | cut -d: -f1)
  second=$(grep -nF "$2" "$source_file" | head -1 | cut -d: -f1)
  if [ -z "$first" ] || [ -z "$second" ] || [ "$first" -ge "$second" ]; then
    echo "Menu contract is out of order: $1 before $2" >&2
    exit 1
  fi
}

require_last_order() {
  first=$(grep -nF "$1" "$source_file" | tail -1 | cut -d: -f1)
  second=$(grep -nF "$2" "$source_file" | tail -1 | cut -d: -f1)
  if [ -z "$first" ] || [ -z "$second" ] || [ "$first" -ge "$second" ]; then
    echo "Menu contract is out of order: $1 before $2" >&2
    exit 1
  fi
}

# Top-level rows retain visible profile state while secondary actions stay nested.
require_text 'item.state = active == profile.name ? .on : .off'
require_text 'marker = "⏳"'
require_text 'suffix = "  ⬆️ update pending"'
require_text 'NSMenuItem(title: "Sessions"'
require_text 'NSMenuItem(title: "Manage Profile"'
require_text 'NSMenuItem(title: "Manage Claudes"'

# Frequent actions remain first and directly reachable in every profile menu.
require_order 'actionItem("Set as Active (Global)", #selector(setActiveProfile' 'actionItem("Open Desktop App", #selector(openDesktop'
require_order 'actionItem("Open Desktop App", #selector(openDesktop' 'actionItem("Open Claude Code (\(preferredTerminal.name))", #selector(openTerminal'
require_last_order 'actionItem("Open Claude Code (\(preferredTerminal.name))", #selector(openTerminal' 'let sessionsItem = NSMenuItem(title: "Sessions"'

# Existing secondary capabilities remain mapped to their original handlers.
require_text 'NSMenuItem(title: "Open Claude Code In", action: nil'
require_text '#selector(openTerminalIn(_:))'
require_text '#selector(transferProfileSession(_:))'
require_text '#selector(copyCommand(_:))'
require_text '#selector(revealData(_:))'
require_text '#selector(newProfile(_:))'
require_text '#selector(repatchAll(_:))'
require_text '#selector(toggleAutoRepatch(_:))'
require_text '#selector(selfUpdate(_:))'

# Deletion is last in Manage Profile and still has running/repatch/confirmation guards.
require_order '#selector(revealData(_:))' 'manageMenu.addItem(.separator())'
require_order 'manageMenu.addItem(.separator())' '#selector(deleteProfile(_:))'
require_text 'if isRunning(p) {'
require_text 'if repatchInFlight.contains(p.name) {'
require_text 'guard choice != .alertThirdButtonReturn else { return }'
require_text 'alert("Delete failed", result.output)'

# The documented proposal includes every interaction state introduced above.
for screenshot in menu-v5-profile.png menu-v5-sessions.png menu-v5-manage.png; do
  test -s "docs/$screenshot"
  grep -Fq "docs/$screenshot" README.md
done

echo "Menu contract tests passed"
