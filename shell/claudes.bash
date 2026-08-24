# Claudes shell helper for bash — tab completion only.
#
# The commands themselves (`claudes`, `claude-as`, `claude-<profile>`) are real
# executables on PATH, installed by `claudes shims`, so every app, editor and
# script gets them — not just shells that sourced this file.

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
