# octarineOS: load the rustup and cargo environment when rustup has been installed in the home directory (for
# example from the dev-toolbox, which shares it, or by `ujust dev --only rust` on the dx image); otherwise, when
# ~/.cargo/bin exists, put it at the end of PATH. Nothing happens when neither exists.
# Disable for yourself: create an empty file of the same name in ~/.config/fish/conf.d/.
if test -r "$HOME/.cargo/env.fish"
    source "$HOME/.cargo/env.fish"
else if test -d "$HOME/.cargo/bin"
    fish_add_path --global --append $HOME/.cargo/bin
end
