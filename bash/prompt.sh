# ~/.config/bash/prompt.sh
#shellcheck shell=bash
# Shell prompt configuration using liquidprompt

# Check if liquidprompt is installed via Homebrew
if [[ -f /opt/homebrew/share/liquidprompt ]]; then
  # Source liquidprompt
  # Configuration is loaded from ~/.config/liquidpromptrc
  # Not source=/opt/homebrew/share/liquidprompt: that path exists only on a
  # Homebrew Mac, so shellcheck resolves it here and fails on the Linux CI
  # runner, where the file is absent.
  # shellcheck source=/dev/null
  source /opt/homebrew/share/liquidprompt
else
  # Fallback to simple prompt if liquidprompt not installed
  # Define color codes
  COLOR_RESET="\[\033[00m\]"
  COLOR_RED="\[\033[31m\]"

  # Capture exit status in PROMPT_COMMAND
  _prompt_exit_status() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
      PROMPT_EXIT_CODE="${exit_code}"
    else
      PROMPT_EXIT_CODE=""
    fi
  }

  # Add to PROMPT_COMMAND
  PROMPT_COMMAND+=("_prompt_exit_status")

  # Simple fallback prompt: exit code in red, prompt symbol
  export PS1="${COLOR_RED}\${PROMPT_EXIT_CODE:+[\${PROMPT_EXIT_CODE}] }${COLOR_RESET}\$ "
fi

# ~/Developer check: once now, then at each prompt. Appended after both
# branches above, so their $? readers run first. Added only once.
if [[ $- == *i* ]] && declare -F _developer_link_check >/dev/null; then
  _developer_link_check
  if [[ "${PROMPT_COMMAND[*]-}" != *_developer_link_check* ]]; then
    if ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 501)); then
      # bash 5.1+ runs every element of a PROMPT_COMMAND array.
      PROMPT_COMMAND+=(_developer_link_check)
    else
      # Older bash runs only element 0, which is also the plain string.
      PROMPT_COMMAND[0]="${PROMPT_COMMAND[0]:+${PROMPT_COMMAND[0]}; }_developer_link_check"
    fi
  fi
fi
