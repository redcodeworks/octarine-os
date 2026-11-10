# octarineOS: `y` starts the yazi file manager (Homebrew) and, when you quit it, changes the shell to the folder you ended up
# in. Adapted from the yazi documentation. A function of your own named y in ~/.config/fish/functions wins.
function y --description 'yazi, then cd to the folder you quit in'
    if not command -q yazi
        echo "y: yazi is not installed (brew install yazi)" >&2
        return 127
    end
    set -l tmp (mktemp -t "yazi-cwd.XXXXXX")
    command yazi $argv --cwd-file="$tmp"
    if read -z cwd <"$tmp"; and test "$cwd" != "$PWD"; and test -d "$cwd"
        builtin cd -- "$cwd"
    end
    command rm -f -- "$tmp"
end
