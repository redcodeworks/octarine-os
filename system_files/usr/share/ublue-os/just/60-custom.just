# vim: set ft=make :

# Add a user (default: you) to the gamemode, input and libvirt groups
add-user-groups user=`id -un`:
    #!/usr/bin/env bash
    set -euo pipefail
    user="{{ user }}"
    # gamemode and input only exist in /usr/lib/group, so copy their lines into
    # /etc/group first or usermod -aG would not see them.
    for g in gamemode input libvirt; do
        if ! getent group "$g" >/dev/null; then
            echo "Skipping $g: no such group on this system"
            continue
        fi
        sudo sh -c "grep -q '^$g:' /etc/group || grep '^$g:' /usr/lib/group >> /etc/group"
        if id -nG "$user" | tr ' ' '\n' | grep -qx "$g"; then
            echo "$user is already in $g"
        else
            sudo usermod -aG "$g" "$user"
            echo "Added $user to $g"
        fi
    done
    echo "Log out and back in for the new groups to apply."
