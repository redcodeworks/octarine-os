# vim: set ft=make :

# Wraps the base image's 00-default.just. build.sh keeps the base file as 00-default-base.just; this file imports it and
# defines the motd switch itself (a recipe of the importing file beats the imported one, whereas between two imported files the
# FIRST import wins). Everything else of the base file (enrollment, local override check, ...) comes through unchanged.
import "00-default-base.just"

# Toggle the motd (fastfetch summary or tips) in every shell
[group('Setup')]
toggle-motd:
    #!/usr/bin/env bash
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
