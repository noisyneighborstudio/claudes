#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

sh -n claudes shell/claude-as
zsh -n install.sh uninstall.sh make-claude-profile.sh tray/build.sh scripts/release-build.sh shell/claudes.zsh
bash -n shell/claudes.bash
command -v fish >/dev/null && fish -n shell/claudes.fish
swiftc -typecheck tray/main.swift

if ./make-claude-profile.sh As >/dev/null 2>&1; then
  echo "Reserved profile name was accepted" >&2
  exit 1
fi

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
home="$test_root/home"
shim_bin="$test_root/shims"
foreign_bin="$test_root/foreign-bin"
mkdir -p "$home/.claude-profiles/Expo" "$home/.claude-profiles/Work" \
  "$home/.claude-profiles/As" "$home/.claude-profiles/default" \
  "$shim_bin" "$foreign_bin" "$test_root/foreign"
bad_name=$(printf 'Bad\nclaude')
mkdir "$home/.claude-profiles/$bad_name"

ln -s /usr/bin/false "$foreign_bin/claude-work"
ln -s "$test_root/foreign/claude-as" "$shim_bin/claude-client"
ln -s "$PWD/shell/claude-as" "$shim_bin/claude-old"

HOME="$home" PATH="$foreign_bin:$shim_bin:/usr/bin:/bin" sh -c '
  test_bin=$1
  set -- help
  . "$0" >/dev/null
  bin_dir() { echo "$test_bin"; }
  cmd_shims
' "$PWD/claudes" "$shim_bin"

for name in claude-as claude-default claude-expo; do
  test "$(readlink "$shim_bin/$name")" = "$PWD/shell/claude-as"
done
test ! -e "$shim_bin/claude"
test ! -e "$shim_bin/claude-work"
test ! -e "$shim_bin/claude-old"
test "$(readlink "$shim_bin/claude-client")" = "$test_root/foreign/claude-as"

profiles=$(HOME="$home" ./claudes profiles)
printf '%s\n' "$profiles" | grep -qx Default
printf '%s\n' "$profiles" | grep -qx Expo
if printf '%s\n' "$profiles" | grep -Eq '^(As|as|default|Bad|bad|claude)$'; then
  echo "Invalid or reserved profile was discovered" >&2
  exit 1
fi

ln -s /usr/bin/true "$shim_bin/claude"
HOME="$home" PATH="$shim_bin:/usr/bin:/bin" "$shim_bin/claude-expo" --version

HOME="$home" PATH="$foreign_bin:$shim_bin:/usr/bin:/bin" sh -c '
  test_bin=$1
  set -- help
  . "$0" >/dev/null
  bin_dir() { echo "$test_bin"; }
  cmd_shims --remove
' "$PWD/claudes" "$shim_bin"

test "$(readlink "$shim_bin/claude-client")" = "$test_root/foreign/claude-as"
test "$(readlink "$shim_bin/claude")" = /usr/bin/true
echo "All tests passed"
