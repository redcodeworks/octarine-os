# vim: set ft=make :

# The image's motd recipes. Imported by /usr/share/ublue-os/just/00-default.just (ujust) and by /usr/share/octarine-os/justfile.

# Toggle the motd (fastfetch summary or tips) in every shell
[group('Setup')]
toggle-motd:
    #!/usr/bin/env bash
    [ -r /usr/share/octarine-os/lib/emoji.sh ] && . /usr/share/octarine-os/lib/emoji.sh
    set -uo pipefail
    flag="${HOME}/.config/no-show-user-motd"
    if [ -e "${flag}" ]; then
        rm -f -- "${flag}"
        echo "motd is now on (bash and zsh login shells; fish through a fish_greeting function that calls /usr/libexec/octarine-os/motd)"
    else
        mkdir -p -- "${HOME}/.config" && : > "${flag}"
        echo "motd is now off (switch it back on with: ujust toggle-motd)"
    fi

# Toggle the motd, same as toggle-motd (the name of the base image's recipe)
[group('Setup')]
toggle-user-motd: toggle-motd
