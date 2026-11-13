# Opt-in export of a few binaries from a distrobox to the host's ~/.local/bin (`distrobox-export --bin`). Sourced by
# `ujust hardware-setup` (rocm) and `ujust dev` (cuda); nothing is exported unless the user asks (--export), and
# --unexport removes only the wrappers of this box.
#
#   box_export <box> <dir> export|unexport <binary>...
#
# Per binary: the real path is resolved INSIDE the box with `command -v` in a login shell (so /etc/profile.d additions such as
# /usr/local/cuda/bin are seen); a missing binary is skipped with a message. A file at <dir>/<binary> is ours only when it is a
# distrobox wrapper of this box (it carries "# distrobox_binary" and "# name: <box>"); any other file is shown and left alone.
# Output lines: "exported", "already exported", "unexported", "not exported", "skipped: ..." per binary. Returns 1 when a
# distrobox command failed. DISTROBOX_CMD overrides the distrobox command (tests).

box_export() {
    local box=$1 dir=$2 action=$3 rc=0 b real wrapper
    shift 3
    local dbx=${DISTROBOX_CMD:-distrobox}
    for b in "$@"; do
        wrapper="$dir/$b"
        real=$("$dbx" enter --name "$box" --no-tty -- bash -lc "command -v $b" </dev/null 2>/dev/null | tail -n 1)
        case "$action" in
            export)
                if [ -z "$real" ]; then
                    echo "  skipped: $b is not installed in the box $box"
                    continue
                fi
                if [ -e "$wrapper" ]; then
                    if grep -q '^# distrobox_binary' "$wrapper" 2>/dev/null && grep -q "^# name: $box\$" "$wrapper" 2>/dev/null; then
                        echo "  already exported: $wrapper"
                    else
                        echo "  skipped: $wrapper exists and is not an export of the box $box (not ours); it looks like:"
                        head -n 5 "$wrapper" 2>/dev/null | sed 's/^/    /'
                    fi
                    continue
                fi
                mkdir -p "$dir"
                if "$dbx" enter --name "$box" --no-tty -- distrobox-export --bin "$real" --export-path "$dir" </dev/null; then
                    echo "  exported: $b ($real in $box) -> $wrapper"
                else
                    echo "  FAILED: could not export $b" >&2
                    rc=1
                fi
                ;;
            unexport)
                if [ ! -e "$wrapper" ]; then
                    echo "  not exported: $b"
                    continue
                fi
                if ! { grep -q '^# distrobox_binary' "$wrapper" 2>/dev/null && grep -q "^# name: $box\$" "$wrapper" 2>/dev/null; }; then
                    echo "  skipped: $wrapper is not an export of the box $box (not ours); left alone"
                    continue
                fi
                if [ -n "$real" ] && "$dbx" enter --name "$box" --no-tty -- distrobox-export --bin "$real" --export-path "$dir" --unexport </dev/null; then
                    echo "  unexported: $b"
                elif rm -f -- "$wrapper"; then
                    echo "  unexported: $b (wrapper file removed)"
                else
                    echo "  FAILED: could not remove $wrapper" >&2
                    rc=1
                fi
                ;;
        esac
    done
    return "$rc"
}
