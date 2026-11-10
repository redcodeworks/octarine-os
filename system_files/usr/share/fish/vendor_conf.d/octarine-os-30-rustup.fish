# octarineOS: load the rustup and cargo environment when rustup has been installed in the home directory (for
# example from the dev-toolbox, which shares it); nothing happens otherwise.
# Disable for yourself: create an empty file of the same name in ~/.config/fish/conf.d/.
if test -r "$HOME/.cargo/env.fish"
    source "$HOME/.cargo/env.fish"
end
