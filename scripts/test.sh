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
shim_bin="$home/.local/bin"
foreign_bin="$test_root/foreign-bin"
mkdir -p "$home/.claude-profiles/Expo" "$home/.claude-profiles/Work" \
  "$home/.claude-profiles/As" "$home/.claude-profiles/default" \
  "$shim_bin" "$foreign_bin" "$test_root/foreign"
bad_name=$(printf 'Bad\nclaude')
mkdir "$home/.claude-profiles/$bad_name"

ln -s /usr/bin/false "$foreign_bin/claude-work"
ln -s "$test_root/foreign/claude-as" "$shim_bin/claude-client"
ln -s "$PWD/shell/claude-as" "$shim_bin/claude-old"
ln -s "$PWD/claudes" "$shim_bin/claudes"

HOME="$home" PATH="/usr/bin:/bin" sh -c '
  set -- help
  . "$0" >/dev/null
  test "$(bin_dir)" = "$HOME/.local/bin"
' "$PWD/claudes"
test "$(cat "$home/.claude-profiles/.bin-dir")" = "$shim_bin"

HOME="$home" PATH="$foreign_bin:$shim_bin:/usr/bin:/bin" sh -c '
  set -- help
  . "$0" >/dev/null
  cmd_shims
' "$PWD/claudes"

HOME="$home" PATH="/usr/bin:/bin" zsh -c 'source shell/claudes.zsh; command -v claudes >/dev/null; command -v claude-expo >/dev/null'
HOME="$home" PATH="/usr/bin:/bin" bash -c 'source shell/claudes.bash; command -v claudes >/dev/null; command -v claude-expo >/dev/null'
if command -v fish >/dev/null; then
  fish_bin=$(command -v fish)
  HOME="$home" PATH="/usr/bin:/bin" "$fish_bin" -c 'source shell/claudes.fish; command -q claudes; and command -q claude-expo'
fi

HOME="$home" PATH="$foreign_bin:$shim_bin:/usr/bin:/bin" TMPDIR="$test_root/one" ./claudes shims >/dev/null &
first_sync=$!
HOME="$home" PATH="$foreign_bin:$shim_bin:/usr/bin:/bin" TMPDIR="$test_root/two" ./claudes shims >/dev/null &
second_sync=$!
wait $first_sync
wait $second_sync
test ! -e "$home/.claude-profiles/.shims.lock"

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
printf '%s\n' "$profiles" | grep -qx As
if printf '%s\n' "$profiles" | grep -Eq '^(as|default|Bad|bad|claude)$'; then
  echo "Invalid or reserved profile was discovered" >&2
  exit 1
fi

ln -s /usr/bin/true "$shim_bin/claude"
HOME="$home" PATH="$shim_bin:/usr/bin:/bin" "$shim_bin/claude-expo" --version

HOME="$home" PATH="$foreign_bin:$shim_bin:/usr/bin:/bin" sh -c '
  set -- help
  . "$0" >/dev/null
  cmd_shims --remove
' "$PWD/claudes"

test "$(readlink "$shim_bin/claude-client")" = "$test_root/foreign/claude-as"
test "$(readlink "$shim_bin/claude")" = /usr/bin/true

installed_line='export PATH="$HOME/.local/bin:$PATH"  # claudes-path'
custom_line='if true; then export PATH="$HOME/.local/bin:$PATH"  # claudes-path'
printf '%s\n%s\n' "$installed_line" "$custom_line" > "$test_root/rc"
grep -vxF -e "$installed_line" "$test_root/rc" > "$test_root/rc.cleaned"
test "$(cat "$test_root/rc.cleaned")" = "$custom_line"

fish_line='fish_add_path "$HOME/.local/bin"  # claudes-path'
custom_fish='if true; fish_add_path "$HOME/.local/bin"  # claudes-path'
printf '%s\n%s\n' "$fish_line" "$custom_fish" > "$test_root/fish"
grep -vxF -e "$fish_line" "$test_root/fish" > "$test_root/fish.cleaned"
test "$(cat "$test_root/fish.cleaned")" = "$custom_fish"

migrate_home="$test_root/migrate-home"
migrate_bin="$test_root/migrate-bin"
mkdir -p "$migrate_home/.claude-profiles" "$migrate_home/.local/bin" "$migrate_bin"
ln -s "$PWD/shell/claude-as" "$migrate_home/.local/bin/claude-stale"
HOME="$migrate_home" PATH="/usr/bin:/bin" sh -c '
  new_bin=$1
  set -- help
  . "$0" >/dev/null
  bin_dir() { echo "$new_bin"; }
  cmd_shims
' "$PWD/claudes" "$migrate_bin"
test ! -e "$migrate_home/.local/bin/claude-stale"
echo "All tests passed"
