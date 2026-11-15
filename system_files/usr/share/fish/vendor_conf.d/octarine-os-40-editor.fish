# octarineOS: the default editor the user chose with `ujust user-setup --only editor`, from the managed file
# ~/.config/environment.d/50-editor.conf (KEY=value lines: EDITOR, VISUAL, SUDO_EDITOR); the same file /etc/profile.d/octarine-os-editor.sh reads
# for bash and zsh. Sorts after nano-default-editor.fish, which only sets EDITOR when it is unset. Only those three keys and plain path
# characters are accepted. Your own config.fish runs later and wins.
# Disable for yourself: create an empty file of the same name in ~/.config/fish/conf.d/ (or delete the managed file).
set -l conf (set -q XDG_CONFIG_HOME; and echo $XDG_CONFIG_HOME; or echo $HOME/.config)/environment.d/50-editor.conf
if test -r "$conf"
    for line in (cat "$conf")
        if string match -qr '^(EDITOR|VISUAL|SUDO_EDITOR)=[A-Za-z0-9_./+-]+$' -- $line
            set -l kv (string split -m 1 = -- $line)
            set -gx $kv[1] $kv[2]
        end
    end
end
