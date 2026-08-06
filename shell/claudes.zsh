# Claudes shell helper — source from ~/.zshrc (install.sh adds this for you):
#   source "/Applications/Claudes.app/Contents/Resources/claudes.zsh"
#
# Gives you:
#   claude-<profile>            per-profile commands, e.g. profile "Expo" -> `claude-expo`
#   claude-as <Profile> [args]  explicit form, tab-completable
#
# Nothing global is switched — only the invoked session uses the profile.

_claudes_root="$HOME/.claude-profiles"

# Map a lowercased suffix ("expo") back to the real profile dir name ("Expo").
_claudes_profile_dir() {
  local d
  for d in "$_claudes_root"/*(N/:t); do
    if [[ ${d:l} == ${1:l} ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

claude-as() {
  local profile=${1:-}
  if [[ -z $profile ]]; then
    echo "usage: claude-as <Profile> [claude args…]" >&2
    echo "profiles: $(ls "$_claudes_root" 2>/dev/null | tr '\n' ' ')" >&2
    return 1
  fi
  shift
  local dir
  if ! dir=$(_claudes_profile_dir "$profile"); then
    echo "claude-as: no profile named '$profile' (looked in $_claudes_root)" >&2
    return 1
  fi
  CLAUDE_CONFIG_DIR="$_claudes_root/$dir" claude "$@"
}

# Define claude-<profile> for every profile that exists at shell startup.
_claudes_define_commands() {
  local d cmd
  for d in "$_claudes_root"/*(N/:t); do
    cmd="claude-${d:l}"
    # never shadow a real command of the same name
    (( $+commands[$cmd] )) && continue
    functions[$cmd]="claude-as ${(q)d} \"\$@\""
  done
}
_claudes_define_commands

# Profiles created after this shell started still resolve, via the
# command-not-found hook. Chain any pre-existing handler (e.g. Homebrew's).
if (( $+functions[command_not_found_handler] )) && ! (( $+functions[_claudes_prev_cnf_handler] )); then
  functions[_claudes_prev_cnf_handler]=$functions[command_not_found_handler]
fi
command_not_found_handler() {
  local cmd=$1
  if [[ $cmd == claude-* && $cmd != claude-as ]]; then
    local dir
    if dir=$(_claudes_profile_dir "${cmd#claude-}"); then
      shift
      claude-as "$dir" "$@"
      return $?
    fi
  fi
  if (( $+functions[_claudes_prev_cnf_handler] )); then
    _claudes_prev_cnf_handler "$@"
    return $?
  fi
  echo "zsh: command not found: $cmd" >&2
  return 127
}

# Tab completion for claude-as profile names.
_claude_as_complete() {
  local -a profiles
  profiles=(${(f)"$(ls "$_claudes_root" 2>/dev/null)"})
  _describe 'profile' profiles
}
(( $+functions[compdef] )) && compdef _claude_as_complete claude-as
