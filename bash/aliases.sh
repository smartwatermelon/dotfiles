# ~/.config/bash/aliases.sh
# shellcheck shell=bash

# File listing aliases (BSD ls)
alias ls='ls -AFGhl'
alias ll='ls'

# Common typo fixes
alias brwe='brew' # "I can't type" (as noted)

# Tool enhancements
alias batp='bat -p'
alias epoch='date +%s'
alias pbat='bat -p'
alias profile='source ${HOME}/.bash_profile'
alias ps='ps -efww'
alias rgall='rg -uuu'
alias rsync='rsync -avz'

# Force pipx for global package installation (use \pip3 to bypass)
alias pip='echo "Use pipx instead: pipx install <package>" && false'
alias pip3='pipx'

# System commands
alias softboot="osascript -e 'tell app \"System Events\" to restart'"

# Homebrew update alias (uses function from functions.sh)
alias brewup='_homebrew_update'

# Git shortcuts (optional - add your own)
alias gs='git status'
alias gl='git log --oneline'
alias gp='git pull'
alias gc='git commit -m'
alias mla='merge-lock auth'
alias my-prs='my_prs'       # open PRs across my orgs (functions.sh)
alias my-issues='my_issues' # open issues across my orgs (functions.sh)

# Exciting ways of launching Claude Code
if [[ -f "${HOME}/.local/bin/claude-wrapper" ]]; then
  alias claude='${HOME}/.local/bin/claude-wrapper'
  alias megaclaude="BUDGET_SESSION_TOKENS=50000000 BUDGET_SUBAGENT_TOKENS=12000000 claude"
  alias megaclauded="BUDGET_SESSION_TOKENS=50000000 BUDGET_SUBAGENT_TOKENS=12000000 clauded"
elif [[ -f "${HOME}/.local/bin/claude-wrapper-lite" ]]; then
  # Only adds machine-settings.json, for hosts without the full wrapper.
  # It runs caffeinate itself.
  alias claude='${HOME}/.local/bin/claude-wrapper-lite'
  alias megaclaude="BUDGET_SESSION_TOKENS=50000000 BUDGET_SUBAGENT_TOKENS=12000000 claude"
  alias megaclauded="BUDGET_SESSION_TOKENS=50000000 BUDGET_SUBAGENT_TOKENS=12000000 clauded"
else
  alias claude='/usr/bin/caffeinate -i ${HOME}/.local/bin/claude'
fi

# clauded (#435): a = plain claude; else, or after CLAUDED_TIMEOUT (10s),
# YOLO. No TTY: YOLO, no prompt.
unalias clauded 2>/dev/null
# Must follow the if block, so the claude alias expands in the body.
_clauded_stdin_is_tty() { [[ -t 0 ]]; }
clauded() {
  local timeout="${CLAUDED_TIMEOUT:-10}" key="" rc=0
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=10
  if ! _clauded_stdin_is_tty; then
    claude --dangerously-skip-permissions "$@"
    return
  fi
  printf "Try plain 'claude' instead.\n" >&2
  printf '[a]uto / [y]olo (clauded), yolo in %ss: ' "${timeout}" >&2
  read -r -s -n 1 -t "${timeout}" key || rc=$?
  if ((rc > 128)); then
    printf '\n(timed out)\n' >&2
  else
    printf '%s\n' "${key}" >&2
  fi
  if [[ "${key}" == [aA] ]]; then
    # Plain claude: auto mode only where machine settings set it.
    printf 'Starting plain claude.\n' >&2
    claude "$@"
  else
    claude --dangerously-skip-permissions "$@"
  fi
}
alias suclaude='${HOME}/.local/bin/claude'
alias suclauded="suclaude --dangerously-skip-permissions"

# Add custom aliases below
# ------------------------
alias markdownlint='markdownlint --config ${HOME}/.markdownlint.json'
alias npx-markdownlint='npx markdownlint --config ${HOME}/.markdownlint.json'
alias diskspace='df -h /System/Volumes/Data'
alias dotall='dotfiles && dotclaude'
