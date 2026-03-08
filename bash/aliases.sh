# ~/.config/bash/aliases.sh
# shellcheck shell=bash

# File listing aliases (BSD ls)
alias ls='ls -AFGhl'
alias ll='ls'

# Common typo fixes
alias brwe='brew' # "I can't type" (as noted)

# Tool enhancements
alias batp='bat -p'
alias pbat='bat -p'
alias profile='source ~/.bash_profile'
alias ps='ps -efww'
alias rsync='rsync -avz'

# Python -> Python3
alias python='python3'

# Force pipx for global package installation (use \pip3 to bypass)
alias pip='echo "Use pipx instead: pipx install <package>" && false'
alias pip3='pipx'

# System commands
alias softboot="osascript -e 'tell app \"System Events\" to restart'"
# updates is now a function in functions.sh (orchestrates all package managers)

# Homebrew update alias (uses function from functions.sh)
alias brewup='_homebrew_update'

# Git shortcuts (optional - add your own)
alias gs='git status'
alias gl='git log --oneline'
alias gp='git pull'
alias gc='git commit -m'

# Exciting ways of launching Claude Code
alias claude='$HOME/.local/bin/claude-wrapper'
alias clauded="claude --dangerously-skip-permissions"
alias suclaude='$HOME/.local/bin/claude'
alias suclauded="suclaude --dangerously-skip-permissions"

# Add custom aliases below
# ------------------------
alias markdownlint="markdownlint --config ~/.markdownlint.json"
alias npx-markdownlint="npx markdownlint --config ~/.markdownlint.json"
alias diskspace='df -h /System/Volumes/Data'
