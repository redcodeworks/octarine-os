# octarineOS: replaces the base image's file of the same name. The motd of bash and zsh login shells, from ONE script that also
# serves other shells (fastfetch when it is installed, else a tip). Interactive shells only: scripts, `ssh host cmd` and
# `bash -lc` never print it. The switch is the base flag ~/.config/no-show-user-motd (`ujust toggle-motd`), checked by the script.
case $- in
  *i*)
    # Prevent doublesourcing
    if [ -z "$USERMOTDSOURCED" ]; then
      USERMOTDSOURCED="Y"
      if [ -t 1 ] && [ -x /usr/libexec/octarine-os/motd ]; then
        /usr/libexec/octarine-os/motd
      fi
    fi
    ;;
esac
