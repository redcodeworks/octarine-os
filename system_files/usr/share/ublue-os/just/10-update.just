# vim: set ft=make :

# Wraps the base image's 10-update.just. build.sh keeps the base file as 10-update-base.just. `update` and `toggle-updates` live in
# /usr/share/octarine-os/just/update.just, imported FIRST: between two imported files the first import wins, so they beat the base file's
# (a later file such as 60-custom.just could not override them either way). changelogs, update-firmware and the aliases (upgrade,
# changelog, auto-update) come from the base file unchanged.
import "/usr/share/octarine-os/just/update.just"
import "10-update-base.just"
