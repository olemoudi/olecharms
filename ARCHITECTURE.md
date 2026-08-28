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

### 1. Constants & Globals (lines 5-65)
All paths, markers, intervals, and config variables. Key globals:
- `SCRIPT_DIR` — resolved repo root (symlink chain walked, with a loop guard)
- `SCRIPT_PATH` — the script's own resolved path; used for the `~/.local/bin` symlink and the self-update re-exec, so a renamed checkout still works
- `CONF_FILE` — path to `packages.conf`
- `BUNDLED_STAMP` — `.olecharms-bundled`, dropped into any directory populated from a bundled fallback
- `OLECHARMS_CONFIG_FILE` — XDG config at `~/.config/olecharms/config`
- `CURRENT_CONFIG_VERSION` — drives migration logic
- `SOURCE_LINE` — the `~/.vimrc` source line, with the path run through `_vim_escape()` (`:source` takes a bare path, so spaces and `\ | " % #` must be backslash-escaped)
- Marker strings for idempotent RC file management (see [File Markers](#file-markers))

This section also aborts immediately if `$HOME` is unset, missing, or not writable — every path olecharms writes lives under it.

### 2. Color / Output Helpers (lines 67-82)
`info()`, `warn()`, `error()` with color support. Colors auto-disable when stdout is not a terminal. `error()` increments `ERROR_COUNT`, which `main()` turns into a non-zero exit status.

### 3. Utility Functions (lines 84-768)
General-purpose helpers:
- `load_config()` — sources `packages.conf`
- `detect_os()` — sets `OS`, `PKG_MANAGER`, `FONT_DIR` (XDG-aware on Linux: `${XDG_DATA_HOME:-~/.local/share}/fonts`)
- `backup_file()` — timestamped backup before destructive operations
- `clone_or_pull()` — git clone with update, offline fallback, and non-destructive plugin replacement
- `check_command()` — `command -v` wrapper
- `resolve_link()` — portable symlink-chain resolution (no `readlink -f`, which is GNU-only)
- `write_file_contents()` — replaces a file's contents by writing through symlinks and swapping in via rename, preserving mode/ownership. Used everywhere instead of `mv tmpfile rcfile`, which would replace a symlinked dotfile with a regular file and reset its permissions
- `sed_inplace()` — portable `sed -i` (BSD/macOS sed requires an argument to `-i`)
- `rc_strip_block()` — removes an olecharms block (marker line, associated lines, and the blank separator) from an RC file
- `append_block()` — appends a block with exactly one blank separator line, and none at all when the file is new or empty
- `managed_rc_files()` / `rc_has_marker()` — the RC file list (defaulting to `~/.bashrc`) and a marker lookup
- `cron_replace_entry()` / `cron_quote_path()` — single point of crontab manipulation; paths are single-quoted and `%` escaped, since cron hands the line to `/bin/sh` and turns a bare `%` into a newline
- `ensure_scripts_dir()` — fails loudly if the checkout is read-only rather than generating half-written scripts
- `_file_hash()` — portable file hashing (md5sum → md5 → cksum)
- `find_downloads_dirs()` — locates `~/Downloads` (case-insensitive)
- `generate_hook_script()` — writes the shell-hook dispatcher
- `install_shell_hook()` / `remove_shell_hook()` — manages hook lines in RC files
- `generate_shell_loader()` — writes the `shell/*.sh` loader script
- `install_shell_commands()` / `remove_shell_commands()` — manages loader lines in RC files
- `install_binary()` — symlinks `olecharms` to `~/.local/bin` and adds it to PATH
- `install_editor_env()` — exports `EDITOR=vim` and `VISUAL=vim` in RC files
- `enable_downloads_cleanup()` / `disable_downloads_cleanup()` — manages the downloads cleaner
- `enable_paranoid_mode()` / `disable_paranoid_mode()` — manages paranoid-mode cleaner

### 4. Config Versioning (lines 770-975)
XDG-based configuration persistence:
- `config_read()` — parses key=value file into `OLECHARMS_CFG_*` variables (no `source`, safe)
- `config_get()` / `config_set()` — read/write individual keys
- `config_write_all()` — writes the complete config file
- `config_bootstrap()` — first-run detection of existing state
- `migrate_config()` — version-driven migration loop
- `config_ensure()` — bootstrap or read+migrate on every run
- `restore_scheduled_features()` — reconciles config → filesystem. `scripts/` is gitignored, so a fresh clone (or a moved install) has no generated cleanup scripts even when the config says a feature is on; this regenerates them and rewrites the crontab entries. Called by `install`/`update`, and with `force` by `fix_moved_install()`
- `fix_moved_install()` — repairs stale absolute paths after the checkout is moved

### 5. Core Operations (lines 977-1303)
The installation steps called by subcommands:
- `install_packages()` — apt/brew install with smart skip of already-installed packages
- `create_vim_dirs()` — creates `~/.vim/{autoload,bundle,bundle_disabled,undodir,swapfiles}`
- `install_pathogen()` — clones or falls back to bundled pathogen
- `install_plugins()` — clones/updates each plugin from `VIM_PLUGINS` array
- `install_vimrc()` — adds source line to `~/.vimrc` (idempotent, updates stale paths)
- `install_fonts()` — clones powerline fonts or uses bundled copies, rebuilds font cache
- `install_omz()` — installs Oh My Zsh, creates custom theme with random host color
- `run_post_commands()` — runs user-defined post-install commands

### 6. Subcommand Handlers (lines 1305-1935)
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

### 8. Main (lines 1937-1987)
Dispatches `$1` to the appropriate `cmd_*` handler, warns when running as root (everything would be installed into root's home; `OLECHARMS_ALLOW_ROOT=1` silences it), and exits non-zero if `ERROR_COUNT > 0`.

## Subcommand Flows

### `install` / `update`
`main()` calls `config_ensure` + `fix_moved_install` before dispatch (see [Auto-fix on move](#auto-fix-on-move)). Then both commands run the same sequence:
1. `load_config` — source `packages.conf`
2. `detect_os` — determine package manager and font directory
3. `_self_update` — pull the olecharms repo; re-exec if script changed
4. `install_packages` — install missing system packages (skip already-installed)
5. `create_vim_dirs` — ensure vim directory structure
6. `install_pathogen` — clone or use bundled pathogen
7. `install_plugins` — clone/update all vim plugins
8. `install_vimrc` — add/update source line in `~/.vimrc`
9. `install_fonts` — install powerline fonts
10. `install_omz` — set up Oh My Zsh with custom theme
11. `run_post_commands` — execute user-defined commands
12. `install_shell_commands` — generate loader, add to RC files
13. `install_binary` — symlink `olecharms` to `~/.local/bin`
14. `install_editor_env` — export `EDITOR=vim` and `VISUAL=vim` in RC files
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
- EDITOR environment variable

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

- **`olecharms-shell.sh`** — sources all `shell/*.sh` files; resolves its own directory at runtime to find `shell/`
- **`olecharms-hook.sh`** — shell-hook dispatcher; resolves its own directory at runtime to find sibling scripts and `.last-run/`
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

### Current config keys (v2)
- `downloads_cleanup_enabled` (true/false)
- `downloads_cleanup_dir` (path)
- `downloads_cleanup_method` (hook/cron)
- `downloads_cleanup_max_age_days` (integer)
- `paranoid_mode_enabled` (true/false)
- `paranoid_mode_method` (hook/cron)
- `install_dir` (path) — records the installation directory for stale-path detection after folder moves

## Design Decisions

### Idempotency
Every operation checks current state before acting. Running `install` or `update` multiple times produces the same result. Marker strings prevent duplicate entries in RC files.

### Userland install
Everything olecharms writes lives under `$HOME`: `~/.vim`, `~/.vimrc`, `~/.local/bin`, `${XDG_DATA_HOME:-~/.local/share}/fonts`, `~/.config/olecharms`, `~/.oh-my-zsh` (or `$ZSH`), the user's own crontab, and the checkout's `scripts/` directory. Nothing needs root except optional system package installation, which is delegated to `sudo`; `install_packages()` skips that step rather than blocking on a password prompt when there is no terminal, and skips it entirely on non-Debian Linux. `main()` warns when run as root, since that would set up root's environment rather than the user's.

### Path robustness
Absolute paths are unavoidable — RC files, the vimrc source line, the launcher symlink, and crontab entries all need them — so the script is built to survive them going stale or containing awkward characters:

- `SCRIPT_DIR`/`SCRIPT_PATH` are resolved from `BASH_SOURCE` through the symlink chain (guarded against loops), never assumed.
- The generated `scripts/olecharms-hook.sh` and `scripts/olecharms-shell.sh` locate themselves at source time, so only the RC line that sources them holds an absolute path.
- Paths written into other languages are escaped for their target: backslash-escaping for vim's `:source`, single-quoting plus `%` escaping for crontab command lines.
- `olevimrc.vim` uses `let &undodir = expand(...)` rather than `set undodir=...`, which would need escaping for a `$HOME` containing spaces.
- `fix_moved_install()` repairs every stale path in one pass (see below), and `status` prints the paths it depends on, flagging a broken launcher symlink.

### Preserving existing installations
When multiple copies of the repo exist (e.g., a primary install at `/home/user/olecharms` and a dev copy elsewhere), running `install`/`update` from one copy will not overwrite valid entries from another. The binary symlink function keeps an existing symlink that points at a different, still-present checkout. RC entries are rewritten only when they do not already point at the current checkout's generated script.

### Auto-fix on move
The config stores `install_dir` (the directory olecharms was last run from). On every operational command (`install`, `update`, `check`, `status`, `config`), `main()` calls `fix_moved_install()` which compares the stored path against the current `SCRIPT_DIR`. If they differ, the installation folder was moved. For mutating commands (`install`/`update`/`config`), all stale paths are repaired automatically: the vimrc source line, RC file references, the binary symlink, and — via `restore_scheduled_features force` — the generated cleanup scripts and their crontab entries, which would otherwise point at the old location. For read-only commands (`check`/`status`), a warning is printed directing the user to run `install` or `update`.

### Bundled fallbacks
All vim plugins, pathogen, and powerline fonts are bundled in `vimthings/`. If `git clone` fails (offline, firewalled), the bundled copy is used. This guarantees the environment works without network access.

A directory populated this way gets a `.olecharms-bundled` stamp file. On later runs `clone_or_pull()` sees the stamp and tries to upgrade the copy to a real clone, leaving it untouched if still offline — rather than treating it as a foreign directory, shunting it into `bundle_disabled/`, and re-copying it on every single run. `install_pathogen()` deliberately passes no fallback (pathogen is one file, copied straight out of `vimthings/autoload/`) and reclaims the oversized staging directory older versions left behind.

### Exit status
`error()` increments `ERROR_COUNT` and `main()` exits 1 when it is non-zero, so `olecharms update && ...` and cron jobs see failures. `cmd_install()` ends by `exec`ing a login zsh only when stdin and stdout are both terminals and the run was clean; otherwise it returns normally so the exit status survives.

### Smart package check
On Linux, `dpkg -s` checks each package individually before invoking `sudo apt-get`. If all packages are already installed, `sudo` is never called. This avoids unnecessary password prompts.

### Self-update with re-exec
`_self_update()` hashes `olecharms.sh` and `packages.conf` before and after `git pull`. If either changed, it `bash -n`-checks the new file and then `exec`s it so the rest of the install runs with updated code. The re-exec sets `OLECHARMS_RELAUNCHED=1`, which makes the new process skip self-update entirely — a mis-comparing hash can never loop.

### Dual scheduling (hook + cron)
Cleanup features can be scheduled via shell hooks (checked on every shell open, throttled by timestamp files) or via cron jobs. The hook approach works without a cron daemon and runs even on systems where cron isn't available.

### Non-destructive plugin management
When a plugin directory exists, isn't a git repo, and carries no `.olecharms-bundled` stamp — i.e. it is the user's own — it's moved to `~/.vim/bundle_disabled/` with a timestamp before re-cloning. Nothing is deleted.

### Editing RC files in place
RC files are rewritten with `write_file_contents()`, which follows symlinks and swaps the new content in by rename. Symlinked dotfiles (stow, chezmoi, a `~/dotfiles` checkout) keep pointing at the real file, permissions and ownership survive, and an interrupted run cannot leave a half-written `~/.bashrc` behind.

### Random host color theme
On first Oh My Zsh install, a random HSL color (bright, readable range) is generated via awk and embedded in the zsh theme. This gives each machine a unique prompt color for visual identification. The color is preserved across updates.

## File Markers

These marker strings are used for idempotent management of lines in shell RC files (`~/.bashrc`, `~/.bash_profile`, `~/.zshrc`):

| Marker | Purpose |
|---|---|
| `# olecharms managed hook - do not remove this line` | Shell hook for scheduled cleanups |
| `# olecharms shell commands - do not remove this line` | Shell command loader |
| `# olecharms PATH - do not remove this line` | `~/.local/bin` PATH entry |
| `# olecharms editor - do not remove this line` | EDITOR/VISUAL environment variable |
| `" olecharms managed config - do not remove this line` | Source line in `~/.vimrc` |

Blocks are added with `append_block()` (one blank separator line, none when the file is new) and removed with `rc_strip_block()`, which also absorbs that separator so repeated install/remove cycles do not accumulate blank lines.

## Testing

- **Syntax check:** `bash -n olecharms.sh`
- **Non-destructive:** `./olecharms.sh check` and `./olecharms.sh status`
- **Sandboxed end-to-end:** point `HOME` and `XDG_CONFIG_HOME` at a scratch directory and run `update` twice against a copy of the checkout; the second run must report no errors and leave the RC files byte-identical.
