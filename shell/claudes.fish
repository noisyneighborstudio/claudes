# Claudes shell helper for fish — sourced from ~/.config/fish/conf.d/claudes.fish
# (install.sh writes that stub). Gives you:
#   claudes                     the cohesive CLI (also on PATH via install.sh)
#   claude-as <Profile> [args]  run Claude Code pinned to a profile
#   claude-<profile>            per-profile commands, e.g. Expo -> claude-expo

set -g _claudes_dir (dirname (status filename))

function claudes
    "$_claudes_dir/claudes" $argv
end

function claude-as
    "$_claudes_dir/claudes" run $argv
end

for _claudes_d in $HOME/.claude-profiles/*/
    set -l _claudes_name (basename $_claudes_d)
    set -l _claudes_cmd claude-(string lower $_claudes_name)
    # never shadow a real command of the same name
    if not type -q $_claudes_cmd
        eval "function $_claudes_cmd; claude-as $_claudes_name \$argv; end"
    end
end
set -e _claudes_d

complete -c claudes -f -n __fish_use_subcommand \
    -a 'list active use run new delete repatch sessions transfer desktop version help'
complete -c claude-as -f -a '(command ls $HOME/.claude-profiles 2>/dev/null)'
