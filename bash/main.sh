# ~/.config/bash/main.sh
#shellcheck shell=bash
# Main configuration file that sources all other modules

# Define base directory for configuration
export BASH_CONFIG_DIR="${HOME}/.config/bash"

# Load functions FIRST (needed by other modules)
if [[ -f "${BASH_CONFIG_DIR}/functions.sh" ]]; then
  source "${BASH_CONFIG_DIR}/functions.sh"
fi

# Load environment variables (depends on functions only)
# NOTE: env.sh runs 'brew shellenv' which modifies PATH. Must load BEFORE
# path.sh so that path.sh can apply the correct priority ordering on top.
if [[ -f "${BASH_CONFIG_DIR}/env.sh" ]]; then
  source "${BASH_CONFIG_DIR}/env.sh"
fi

# Load PATH configuration (depends on functions and env)
# Runs AFTER env.sh to override brew shellenv's PATH ordering
# with user-preferred priorities (~/.local/bin first)
if [[ -f "${BASH_CONFIG_DIR}/path.sh" ]]; then
  source "${BASH_CONFIG_DIR}/path.sh"
fi

# Load service management (depends on functions, env, and path)
if [[ -f "${BASH_CONFIG_DIR}/services.sh" ]]; then
  source "${BASH_CONFIG_DIR}/services.sh"
fi

# Load completion settings
if [[ -f "${BASH_CONFIG_DIR}/completion.sh" ]]; then
  source "${BASH_CONFIG_DIR}/completion.sh"
fi

# Load history settings
if [[ -f "${BASH_CONFIG_DIR}/history.sh" ]]; then
  source "${BASH_CONFIG_DIR}/history.sh"
fi

# Load aliases
if [[ -f "${BASH_CONFIG_DIR}/aliases.sh" ]]; then
  source "${BASH_CONFIG_DIR}/aliases.sh"
fi

# Load prompt (after functions for git integration)
if [[ -f "${BASH_CONFIG_DIR}/prompt.sh" ]]; then
  source "${BASH_CONFIG_DIR}/prompt.sh"
fi

# Additional custom configuration can be placed in this block
# -------------------------------------------------------------

# Enable case-insensitive globbing
shopt -s nocaseglob

# Correct simple directory spelling errors when using cd
shopt -s cdspell

# End of custom configuration

# Print startup message (comment out if not desired)
# echo "Bash configuration loaded from ${BASH_CONFIG_DIR}"
