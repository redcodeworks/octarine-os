# Default zshrc for new users (octarineOS). Stops the zsh-newuser-install wizard; edit freely.
# /etc/zprofile and /etc/zshrc (Fedora zsh package) already source /etc/profile.d, so PATH and brew are set.
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS
autoload -Uz compinit && compinit
autoload -Uz colors && colors
PROMPT='%F{green}%n@%m%f %F{blue}%~%f %# '
[[ -d "$HOME/.local/bin" ]] && path=("$HOME/.local/bin" $path)
