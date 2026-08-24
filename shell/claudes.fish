# Claudes shell helper for fish — tab completion only.
#
# The commands themselves (`claudes`, `claude-as`, `claude-<profile>`) are real
# executables on PATH, installed by `claudes shims`, so every app, editor and
# script gets them — not just shells that sourced this file.

complete -c claudes -f -n __fish_use_subcommand \
    -a 'list active use run new delete repatch sessions transfer desktop shims version help'
complete -c claudes -f -n 'not __fish_use_subcommand' \
    -a '(command ls $HOME/.claude-profiles 2>/dev/null)'
complete -c claude-as -f -a '(command ls $HOME/.claude-profiles 2>/dev/null)'
