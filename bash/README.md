# Bash Configuration

A modular, organized bash configuration setup for macOS development environments.

## Overview

This repository contains my personal bash configuration files, designed with modularity and maintainability in mind. It separates various aspects of the bash environment into discrete, purpose-specific files for easier management and customization.

## Structure

- `.bash_profile`: Main entry point that sources other configuration files
- `main.sh`: Core configuration and settings
- `env.sh`: Environment variables and path configuration
- `aliases.sh`: Command shortcuts and aliases
- `functions.sh`: Custom bash functions
- `completion.sh`: Tab completion configuration
- `history.sh`: Command history settings
- `prompt.sh`: Command prompt customization
- `secrets.sh`: Private environment variables and tokens (not tracked in git)
- `backups/`: Directory containing configuration backups

## Features

- Modular design with separation of concerns
- Organized file structure for easy maintenance
- Custom prompt configuration
- Useful aliases and functions for development workflows
- Tab completion enhancements
- History optimization settings

## Installation

Files are maintained individually and can be sourced directly from your `.bash_profile` or `.bashrc`. Each module can be loaded independently based on your needs.

## Usage

After installation, the configuration will be loaded automatically when opening a new terminal. The modular design allows for easy customization:

- Add new aliases to `aliases.sh`
- Define custom functions in `functions.sh`
- Set environment variables in `env.sh`
- Store sensitive information in `secrets.sh` (which is git-ignored)

## Requirements

- macOS
- Bash 5 (installable via Homebrew)

## License

Personal use - see LICENSE file for details.
