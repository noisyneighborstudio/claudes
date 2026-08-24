# Claudes shell helper for fish — tab completion only.
#
# The commands themselves (`claudes`, `claude-as`, `claude-<profile>`) are real
# executables on PATH, installed by `claudes shims`, so every app, editor and
# script gets them — not just shells that sourced this file.

set -l _claudes_bin_file "$HOME/.claude-profiles/.bin-dir"
if test -r $_claudes_bin_file
    read -l _claudes_bin_dir < $_claudes_bin_file
    if contains -- $_claudes_bin_dir /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; and test -d $_claudes_bin_dir
        contains -- $_claudes_bin_dir $PATH; or set -gx PATH $_claudes_bin_dir $PATH
    end
end

complete -c claudes -f -n __fish_use_subcommand \
    -a 'list active use run best new delete repatch sessions transfer desktop shims version help'
complete -c claudes -f -n 'not __fish_use_subcommand' \
    -a '(claudes profiles 2>/dev/null) --next --best'
complete -c claude-as -f -a '(claudes profiles 2>/dev/null) --next --best'
