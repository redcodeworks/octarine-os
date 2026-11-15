# vim: set ft=make :

# Wraps the base image's 00-default.just. build.sh keeps the base file as 00-default-base.just. The motd recipes live in
# /usr/share/octarine-os/just/motd.just, imported FIRST: between two imported files the first import wins, so they beat the base file's
# toggle-user-motd. Everything else of the base file (enrollment, local override check, ...) comes through unchanged.
import "/usr/share/octarine-os/just/motd.just"
import "00-default-base.just"
