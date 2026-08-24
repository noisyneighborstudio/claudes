# Claudes shell helper for bash — tab completion only.
#
# The commands themselves (`claudes`, `claude-as`, `claude-<profile>`) are real
# executables on PATH, installed by `claudes shims`, so every app, editor and
# script gets them — not just shells that sourced this file.

_claudes_bin_file="$HOME/.claude-profiles/.bin-dir"
if [ -r "$_claudes_bin_file" ]; then
  IFS= read -r _claudes_bin_dir < "$_claudes_bin_file"
  case $_claudes_bin_dir in
    /opt/homebrew/bin|/usr/local/bin|"$HOME/.local/bin")
      case :$PATH: in *:"$_claudes_bin_dir":*) ;; *) export PATH="$_claudes_bin_dir:$PATH" ;; esac
      ;;
  esac
fi
unset _claudes_bin_file _claudes_bin_dir

_claudes_complete() {
  local words="list active use run best new delete repatch sessions transfer desktop shims version help"
  [ "$COMP_CWORD" -gt 1 ] && words="$(claudes profiles 2>/dev/null) --next --best"
  COMPREPLY=($(compgen -W "$words" -- "${COMP_WORDS[COMP_CWORD]}"))
}
complete -F _claudes_complete claudes

_claude_as_complete() {
  COMPREPLY=($(compgen -W "$(claudes profiles 2>/dev/null) --next --best" -- "${COMP_WORDS[COMP_CWORD]}"))
}
complete -F _claude_as_complete claude-as
