# octarineOS dx image: put ~/.cargo/bin (rustup's cargo, rustc and rust-analyzer proxies) at the END of PATH when it
# exists, so `ujust dev --only rust` needs no edit of any rc file. Idempotent. Disable for yourself by making
# ~/.cargo/bin not exist or by removing it from PATH in your own rc file.
if [ -d "$HOME/.cargo/bin" ]; then
    case ":${PATH}:" in
        *":$HOME/.cargo/bin:"*) ;;
        *) PATH="${PATH}:$HOME/.cargo/bin" ;;
    esac
    export PATH
fi
