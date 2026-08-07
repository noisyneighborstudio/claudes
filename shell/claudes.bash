# Claudes shell helper for bash — sourced from ~/.bash_profile / ~/.bashrc
# (install.sh adds the line). Gives you:
#   claudes                     the cohesive CLI (also on PATH via install.sh)
#   claude-as <Profile> [args]  run Claude Code pinned to a profile
#   claude-<profile>            per-profile commands, e.g. Expo -> claude-expo
#
# macOS ships bash 3.2 (no command_not_found_handle), so claude-<profile>
# commands for profiles created after shell startup need a new shell.

_claudes_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

claudes() { "$_claudes_dir/claudes" "$@"; }
claude-as() { "$_claudes_dir/claudes" run "$@"; }

_claudes_define_commands() {
  local d name cmd
  for d in "$HOME/.claude-profiles"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    cmd="claude-$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    # never shadow a real command of the same name
    command -v "$cmd" >/dev/null 2>&1 && continue
    eval "$cmd() { claude-as \"$name\" \"\$@\"; }"
  done
}
_claudes_define_commands
unset -f _claudes_define_commands
