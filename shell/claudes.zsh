# Claudes shell helper — source from ~/.zshrc:
#   source /path/to/claudes/shell/claudes.zsh
#
# claude-as <Profile> [args…]  -> Claude Code with that profile's config dir.
# Does NOT change global state; only the invoked session uses the profile.

claude-as() {
  local profile=$1
  if [[ -z ${profile:-} ]]; then
    echo "usage: claude-as <Profile> [claude args…]" >&2
    echo "profiles: $(ls ~/.claude-profiles 2>/dev/null | tr '\n' ' ')" >&2
    return 1
  fi
  shift
  CLAUDE_CONFIG_DIR="$HOME/.claude-profiles/$profile" claude "$@"
}

_claude_as_complete() {
  local -a profiles
  profiles=(${(f)"$(ls ~/.claude-profiles 2>/dev/null)"})
  _describe 'profile' profiles
}
(( $+functions[compdef] )) && compdef _claude_as_complete claude-as
