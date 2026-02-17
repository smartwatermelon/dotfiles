# Vim Configuration

Personal vim configuration optimized for Bash scripting, SSH sessions, and general text editing.

## Overview

This directory contains vim configuration with sensible defaults, Bash-specific settings, and useful keybindings for shell script development.

**Location**: `~/.config/vim/`
**Config file**: `vimrc`
**Runtime data**: `vim-data/` (color schemes, plugins)

## Structure

```
vim/
├── vimrc                          # Main vim configuration
├── vim-data/                      # Runtime data directory
│   ├── colors/gruvbox.vim        # Gruvbox color scheme
│   └── autoload/plug.vim         # Vim-Plug package manager
└── README.md                      # This file
```

## Key Features

### Color Scheme

**Gruvbox** - Retro groove color scheme with warm, muted colors

- **Contrast**: Medium dark background
- **Improved strings**: Better syntax highlighting
- **256-color support**: Works in all terminals

### Editor Behavior

**Search**:

- Incremental search (`incsearch`) - Shows matches as you type
- Highlight matches (`hlsearch`) - Highlights all search results
- Smart case (`smartcase`) - Case-insensitive unless uppercase used
- Ignore case (`ignorecase`) - Default case-insensitive search

**Indentation**:

- **Default**: 4 spaces, no tabs (`expandtab`, `tabstop=4`, `shiftwidth=4`)
- **Bash scripts**: 2 spaces (auto-detected via `FileType sh`)
- Auto-indent and smart indent enabled

**Interface**:

- Line numbers (`number`)
- Cursor line highlight (`cursorline`)
- Status line always visible (`laststatus=2`)
- Command-line completion (`wildmenu`)
- Scrolloff (keeps 3 lines visible above/below cursor)

### SSH Optimization

Settings for better performance over SSH:

- **Fast terminal** (`ttyfast`) - Assumes fast connection
- **Mouse support** (`mouse=a`, `ttymouse=xterm2`) - Works in SSH sessions
- **Timeout reduction** (`ttimeoutlen=50`) - Faster escape key response

### Bash-Specific Features

**Syntax highlighting**:

- `g:is_bash = 1` - Treats all shell files as Bash (not POSIX sh)
- `g:sh_no_error = 1` - Disables some overzealous syntax error highlighting

**Indentation**:

- Automatic 2-space indentation for `.sh` files
- Matches shfmt formatting standards

**Keybindings** (Bash development):

- **F5**: Execute current script (`bash %`)
- **F6**: Check syntax without executing (`bash -n %`)
- **F7**: Run shellcheck on current file

### Quality of Life

**Trailing whitespace**:

- Highlighted in red (catches unwanted spaces)
- Auto-highlights on buffer load and leaving insert mode

**Editing**:

- System clipboard integration (`clipboard=unnamed`)
- Backspace works over indents, line breaks, and insertion start
- Matching bracket highlighting (`showmatch`)

**Status line**:
Custom status line showing:

- Full file path
- File modified/readonly flags
- File format (unix/dos/mac)
- File type
- Cursor position (line, column, percentage)
- Current time and date

## Usage

### Opening Files

```bash
vim script.sh            # Open file
vim +10 script.sh        # Open at line 10
vim +/pattern script.sh  # Open at first match
```

### Bash Development Workflow

1. Write your script
2. Press **F6** to check syntax
3. Fix any errors
4. Press **F7** to run shellcheck
5. Press **F5** to execute and test

### Common Commands

**Editing**:

- `i` - Insert mode
- `Esc` - Normal mode
- `v` - Visual mode (select text)
- `dd` - Delete line
- `yy` - Yank (copy) line
- `p` - Paste

**Search & Replace**:

- `/pattern` - Search forward
- `?pattern` - Search backward
- `n` - Next match
- `N` - Previous match
- `:%s/old/new/g` - Replace all in file
- `:s/old/new/g` - Replace all in line

**Navigation**:

- `gg` - Go to first line
- `G` - Go to last line
- `10G` - Go to line 10
- `w` - Next word
- `b` - Previous word
- `0` - Start of line
- `$` - End of line

## Configuration Details

### Color Scheme Setup

Gruvbox is loaded from `~/.config/vim/vim-data/colors/gruvbox.vim`. The `runtimepath` is extended to include this directory, allowing vim to find the color scheme.

### Trailing Whitespace Detection

Whitespace is highlighted using vim's match patterns:

```vim
match ExtraWhitespace /\s\+$/
```

This runs on:

- Buffer load (`BufWinEnter`)
- Leaving insert mode (`InsertLeave`)

### FileType Detection

Bash-specific settings trigger automatically for files with:

- `.sh` extension
- Shebang: `#!/bin/bash` or `#!/usr/bin/env bash`

## Customization

### Changing Indentation

Edit default tab settings in `vimrc`:

```vim
set tabstop=4      " Number of spaces for a tab
set shiftwidth=4   " Number of spaces for auto-indent
```

For specific file types:

```vim
autocmd FileType python setlocal tabstop=4 shiftwidth=4
autocmd FileType javascript setlocal tabstop=2 shiftwidth=2
```

### Adding Keybindings

Example custom keybinding:

```vim
nnoremap <F8> :!python3 %<CR>   " Execute Python script
nnoremap <F9> :!node %<CR>      " Execute Node.js script
```

### Changing Color Scheme

Replace Gruvbox with another scheme:

```vim
colorscheme desert
colorscheme molokai
colorscheme solarized
```

### Plugin Management

This config uses **Vim-Plug** (included in `vim-data/autoload/plug.vim`). To add plugins, edit `vimrc`:

```vim
call plug#begin('~/.config/vim/vim-data/plugged')
Plug 'tpope/vim-fugitive'        " Git integration
Plug 'dense-analysis/ale'        " Asynchronous linting
call plug#end()
```

Then run `:PlugInstall` in vim.

## Integration with Other Tools

### ShellCheck

F7 keybinding assumes shellcheck is installed:

```bash
brew install shellcheck
```

### Bash Syntax Checking

F6 uses bash's built-in syntax checker (`bash -n`), which is always available.

### System Clipboard

Clipboard integration (`clipboard=unnamed`) works with:

- **macOS**: pbcopy/pbpaste (built-in)
- **Linux**: xclip or xsel (install separately)

## Troubleshooting

### Colors look wrong

Ensure your terminal supports 256 colors:

```bash
echo $TERM  # Should be xterm-256color or similar
```

If not, add to your `.bash_profile`:

```bash
export TERM=xterm-256color
```

### Mouse doesn't work over SSH

Enable mouse support in your terminal:

- **iTerm2**: Preferences > Profiles > Terminal > "Report mouse clicks & drags"
- **Terminal.app**: Works by default on macOS

### Keybindings don't work

Check if keys are being captured by your terminal:

- **F5-F12**: Some terminals intercept these for system functions
- **Alt/Option**: May be used for special characters on macOS

### Syntax highlighting issues

For Bash scripts, ensure file is detected as Bash:

```vim
:set filetype?    " Check current filetype
:set filetype=sh  " Force Bash syntax
```

## References

- [Vim Documentation](https://www.vim.org/docs.php)
- [Gruvbox Color Scheme](https://github.com/morhetz/gruvbox)
- [Vim-Plug Plugin Manager](https://github.com/junegunn/vim-plug)
- [Learn Vim](https://www.openvim.com/)
- [Vim Cheat Sheet](https://vim.rtorr.com/)
