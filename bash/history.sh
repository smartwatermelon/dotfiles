# ~/.config/bash/history.sh
#shellcheck shell=bash
# History configuration (from previous .profile)

# set history file location
HISTDIR="${HOME}/.local/state/bash/"
mkdir -p "${HISTDIR}"
HISTFILE="${HISTDIR}/history"

# Append to the history file, don't overwrite it
shopt -s histappend

# Save multi-line commands as one command
shopt -s cmdhist

# Record each line as it gets issued
PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }"'history -a'

# Huge history. Doesn't appear to slow things down, so why not?
HISTSIZE=500000
HISTFILESIZE=100000

# Avoid duplicate entries
HISTCONTROL="erasedups:ignoreboth"

# Don't record some commands
export HISTIGNORE="&:[ ]*:exit:ls:bg:fg:history:clear"

# Useful timestamp format
HISTTIMEFORMAT='%F %T '
