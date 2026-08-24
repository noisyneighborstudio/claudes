# Claudes shell helper for zsh — tab completion only.
#
# The commands themselves (`claudes`, `claude-as`, `claude-<profile>`) are real
# executables on PATH, installed by `claudes shims`, so every app, editor and
# script gets them — not just shells that sourced this file.

_claudes_bin_file="$HOME/.claude-profiles/.bin-dir"
if [[ -r $_claudes_bin_file ]]; then
  IFS= read -r _claudes_bin_dir < "$_claudes_bin_file"
  case $_claudes_bin_dir in
    /opt/homebrew/bin|/usr/local/bin|"$HOME/.local/bin")
      [[ -d $_claudes_bin_dir && :$PATH: != *":$_claudes_bin_dir:"* ]] \
        && export PATH="$_claudes_bin_dir:$PATH"
      ;;
  esac
fi
unset _claudes_bin_file _claudes_bin_dir

_claudes_profiles() {
  local -a profiles
  profiles=(--next --best ${(f)"$(claudes profiles 2>/dev/null)"})
  _describe 'profile' profiles
}

_claudes_cli() {
  if (( CURRENT == 2 )); then
    _values 'command' list active use run best new delete repatch sessions \
      transfer desktop shims version help
  else
    _claudes_profiles
  fi
}

if (( $+functions[compdef] )); then
  compdef _claudes_profiles claude-as
  compdef _claudes_cli claudes
fi
