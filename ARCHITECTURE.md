# Architecture

## Overview

**olecharms** is a single-script environment manager that sets up a consistent development environment (vim, zsh, fonts, shell utilities) across Linux and macOS machines. It follows a **clone → install → config → update** lifecycle:

1. Clone the repo to any machine
2. Run `./olecharms.sh install` for idempotent first-time setup
3. Optionally run `olecharms config` to enable features like downloads cleanup or paranoid mode
4. Run `olecharms update` at any time to pull changes and re-apply everything

## Project Structure

```
olecharms/
├── olecharms.sh              # The single main script (all logic lives here)
├── packages.conf              # User-editable config: packages, plugins, fonts, post-install commands
├── shell/                     # Shell commands auto-sourced into bash/zsh sessions
│   ├── mkcd.sh                #   mkdir + cd in one step
│   ├── mksh.sh                #   create a new shell script with boilerplate
│   ├── serveit.sh             #   start a static file server (python/npx/ruby/php)
│   ├── each.sh                #   run a command for each line of stdin
│   └── switchsshkey.sh        #   manage and switch between named SSH key pairs
├── vimthings/                 # Bundled vim configuration and fallback copies
│   ├── olevimrc.vim           #   Main vimrc (sourced from ~/.vimrc)
│   ├── configure.sh           #   Legacy standalone vim configurator (unused by olecharms.sh)
│   ├── autoload/
│   │   └── pathogen.vim       #   Bundled fallback copy of pathogen
│   ├── bundle/                #   Bundled fallback copies of all vim plugins
│   │   ├── airline/
│   │   ├── ctrlp/
│   │   ├── easymotion/
│   │   ├── fugitive/
│   │   ├── nerdtree/
│   │   ├── supertab/
│   │   ├── surround/
│   │   ├── syntastic/
│   │   └── vim-go/
│   └── fonts/
│       └── powerline/         #   Bundled powerline fonts (30 families)
├── scripts/                   # Generated at runtime (not committed)
│   ├── olecharms-hook.sh      #   Shell profile hook for scheduled cleanups
│   ├── olecharms-shell.sh     #   Loader that sources shell/*.sh files
│   ├── cleanup-downloads.sh   #   Generated downloads cleanup script
│   ├── paranoid-cleanup.sh    #   Generated paranoid-mode cleanup script
│   └── .last-run/             #   Timestamps for hook-based scheduling
├── ARCHITECTURE.md            # This file
└── CLAUDE.md                  # Project instructions for Claude Code
```

## Script Sections

`olecharms.sh` is organized into 9 logical sections, delimited by comment banners:

### 1. Constants & Globals (lines 5-40)
All paths, markers, intervals, and config variables. Key globals:
- `SCRIPT_DIR` — resolved repo root
- `CONF_FILE` — path to `packages.conf`
- `OLECHARMS_CONFIG_FILE` — XDG config at `~/.config/olecharms/config`
- `CURRENT_CONFIG_VERSION` — drives migration logic
- Marker strings for idempotent RC file management (see [File Markers](#file-markers))

### 2. Color / Output Helpers (lines 42-57)
`info()`, `warn()`, `error()` with color support. Colors auto-disable when stdout is not a terminal.

### 3. Utility Functions (lines 59-498)
General-purpose helpers:
- `load_config()` — sources `packages.conf`
- `detect_os()` — sets `OS`, `PKG_MANAGER`, `FONT_DIR`
- `backup_file()` — timestamped backup before destructive operations
- `clone_or_pull()` — git clone with update, offline fallback, and non-destructive plugin replacement
- `check_command()` — `command -v` wrapper
- `_file_hash()` — portable file hashing (md5sum → md5 → cksum)
- `find_downloads_dirs()` — locates `~/Downloads` (case-insensitive)
- `generate_hook_script()` — writes the shell-hook dispatcher
- `install_shell_hook()` / `remove_shell_hook()` — manages hook lines in RC files
- `generate_shell_loader()` — writes the `shell/*.sh` loader script
- `install_shell_commands()` / `remove_shell_commands()` — manages loader lines in RC files
- `install_binary()` — symlinks `olecharms` to `~/.local/bin` and adds it to PATH
- `enable_downloads_cleanup()` / `disable_downloads_cleanup()` — manages the downloads cleaner
- `enable_paranoid_mode()` / `disable_paranoid_mode()` — manages paranoid-mode cleaner

### 4. Config Versioning (lines 500-624)
XDG-based configuration persistence:
- `config_read()` — parses key=value file into `OLECHARMS_CFG_*` variables (no `source`, safe)
- `config_get()` / `config_set()` — read/write individual keys
- `config_write_all()` — writes the complete config file
- `config_bootstrap()` — first-run detection of existing state
- `migrate_config()` — version-driven migration loop
- `config_ensure()` — bootstrap or read+migrate on every run

### 5. Core Operations (lines 626-907)
The installation steps called by subcommands:
- `install_packages()` — apt/brew install with smart skip of already-installed packages
- `create_vim_dirs()` — creates `~/.vim/{autoload,bundle,bundle_disabled,undodir,swapfiles}`
- `install_pathogen()` — clones or falls back to bundled pathogen
- `install_plugins()` — clones/updates each plugin from `VIM_PLUGINS` array
- `install_vimrc()` — adds source line to `~/.vimrc` (idempotent, updates stale paths)
- `install_fonts()` — clones powerline fonts or uses bundled copies, rebuilds font cache
- `install_omz()` — installs Oh My Zsh, creates custom theme with random host color
- `run_post_commands()` — runs user-defined post-install commands

### 6. Subcommand Handlers (lines 909-1485)
- `_self_update()` — pulls the olecharms repo itself, re-execs if the script changed
- `cmd_install()` — full idempotent setup sequence
- `cmd_update()` — same as install (alias)
- `cmd_check()` — reports installed/missing status for all components
- `cmd_status()` — shows versions and commit hashes for all installed components
- `cmd_config()` — interactive menu for toggling features
- `cmd_help()` — usage text with dynamically listed shell commands

### 7. Config Submenus (within Subcommand Handlers)
- `config_downloads_cleanup()` — interactive enable/disable of downloads auto-cleanup
- `config_paranoid_mode()` — interactive enable/disable of paranoid mode

### 8. Main (lines 1487-1509)
Dispatches `$1` to the appropriate `cmd_*` handler.

## Subcommand Flows

### `install` / `update`
Both run the exact same sequence:
1. `load_config` — source `packages.conf`
2. `detect_os` — determine package manager and font directory
3. `_self_update` — pull the olecharms repo; re-exec if script changed
4. `config_ensure` — bootstrap or migrate XDG config file
5. `install_packages` — install missing system packages (skip already-installed)
6. `create_vim_dirs` — ensure vim directory structure
7. `install_pathogen` — clone or use bundled pathogen
8. `install_plugins` — clone/update all vim plugins
9. `install_vimrc` — add/update source line in `~/.vimrc`
10. `install_fonts` — install powerline fonts
11. `install_omz` — set up Oh My Zsh with custom theme
12. `run_post_commands` — execute user-defined commands
13. `install_shell_commands` — generate loader, add to RC files
14. `install_binary` — symlink `olecharms` to `~/.local/bin`
15. On install only: launch `zsh -l` so the user sees the result

### `check`
Reads `packages.conf`, then reports presence/absence of:
- System commands (git, vim, curl, etc.)
- Vim directories
- Pathogen
- Each plugin (git repo vs bundled copy vs missing)
- Vimrc source line
- Font families
- Shell commands and loader

### `status`
Shows OS, repo path, config version, repo commit, installed plugin versions (commit + date), pathogen status, and available shell commands.

### `config`
Interactive menu loop offering:
1. **Downloads auto-cleanup** — toggle on/off, choose folder, choose hook vs cron scheduling
2. **Paranoid mode** — toggle on/off, choose hook vs cron; auto-enables downloads cleanup if not already on

## packages.conf

Sourced by `olecharms.sh` to define what gets installed:

| Variable | Purpose |
|---|---|
| `APT_PACKAGES` | System packages for Debian/Ubuntu |
| `BREW_PACKAGES` | System packages for macOS |
| `VIM_PLUGINS` | Array of `"name\|git_url"` pairs |
| `PATHOGEN_REPO` | Git URL for vim-pathogen |
| `POWERLINE_FONTS_REPO` | Git URL for powerline fonts |
| `FONT_FAMILIES` | Which font families to install from the fonts repo |
| `POST_INSTALL_COMMANDS` | Optional commands to run after install/update |

## vimthings/

Bundled vim configuration:

- **`olevimrc.vim`** — the main vim config file, sourced from `~/.vimrc`. Configures pathogen loading, editor settings, key mappings, and plugin options.
- **`autoload/pathogen.vim`** — bundled fallback copy of pathogen, used when cloning fails (offline installs).
- **`bundle/`** — bundled fallback copies of all 9 vim plugins. Used when `git clone` fails. Each is a full copy of the plugin repository.
- **`fonts/powerline/`** — bundled copy of the powerline fonts repository (30 families). `DejaVuSansMono` is installed by default.

## shell/

Shell commands that are auto-sourced into the user's shell session via a generated loader script. Each file defines a function named after the file:

| Command | Description |
|---|---|
| `mkcd` | Create a directory and cd into it |
| `mksh` | Create a new shell script with strict-mode boilerplate, make it executable, open in editor |
| `serveit` | Start a static file server using whichever runtime is available (python3 → python → npx → ruby → php) |
| `each` | Run a command for every line of stdin, replacing `{}` with each line |
| `switchsshkey` | Manage named SSH key pairs: `add`, `list`, or switch by name |

To add a new shell command, create a file in `shell/` following the format:
```bash
# commandname — short description
commandname() {
    # implementation
}
```

The first line (`# name — description`) is parsed by `cmd_help` to display available commands.

## scripts/ (Generated at Runtime)

These files are generated by `olecharms.sh` and are not committed to the repo:

- **`olecharms-shell.sh`** — sources all `shell/*.sh` files; added to RC files via `SHELL_MARKER`
- **`olecharms-hook.sh`** — shell-hook dispatcher that runs cleanup scripts at configured intervals
- **`cleanup-downloads.sh`** — deletes files older than 30 days from the configured downloads folder
- **`paranoid-cleanup.sh`** — purges shell history and vim swap/undo files
- **`.last-run/`** — directory of timestamp files used by the hook to enforce intervals

## Config Versioning

Persistent settings are stored in `~/.config/olecharms/config` (XDG-compliant). The system uses a version-driven migration mechanism.

### Config file format
Simple `key=value` pairs. Parsed safely without `source` — only alphanumeric keys and underscores are allowed.

### Migration mechanism
- `CURRENT_CONFIG_VERSION` in `olecharms.sh` defines the target version
- `config_ensure()` runs on every subcommand: bootstraps if no config exists, otherwise reads and migrates
- `migrate_config()` loops from the file's `CONFIG_VERSION` up to `CURRENT_CONFIG_VERSION`, calling `migrate_config_N_to_M()` functions if they exist
- To add a new config flag: increment `CURRENT_CONFIG_VERSION`, add a `migrate_config_N_to_M()` function that calls `config_set` for the new key, and update `config_write_all()` to include it

### Current config keys (v1)
- `downloads_cleanup_enabled` (true/false)
- `downloads_cleanup_dir` (path)
- `downloads_cleanup_method` (hook/cron)
- `downloads_cleanup_max_age_days` (integer)
- `paranoid_mode_enabled` (true/false)
- `paranoid_mode_method` (hook/cron)

## Design Decisions

### Idempotency
Every operation checks current state before acting. Running `install` or `update` multiple times produces the same result. Marker strings prevent duplicate entries in RC files.

### Preserving existing installations
When multiple copies of the repo exist (e.g., a primary install at `/home/user/olecharms` and a dev copy elsewhere), running `install`/`update` from one copy will not overwrite valid entries from another. The shell hook, shell commands, and binary symlink functions extract the path from existing RC entries or symlinks and skip the update if the target file still exists on disk. Only stale entries (pointing to paths that no longer exist) are replaced.

### Bundled fallbacks
All vim plugins, pathogen, and powerline fonts are bundled in `vimthings/`. If `git clone` fails (offline, firewalled), the bundled copy is used. This guarantees the environment works without network access.

### Smart package check
On Linux, `dpkg -s` checks each package individually before invoking `sudo apt-get`. If all packages are already installed, `sudo` is never called. This avoids unnecessary password prompts.

### Self-update with re-exec
`_self_update()` hashes `olecharms.sh` and `packages.conf` before and after `git pull`. If either changed, it `exec`s the new version so the rest of the install runs with updated code.

### Dual scheduling (hook + cron)
Cleanup features can be scheduled via shell hooks (checked on every shell open, throttled by timestamp files) or via cron jobs. The hook approach works without a cron daemon and runs even on systems where cron isn't available.

### Non-destructive plugin management
When a plugin directory exists but isn't a git repo (e.g., from a bundled fallback install), it's moved to `~/.vim/bundle_disabled/` with a timestamp before re-cloning. Nothing is deleted.

### Random host color theme
On first Oh My Zsh install, a random HSL color (bright, readable range) is generated via awk and embedded in the zsh theme. This gives each machine a unique prompt color for visual identification. The color is preserved across updates.

## File Markers

These marker strings are used for idempotent management of lines in shell RC files (`~/.bashrc`, `~/.bash_profile`, `~/.zshrc`):

| Marker | Purpose |
|---|---|
| `# olecharms managed hook - do not remove this line` | Shell hook for scheduled cleanups |
| `# olecharms shell commands - do not remove this line` | Shell command loader |
| `# olecharms PATH - do not remove this line` | `~/.local/bin` PATH entry |
| `" olecharms managed config - do not remove this line` | Source line in `~/.vimrc` |
