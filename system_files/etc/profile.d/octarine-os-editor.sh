# octarineOS: the default editor the user chose with `ujust user-setup --only editor`, from the managed file
# ~/.config/environment.d/50-editor.conf (KEY=value lines: EDITOR, VISUAL, SUDO_EDITOR). The systemd user manager reads that file for the
# services it starts, but a login session imports the LOGIN SHELL's environment into the user manager afterwards, and SSH and TTY logins never
# read environment.d, so login shells read it here too; this file sorts after nano-default-editor.sh, which only sets EDITOR when it is unset.
# Only those three keys and plain path characters are accepted (the file is parsed, never executed). A value in the user's own ~/.bashrc,
# ~/.zshrc or ~/.zshenv is read later and still wins. Disable for yourself: delete the managed file.
__octarine_f="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/50-editor.conf"
if [ -r "$__octarine_f" ]; then
	while IFS='=' read -r __octarine_k __octarine_v; do
		case "$__octarine_k" in EDITOR | VISUAL | SUDO_EDITOR) ;; *) continue ;; esac
		case "$__octarine_v" in '' | *[!A-Za-z0-9_./+-]*) continue ;; esac
		export "$__octarine_k=$__octarine_v"
	done <"$__octarine_f"
fi
unset __octarine_f __octarine_k __octarine_v
