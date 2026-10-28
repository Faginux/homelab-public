eval "$(starship init zsh)"
eval "$(zoxide init zsh)"

export EDITOR="nvim"
export SUDO_EDITOR="$EDITOR"

HISTFILE=~/.history
HISTSIZE=10000
SAVEHIST=50000
setopt inc_append_history

# Key bindings and fuzzy completion of fzf
source <(fzf --zsh)

# Jump to a directory with zoxide+fzf and open/attach a tmux session with the
# same name. Useful to move fast between the folders of the docker stacks.
new_tmux () {
  session_dir=$(zoxide query --list | fzf)
  session_name=$(basename "$session_dir")
  if tmux has-session -t $session_name 2>/dev/null; then
    if [ -n "$TMUX" ]; then
      tmux switch-client -t "$session_name"
    else
      tmux attach -t "$session_name"
    fi
    notification="tmux attached to $session_name"
  else
    if [ -n "$TMUX" ]; then
      tmux new-session -d -c "$session_dir" -s "$session_name" && tmux switch-client -t "$session_name"
      notification="new tmux session INSIDE TMUX: $session_name"
    else
      tmux new-session -c "$session_dir" -s "$session_name"
      notification="new tmux session: $session_name"
    fi
  fi
  # notify-send exists only with an active desktop. It is not there on SSH/headless.
  # So the function skips it instead of breaking.
  # (the original of typecraft had a bug here. It had "[-s ...]" with no space after
  # the "[". This gave "command not found" instead of working.)
  if command -v notify-send &>/dev/null; then
    notify-send "$notification"
  fi
}
# lsd replaces ls with icons/colors (https://github.com/lsd-rs/lsd)
alias ls='lsd'

alias tm=new_tmux
