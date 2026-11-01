# Architecture

## Overview

**olecharms** is a single-script environment manager that sets up a consistent development environment (vim, zsh, fonts, shell utilities) across Linux, macOS and WSL. From WSL it also manages the Windows side: Windows' own gVim gets the same config and plugins as the terminal vim, and the Powerline fonts are installed for the Windows user. It follows a **clone → install → config → update** lifecycle:

1. Clone the repo to any machine — or let `bootstrap.sh` do it: `bash -c "$(curl -fsSL https://raw.githubusercontent.com/olemoudi/olecharms/master/bootstrap.sh)"` gets git if missing, clones (or updates an existing checkout) and runs `install`
2. Run `./olecharms.sh install` for idempotent first-time setup; it offers the settings shared from your other machines
3. Optionally run `olecharms config` to enable features like downloads cleanup or paranoid mode, and to share them with every machine
4. Run `olecharms update` at any time to pull changes and re-apply everything
5. Run `olecharms doctor` when something looks off (`--fix` repairs what it can, asking before anything outside olecharms' own files)

## Project Structure

```
olecharms/
├── olecharms.sh              # The single main script (all logic lives here)
├── bootstrap.sh               # One-command setup of a new machine (git, clone, install)
├── packages.conf              # Shared config: packages, plugins, fonts, post-install commands
├── global-aliases.sh          # Global aliases (created by `alias add --global` / `aliaslast`), loaded on every machine
│                              #   (per-machine additions: ~/.config/olecharms/packages.local.conf)
├── shared-config              # Settings shared by every machine (created by `config` → Shared settings)
├── bin/
│   └── olecharms-clip         # System clipboard from a terminal (POSIX sh): copy / paste / backend
├── shell/                     # Shell commands auto-sourced into bash/zsh sessions
│   ├── clipboard.sh           #   copy / paste on top of bin/olecharms-clip
│   ├── mkcd.sh                #   mkdir + cd in one step
│   ├── mksh.sh                #   create a new shell script with boilerplate
│   ├── serveit.sh             #   start a static file server (python/npx/ruby/php)
│   ├── each.sh                #   run a command for each line of stdin
│   └── switchsshkey.sh        #   manage and switch between named SSH key pairs
├── vimthings/                 # Bundled vim configuration and fallback copies
│   ├── olevimrc.vim           #   Main vimrc (sourced from ~/.vimrc, and from Windows' _vimrc on WSL)
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
│   ├── cleanup-downloads.sh   #   Launcher for `olecharms cleanup --scheduled`
│   ├── paranoid-cleanup.sh    #   Generated paranoid-mode cleanup script
│   └── .last-run/             #   Timestamps for hook-based scheduling
├── .gitattributes             # Forces LF for *.sh/*.conf/*.vim (CRLF breaks bash and vim)
└── ARCHITECTURE.md            # This file
```

## Script Sections

`olecharms.sh` is organized into logical sections, delimited by comment banners:

### 1. Constants & Globals (lines 5-118)
All paths, markers, intervals, and config variables. Key globals:
- `SCRIPT_DIR` — resolved repo root (symlink chain walked, with a loop guard)
- `SCRIPT_PATH` — the script's own resolved path; used for the `~/.local/bin` symlink and the self-update re-exec, so a renamed checkout still works
- `CONF_FILE` — path to `packages.conf`
- `BUNDLED_STAMP` — `.olecharms-bundled`, dropped into any directory populated from a bundled fallback
- `OLECHARMS_CONFIG_FILE` — XDG config at `~/.config/olecharms/config`
- `CURRENT_CONFIG_VERSION` — drives migration logic
- `LOCAL_CONF_FILE` — `~/.config/olecharms/packages.local.conf`, per-machine additions sourced after `packages.conf`
- `OLECHARMS_STATE_DIR` / `CLEANUP_LOG` — `${XDG_STATE_HOME:-~/.local/state}/olecharms`, holding the cleanup log and lock
- `GENERATOR_VERSION` / `GENERATOR_STAMP` — stamped into every generated script so `doctor` can tell stale ones apart
- `WIN_MANAGED_STAMP` / `WIN_VIMRC_LINE` — mark the plugin copies olecharms owns in Windows' `vimfiles\bundle`, and the line it puts in Windows' `_vimrc`
- `SOURCE_LINE` — the `~/.vimrc` source line, with the path run through `_vim_escape()` (`:source` takes a bare path, so spaces and `\ | " % #` must be backslash-escaped)
- Marker strings for idempotent RC file management (see [File Markers](#file-markers))

This section also aborts immediately if `$HOME` is unset, missing, or not writable — every path olecharms writes lives under it.

### 2. Color / Output Helpers (lines 120-137)
`info()`, `warn()`, `error()` with color support. Colors auto-disable when stdout is not a terminal. `error()` increments `ERROR_COUNT`, which `main()` turns into a non-zero exit status.

### 3. Utility Functions (lines 139-1371)
General-purpose helpers:
- `load_config()` — sources `packages.conf`, then `packages.local.conf` when present, with `OLECHARMS_OS` / `OLECHARMS_WSL` set so the local file can branch per machine
- `ensure_local_conf_template()` — creates a commented `packages.local.conf` on install/update (never touches an existing one)
- `detect_os()` — idempotent; sets `OS`, `PKG_MANAGER`, `FONT_DIR` (XDG-aware on Linux: `${XDG_DATA_HOME:-~/.local/share}/fonts`) and `IS_WSL`
- `backup_file()` — timestamped backup before destructive operations; dereferences symlinks, so a stow/chezmoi dotfile is really backed up
- `clone_or_pull()` — git clone with update, offline fallback, and non-destructive plugin replacement
- `check_command()` — `command -v` wrapper
- `resolve_link()` — portable symlink-chain resolution (no `readlink -f`, which is GNU-only)
- `write_file_contents()` — replaces a file's contents by writing through symlinks and swapping in via rename, preserving mode/ownership. Used everywhere instead of `mv tmpfile rcfile`, which would replace a symlinked dotfile with a regular file and reset its permissions
- `sed_inplace()` — portable `sed -i` (BSD/macOS sed requires an argument to `-i`)
- `rc_strip_block()` — removes an olecharms block (marker line, associated lines, and the blank separator) from an RC file
- `append_block()` — appends a block with exactly one blank separator line, and none at all when the file is new or empty
- `managed_rc_files()` — the RC file list (defaulting to `~/.bashrc`)
- `cron_replace_entry()` / `cron_quote_path()` — single point of crontab manipulation; paths are single-quoted and `%` escaped, since cron hands the line to `/bin/sh` and turns a bare `%` into a newline. Reads through `cron_read()`, which fails instead of returning an empty table when `crontab -l` errors for any reason other than "no crontab" — so a failed read can never wipe the user's other jobs — and leaves the crontab untouched when the result would be identical
- `cron_daemon_running()` / `warn_if_no_cron_daemon()` — warn when cron mode is chosen but no daemon runs (the default on WSL and in containers); always true on macOS, where launchd starts cron on demand
- `_git_net()` — `git` for third-party repos with `GIT_TERMINAL_PROMPT=0` (a renamed or deleted GitHub repo answers with an auth prompt) and a low-speed timeout, so one bad plugin cannot hang the update
- `ensure_scripts_dir()` — fails loudly if the checkout is read-only rather than generating half-written scripts
- `_file_hash()` — portable file hashing (md5sum → md5 → cksum)
- `find_downloads_dirs()` — locates `~/Downloads` (case-insensitive) and, on WSL, the Windows user's real Downloads folder (asked from Windows, so redirected or OneDrive folders are found); folders reaching the same place are listed once
- `commit_generated()` — moves a generated script into place with an atomic same-directory rename, so a shell starting mid-update never sources half a file
- `generate_hook_script()` — writes the shell-hook dispatcher
- `install_shell_hook()` / `remove_shell_hook()` — manages hook lines in RC files
- `sync_shell_hook()` / `hook_needed()` — the single place that reconciles the hook with the enabled features: regenerates it and ensures the RC lines when any feature is hook-scheduled, removes both otherwise. Every enable/disable path ends here, so switching a feature between hook and cron cannot leave it running from both
- `generate_shell_loader()` — writes the loader: sources `shell/*.sh` with alias expansion off (zsh `no_aliases`/`null_glob` inside a function, bash `expand_aliases` toggled), because shells expand aliases when a function is *defined* and the loader runs after oh-my-zsh — common-aliases' `cp='cp -i'` would otherwise be baked into every function, and an empty `shell/` would abort zsh startup with "no matches found"; activates autojump for the running shell (manual `~/.autojump`, Debian/Ubuntu or Homebrew install, unless `j` already exists — packages install autojump but nothing activates it), loads the aliases and defines the `olecharms()` wrapper function
- `install_shell_commands()` / `remove_shell_commands()` — manages loader lines in RC files. Installed even when `shell/` is empty, since the loader also carries the aliases and the `olecharms` wrapper function. If `.zshrc` sources the loader before `oh-my-zsh.sh` (`loader_before_omz()`), the block is moved to the end: oh-my-zsh defines its aliases when sourced, so it would override the user's
- `install_binary()` — symlinks `olecharms` to `~/.local/bin` and adds it to PATH
- `install_editor_env()` — exports `EDITOR=vim` and `VISUAL=vim` in RC files
- `enable_downloads_cleanup()` / `disable_downloads_cleanup()` — manages the downloads cleaner: writes the `scripts/cleanup-downloads.sh` launcher, the cron entry or hook, and the config keys
- `enable_paranoid_mode()` / `disable_paranoid_mode()` — manages paranoid-mode cleaner. On WSL with the Windows integration on (`paranoid_covers_windows()`), the generated script also purges the Windows gVim's `_viminfo`, `vimfiles/swapfiles` and `vimfiles/undodir`; the Windows path is resolved at generation time (PowerShell is too slow for every run) and the script is regenerated when the integration is toggled. Disabling leaves the downloads cleanup on and says so

### 3b. Aliases (lines 1373-1914)
User-defined shell aliases, in two files with the same format:
- per machine: `~/.config/olecharms/aliases` (next to the config, not in the gitignored `scripts/`, so they survive a fresh clone and a moved checkout)
- global: `global-aliases.sh` in the repo, committed and pushed by olecharms itself, so every machine gets it on its next update. The loader sources it first, so a per-machine alias of the same name wins.

Storage functions take the file as an optional last argument (default: per machine):
- `alias_name_valid()` / `alias_quote()` — name validation and single-quote escaping
- `alias_list_raw()` / `alias_get()` / `alias_count()` — parse a file back into `name<TAB>command` records
- `alias_write_all()` — rewrites a file from records on stdin
- `alias_set()` / `alias_unset()` — add-or-replace and remove, kept sorted
- `confirm_default_yes()` / `confirm_default_no()` — prompts that still honour a piped answer

`aliaslast`:
- `aliaslast_history()` — recent distinct single-line commands, oldest first. Taken from the snapshot the shell wrapper writes (`_olecharms_snapshot`: zsh `$history` as NUL-separated exact entries — `fc -l` prints a newline and a typed `\n` alike — or bash `fc -l`); without the wrapper, from the history file. The in-memory history matters: the shell may keep no history file (`unset HISTFILE`)
- `pick_item()` — arrow-key picker over `PICK_ITEMS`, cursor on the newest entry; falls back to a numbered prompt without a terminal. Restores the cursor on Ctrl-C
- `alias_conflicts()` — what a name already means: an olecharms alias (either file), and from the snapshot the shell's aliases (oh-my-zsh, rc files), functions and builtins; or a command on `PATH`

Global aliases (`global_alias_*`):
- `global_alias_upstream()` — the branch the checkout tracks; without one there is nowhere to publish and nothing is offered
- `global_alias_publish()` — pull, check push access, apply the change to `global-aliases.sh` only, commit that file alone and push (one retry after a rebase if someone pushed in between). Refuses to push unrelated local commits without asking
- `global_push_access()` — dry-run push of the remote's own commit back (a fast-forward, so only access can fail). If git's own credentials fail and the GitHub CLI is signed in, it borrows gh as credential helper for this run (`GLOBAL_PUSH_OPTS`; the git config is not changed). While it still fails, prints how to grant access (`global_push_help()`: this machine's SSH public keys, GitHub key / deploy-key pages, or an SSH push URL for HTTPS remotes) and waits for the user to retry or keep the alias local
- `alias_save_global()` — publishes and drops a per-machine alias of the same name, which would shadow it here
- `confirm_default_yes()` — `[Y/n]` prompt where Enter and EOF mean yes, but a piped answer is still honoured

Both files hold `alias name='command'` lines and nothing else. The loader remembers the names it loaded (`_olecharms_loaded_aliases`) and unaliases them before re-sourcing, so a deleted alias also disappears from the running shell. Files written by older versions ended with an `_olecharms_unload_aliases()` function instead; one line naming every alias would make any two edits of `global-aliases.sh` on different machines conflict.

### 3b2. Shared settings (lines 1916-2174)
`SHARED_KEYS`, `shared_differences()`, `shared_publish()`, `shared_apply()`, `shared_offer_after_pull()`, `config_shared_settings()` — see [Shared settings](#shared-settings).

### 3c. Downloads Cleanup Engine (lines 2176-2746)
One implementation behind `olecharms cleanup`, its `--dry-run`, the config-menu preview, `doctor` and the scheduled runs:
- `cleanup_real_dir()` — resolves the folder and refuses anything that is, or leads to, `$HOME` or `/`
- `cleanup_collect()` — NUL-separated list of files older than N days; `desktop.ini` (Windows) and `.localized` (macOS) always stay, since they give the folder its localized name ("Descargas")
- `cleanup_trash_backend()` / `cleanup_effective_backend()` — picks what happens to old files from `downloads_cleanup_action`: `auto` uses the Windows Recycle Bin (a Windows drive seen from WSL) or the macOS Trash and deletes otherwise — a desktop trash on a headless box would just grow; `trash` also accepts `gio` / `trash-put`; `delete` deletes
- `cleanup_apply()` — acts on the list, then counts whatever is gone as done, so a backend failing halfway is reported truthfully; one log line per file
- `cleanup_run()` — one pass: `mkdir` lock (a lock older than a day is taken over), collect, apply, remove empty dirs, log, trim the log to `CLEANUP_LOG_MAX_LINES`. Scheduled runs are silent and leave their trace in the log
- `cleanup_print_preview()` / `cleanup_show_log()` — what the menu, `cleanup` and `--log` print

### 3d. Windows (WSL) Integration (lines 2748-3241)
Everything that reaches into Windows goes through PowerShell:
- `win_ps_run()` — runs a PowerShell script as `-EncodedCommand` (UTF-16LE base64): nothing to quote through the interop layer, no execution-policy prompt, no temp `.ps1`. Output comes back as UTF-8; stdin is `/dev/null`, because `powershell.exe` otherwise swallows the user's pending input. The scripts (`PS_WIN_ENV`, `PS_FONTS`, `PS_RECYCLE`) are defined at top level with `read -d ''` — a heredoc inside `$(...)` is misparsed by the bash 3.2 that macOS ships
- `win_powershell()` — finds `powershell.exe`, falling back to its standard path (cron's `PATH` has no Windows dirs)
- `win_env_load()` — one PowerShell start per run (~1–2 s) for `USERPROFILE`, `LOCALAPPDATA`, `%HOME%`, the real Downloads folder, Program Files, gVim's registry key and the registered fonts; `WIN_VIM_HOME` follows Vim's rule (`%HOME%` if set, else `%USERPROFILE%`)
- `win_find_gvim()` — installer registry key, `Program Files*/Vim/vimNN` (newest first), Scoop, `%PATH%`
- `install_windows_fonts()` — copies missing `FONT_FAMILIES` files into `%LOCALAPPDATA%\Microsoft\Windows\Fonts`, registers them under HKCU and loads them with `AddFontResource` (no admin; same as Explorer's "Install for me"). Windows Terminal and gVim draw with Windows fonts, so the Linux-side copies do nothing for them
- `install_windows_vim()` — mirrors pathogen, `olevimrc.vim` (to `vimfiles\olecharms\`) and every plugin (`win_sync_plugins()`: rsync without `.git`, stamped with `.olecharms-managed`; copies of plugins no longer listed are removed, folders olecharms did not create are never touched), creates `undodir`/`swapfiles`, and adds the managed block to the user `_vimrc` (`win_install_vimrc()`, keeping the file's own line endings; a new file gets CRLF). A user `_vimrc` takes precedence over the system `$VIM\_vimrc`
- `sync_windows_side()` — the install/update step; skipped when `windows_integration=off` or Windows is unreachable
- `win_recycle()` — the Recycle Bin backend: maps paths with one `wslpath` call for the root, then `SHFileOperation` with `ALLOWUNDO|SILENT|NOCONFIRMATION|NOERRORUI`, so no dialog ever opens from a background run

### 4. Config Versioning (lines 3243-3483)
XDG-based configuration persistence:
- `config_read()` — parses key=value file into `OLECHARMS_CFG_*` variables (no `source`, safe)
- `config_get()` / `config_set()` — read/write individual keys
- `config_write_all()` — writes the complete config file
- `config_bootstrap()` — first-run detection of existing state
- `migrate_config()` — version-driven migration loop
- `config_ensure()` — bootstrap or read+migrate on every run
- `restore_scheduled_features()` — reconciles config → filesystem. `scripts/` is gitignored, so a fresh clone (or a moved install) has no generated cleanup scripts even when the config says a feature is on. It regenerates them on every run — not only when missing — because that is how fixes to their templates reach existing installs; the crontab and config are only rewritten when something differs. A downloads folder that is not reachable (an unmounted `/mnt/c`, an external drive) is skipped with a warning, never disabled in the config. Ends with `sync_shell_hook()`. Called by `install`/`update` and by `fix_moved_install()`
- `fix_moved_install()` — repairs stale absolute paths after the checkout is moved

### 5. Core Operations (lines 3485-3940)
The installation steps called by subcommands:
- `install_packages()` — apt/brew install with smart skip of already-installed packages
- `create_vim_dirs()` — creates `~/.vim/{autoload,bundle,bundle_disabled,undodir,swapfiles}`
- `install_pathogen()` — clones or falls back to bundled pathogen
- `install_plugins()` — clones/updates each plugin from `VIM_PLUGINS` array; `plugin_follow_default_branch()` switches a plugin whose upstream renamed its default branch; `plugins_retire_unlisted()` moves plugins olecharms cloned (recorded in `~/.local/state/olecharms/managed-plugins`) that packages.conf no longer lists to `bundle_disabled` — never one put there by hand, and not when most of them would go at once
- `install_vimrc()` — adds source line to `~/.vimrc` (idempotent, updates stale paths)
- `install_fonts()` — clones powerline fonts or uses bundled copies, rebuilds font cache
- `install_omz()` — installs Oh My Zsh, creates custom theme with random host color. An existing `~/.zshrc` is kept (`KEEP_ZSHRC=yes`; the installer would otherwise move it aside and replace a dotfiles symlink with its template) and `omz_add_to_zshrc()` prepends the oh-my-zsh lines to it
- `install_zsh_extras()` — with `zsh_extras=on` (default), clones or fast-forwards zsh-autosuggestions and zsh-syntax-highlighting into `~/.local/share/olecharms/zsh-plugins/` (`zsh_extra_fetch()` never deletes a folder it did not create); fzf itself comes from the package lists
- `run_post_commands()` — runs user-defined post-install commands

### 6. Subcommand Handlers (lines 3942-6301)
Includes the zsh extras (`zsh_extra_fetch()`, `install_zsh_extras()`, `config_zsh_extras()`, lines 4001-4135) and the doctor (from line 4137).
- `_self_update()` — pulls the olecharms repo itself, re-execs (through `bash`, so a lost exec bit cannot abort it) if the script changed. Warns when `packages.conf` has local edits, and when `--autostash` had to park them in `git stash` because they clashed with the update
- `run_setup_steps()` — the step sequence shared by install and update
- `cmd_install()` — full idempotent setup sequence
- `cmd_update()` — same steps; tells the user to `exec zsh` when RC files, the loader or aliases changed (`shell_config_snapshot()`)
- `cmd_doctor()` — see [Doctor](#doctor); `check` is an alias
- `cmd_cleanup()` — `olecharms cleanup [--dry-run|--log|--yes]`, and `--scheduled` for the launcher
- `cmd_windows()` — WSL only: `sync` (default) or `status`
- `cmd_status()` — shows versions and commit hashes for all installed components
- `cmd_config()` — interactive menu for toggling features (plus the Windows integration switch on WSL)
- `cmd_alias()` — dispatches `add` / `list` / `delete`; `alias_add()`, `alias_delete()` and `alias_show_list()` do the work
- `cmd_aliaslast()` — pick a recent command, name it (checked with `alias_conflicts()`), save it on this machine or globally
- `cmd_help()` — usage text with dynamically listed shell commands

### 7. Doctor and Config Submenus (within Subcommand Handlers)
- `doctor_check_*()` — one function per area; `doc_ok/doc_warn/doc_fail` count results, `doc_why` says in plain words why a warning matters, `doc_hint` prints the fix, `doc_offer` registers a repair that `doctor --fix` asks about (`doctor_apply_offers()`)
- `config_downloads_cleanup()` — when enabling: folder, schedule, trash-or-delete, then a preview of what the first run would remove and a confirmation. When enabled: preview, change action, change max age, history, disable
- `choose_downloads_dir()` / `choose_cleanup_action()` — prompts shared with paranoid mode; they run inside `$(...)`, so their messages go to stderr
- `config_paranoid_mode()` — interactive enable/disable of paranoid mode. Enabling keeps downloads at most `PARANOID_MAX_AGE_DAYS` (15) old: it enables the cleanup, or lowers a longer max age, after a preview of what that removes and a confirmation

### 7b. Secrets (lines 6303-6605)
`secret_scan()`, `rc_toplevel_lines()`, `secret_import()`, `secret_set()` / `secret_rm()` / `secret_list()`, `doctor_check_secrets()`, `cmd_secret()` — see [Secrets](#secrets).

### 8. Main (lines 6607-6679)
Calls `detect_os`, dispatches `$1` to the appropriate `cmd_*` handler, warns when running as root (everything would be installed into root's home; `OLECHARMS_ALLOW_ROOT=1` silences it), and exits non-zero if `ERROR_COUNT > 0`.

## Subcommand Flows

### `install` / `update`
`main()` calls `detect_os`, `config_ensure` + `fix_moved_install` before dispatch (see [Auto-fix on move](#auto-fix-on-move)). Then both commands run the same sequence:
1. `load_config` — source `packages.conf`, then `packages.local.conf`
2. `_self_update` — pull the olecharms repo; re-exec if script changed
3. `ensure_local_conf_template` — create the commented per-machine file if missing
4. `install_packages` — install missing system packages (skip already-installed)
5. `create_vim_dirs` — ensure vim directory structure
6. `install_pathogen` — clone or use bundled pathogen
7. `install_plugins` — clone/update all vim plugins
8. `install_vimrc` — add/update source line in `~/.vimrc`
9. `install_fonts` — install powerline fonts
10. `install_omz` — set up Oh My Zsh with custom theme
10b. `install_zsh_extras` — zsh plugins for suggestions and syntax colours (see [Zsh extras](#zsh-extras))
11. `run_post_commands` — execute user-defined commands
12. `install_shell_commands` — generate loader, add to RC files
13. `install_binary` — symlink `olecharms` to `~/.local/bin`
14. `install_editor_env` — export `EDITOR=vim` and `VISUAL=vim` in RC files
15. `restore_scheduled_features` — regenerate cleanup launchers, cron entries and the hook
16. `sync_windows_side` — WSL only: Windows fonts, then Windows gVim config and plugins
17. `shared_offer_after_pull` — when `shared-config` changed since this machine last went through it (always, on a new machine) and differs here: with a terminal, `shared_apply` asks about each setting; otherwise it says so
18. On install only, with a terminal and a clean run: show the result in zsh without nesting shells. Through the `olecharms()` shell function the calling shell itself is replaced (`exec zsh -l`); from a zsh started any other way olecharms only prints the command; from another shell it `exec`s zsh as before. On update, it says when the shell configuration changed

### `doctor` (alias `check`)
Checks every area olecharms touches and prints `✓` / `~` (warning) / `✗` (problem), for warnings a plain-words line on why it matters (`doc_why`), and a `→` hint: system commands; the checkout (merge/rebase in progress, conflict markers, branch without upstream, commits ahead/behind as of the last fetch, stash entries, days since the last successful pull, git password helpers that no longer exist — `git_effective_helpers()` works out the ones git really runs for the olecharms remote, so a broken generic helper overridden for GitHub by `gh auth setup-git` is reported as harmless for olecharms); launcher symlink, exec bit and PATH; shell loader (generator stamp), its line in each RC file (and whether `.zshrc` loads it before oh-my-zsh), EDITOR, aliases, autojump activation, the clipboard backend, secrets (file mode, plain-text secrets in RC files and in old RC backups), login shell; vim dirs, pathogen, plugins, the `~/.vimrc` line (and an old full copy of olevimrc in it, which loads the config twice: `vimrc_own_lines()` compares it with every version of olevimrc.vim in git plus the pre-repo one, and lists any line that is the user's own); fonts; Oh My Zsh and theme; fzf and the zsh plugins; downloads cleanup (folder, backend, schedule, cron daemon, last run, what is due); paranoid mode; config version, moved checkout, local edits to `packages.conf`, differences from the shared settings; and on WSL the Windows side (fonts, Windows Terminal font — read with python3 for the WSL profiles —, gVim, `_vimrc`, `olevimrc.vim` copy, plugins). Exits 1 when there is a problem.

`doctor --fix` first re-runs the local, offline steps (`run_local_steps()`: vim dirs, `~/.vimrc`, loader and RC lines, launcher, EDITOR, scheduled features, the Windows side), then checks. Repairs that change something outside olecharms' own files are registered by the checks with `doc_offer "question" command args...` and `doctor_apply_offers()` asks about each one (`[y/N]`, only at a terminal): remove a broken git password helper (`git_helper_remove()`, from the file `--show-origin` names, backup kept) or let git use the GitHub CLI login (`gh auth setup-git`); remove an old olevimrc copy from `~/.vimrc` (backup kept); set the Powerline font in Windows Terminal's `settings.json` (`wt_set_font()`, backup kept); `chsh` to zsh; go through differing shared settings; move plain-text secrets into the secrets file; make the secrets file or old RC backups holding secrets private. Checks whose hint is `olecharms update` / `olecharms sync` make it offer that run at the end. After any repair it checks again and prints the new totals.

Every run records its outcome in `~/.local/state/olecharms/doctor.problems` (removed when clean). With `daily_doctor=on` (the default; toggle in `config`) the shell hook runs `doctor --quiet` once a day in the background through `scripts/doctor-daily.sh`, and while that file exists every new shell prints one line about it — a machine you rarely use tells you when it drifted.

### `sync`
The light update: `checkout_pull()` (new global aliases, shared settings, code), the list of new commits, then `exec`s the pulled script for `run_local_steps()` and `shared_offer_after_pull()`. No packages, no plugins. The wrapper reloads aliases afterwards, so a global alias added on another machine is usable at once.

### `secret`
`olecharms secret set NAME` (asks twice without echo; or one line on stdin), `list` (names only), `rm NAME`, `import`. See [Secrets](#secrets).

### `cleanup`
- `olecharms cleanup` — shows folder, rule, action and how many files (and how much space) match, asks, then runs on exactly those files. Without a terminal it refuses unless `--yes`. A mass removal (see [Deletion safety](#deletion-safety)) asks you to type the file count instead, and `--yes` alone refuses it: it takes `--yes --force`.
- `olecharms cleanup --dry-run` — the full list; changes nothing.
- `olecharms cleanup --log` — the last 20 runs from `~/.local/state/olecharms/cleanup.log` (which lists every file each run removed).
- `olecharms cleanup --restore` — picks a quarantined cleanup (newest preselected) and puts its files back; never overwrites a name taken meanwhile.
- `--scheduled` — what the launcher calls: does nothing unless the feature is enabled.

### `windows` (WSL)
`olecharms windows` syncs fonts and gVim now (also part of every update); `olecharms windows status` runs the doctor's Windows checks.

### `status`
Shows OS, repo path, config version, repo commit, installed plugin versions (commit + date), pathogen status, available shell commands, the downloads cleanup settings and last run, and on WSL the Windows gVim found and where its config lives.

### `alias`
- `olecharms alias add <name> <command...>` — everything after the name is the command, so both `alias add gs git status` and `alias add claude "claude --update && claude"` work. Shows what will change, warns if the name already means something — through the wrapper, which passes the running shell's `type` output in `OLECHARMS_NAME_TYPE`, this includes oh-my-zsh aliases and functions the child bash cannot see; without it, only commands on `PATH` — then asks `[Y/n]` (Enter = yes) before writing.
- `olecharms alias add --global <name> <command...>` — the same, published to every machine through git.
- `olecharms alias list` — name/command table, global ones in their own section (marked when overridden on this machine).
- `olecharms alias delete <name>` — same confirmation. A per-machine alias goes first; deleting a global one asks (default no) and publishes the removal.
- `olecharms aliaslast` — arrow-key picker over the latest commands of the running shell (cursor on the newest), then a name, checked against existing aliases, functions, builtins and commands; finally asks whether to make it global. If this machine cannot push, it explains how to grant access (SSH keys) and waits.

Because a child process cannot change its parent shell's aliases, the generated loader defines an `olecharms()` shell function that runs the real script and reloads the alias files afterwards (also after `aliaslast` and `update`). For `aliaslast` it first writes a snapshot of the shell's history and taken names to a private temp dir (`OLECHARMS_SHELL_SNAPSHOT`), removed afterwards. That makes a new alias usable immediately in the shell that created it; the script prints `Ready to use in this session.` when it detects the wrapper (via `OLECHARMS_SHELL_WRAPPER`) and otherwise points at the file to `source`.

### `config`
Interactive menu loop offering:
1. **Downloads auto-cleanup** — enable with folder, schedule (hook/cron), trash-or-delete and a preview; once enabled, preview / change action / change max age / history / disable
2. **Paranoid mode** — toggle on/off, choose hook vs cron; enables the downloads cleanup at 15 days, or lowers it to 15 days, with a preview first
3. **Windows gVim & fonts** (WSL only) — `auto` / `off`
4. **Daily health check** — `daily_doctor` on/off
5. **Shared settings** — share this machine's settings with every machine (`shared_publish`, through the same publish path as global aliases), apply the shared ones here (`shared_apply`), or follow again the ones kept different
6. **Zsh extras** — fzf keys, suggestions and syntax colours on/off (`config_zsh_extras`)

### Shared settings
`shared-config` in the checkout holds `SHARED_KEYS`: the cleanup's max age, action, quarantine days and on/off, paranoid mode, the daily health check and zsh extras — not folders, scheduling methods or the Windows integration, which stay per machine. It travels like `global-aliases.sh`: `shared_publish()` runs `global_alias_publish` with `GLOBAL_PUBLISH_FILE` set to it, so the commit holds that file alone and the push gets the same access checks and retries. A machine never applies shared settings on its own: `shared_apply()` asks about each difference — `[y]es` applies it the way `config` does (enabling the cleanup or paranoid mode shows the preview and asks again; a shorter max age shows what it removes), `[n]ot now`, or `[k]eep this machine different`, recorded in `shared_keep_local` and left out of comparisons. A cleanup age or action makes no difference while the cleanup is off on both sides and is not reported. `~/.local/state/olecharms/shared-seen` holds the fingerprint of the file this machine last went through, so `sync` / `update` speak up only when it changed; `doctor` always lists differences.

### Clipboard
`bin/olecharms-clip` (POSIX sh) is the one place that knows how to reach the system clipboard: over SSH without X forwarding, OSC 52 to the local terminal (wrapped for tmux and screen; paste is impossible that way and says so); macOS `pbcopy`/`pbpaste`; WSL `win32yank.exe` when present, else `clip.exe` fed UTF-16LE (so accents survive) and PowerShell's `Get-Clipboard` (about a second); Wayland `wl-copy`/`wl-paste`; X11 `xclip`/`xsel`. A copy of a single line drops its trailing newline. `OLECHARMS_CLIP_FILE` swaps the clipboard for a file in tests; `OLECHARMS_CLIP_BACKEND` forces a backend.

`shell/clipboard.sh` defines `copy` (stdin, or the files given) and `paste`. `paste` only takes over when called with no arguments at a terminal; with arguments or piped input it is still `paste(1)`.

Terminal Vim (`olevimrc.vim`, not gVim, and only without a working `+clipboard`) emulates `clipboard=unnamed` for yanks: `TextYankPost` sends every yank, and any operation on `"+` / `"*` (mapped to an explicit `""`, which the event reports as register `"` — a plain yank reports none), to the clipboard in a background job after 150 ms — a macro yanking many times copies once — flushed synchronously on exit. Deletes stay inside Vim. Over SSH Vim writes the OSC 52 sequence itself (`echoraw`). With no clipboard at all (backend `none`) it warns once per session. It needs `TextYankPost` (Vim 8.0.1394+); Vims before 8.1.1837 cannot report `clipboard_working`, so there a `+clipboard` build is trusted. `"+p` / `"+P` / `"+gp` / `"+gP` (normal and visual), `<C-r>+` (insert and command line) and `,p` read the clipboard. Visual Ctrl-C copies and Ctrl-S saves in every Vim.

### Secrets
`~/.config/olecharms/secrets` holds `export NAME='value'` lines, mode 600 from the first byte (`secret_rewrite()` writes a private temp file and renames it). The shell loader sources it when the user owns it, and the `olecharms()` wrapper re-sources it (or unsets the name) after `secret` so the current shell sees the change. `secret_scan()` finds unindented `NAME=value` lines outside any if/case/loop/function block (`rc_toplevel_lines()`, since `zsh -n` accepts an emptied block) in the shell startup files, whose name looks like a secret (`secret_name_like()`: KEY, TOKEN, SECRET, PASS(WORD), PAT, CREDENTIALS as a `_`-separated part — not `KEYTIMEOUT`) and whose value is a literal (no `$VAR`, `$(...)`). `secret_import()` moves those lines verbatim to the secrets file; in the RC file the first of them becomes `[ -f "$HOME/.config/olecharms/secrets" ] && . "$HOME/.config/olecharms/secrets"  # olecharms secrets`, so later lines that use them and shells that read only that file (`.zshenv`, `.profile`, cron, `ssh host cmd`) keep working, and the rest go. The edit is in place, with no lasting backup of the RC file (it would keep the secret in plain text): a private copy exists only until the write succeeded. It refuses when the line count is off or the edited file would no longer parse (`rc_parses_like()`, `bash -n` / `zsh -n`). Values are never printed.

### Zsh extras
With `zsh_extras=on` the loader, in interactive shells only, sets up fzf's key bindings in bash and zsh (`fzf --zsh` / `--bash` on fzf ≥ 0.48, else the scripts the package ships) and, in zsh, sources zsh-autosuggestions (strategy `history completion`, since history is often not saved) and then zsh-syntax-highlighting, last as it requires. Each is skipped when something already loaded it. The setting is written into the loader, so changing it regenerates it. `pick_item()` (aliaslast, `cleanup --restore`) uses fzf when present — newest entry at the cursor, typing filters — unless `OLECHARMS_NO_FZF` is set.

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

`~/.config/olecharms/packages.local.conf` is sourced right after it, for additions that only apply to one machine (`APT_PACKAGES+=( htop )`, `VIM_PLUGINS+=(...)`, branches on `$OLECHARMS_OS` / `$OLECHARMS_WSL`). It lives outside the checkout, so updates never touch it and local edits never collide with `git pull`.

## vimthings/

Bundled vim configuration:

- **`olevimrc.vim`** — the main vim config file, sourced from `~/.vimrc` and — copied into `vimfiles\olecharms\` — from Windows' `_vimrc`. Configures pathogen loading, editor settings, key mappings, and plugin options. Portable on purpose: sets UTF-8 first (Windows Vim starts in the legacy code page), keeps undo/swap files under `~/vimfiles` on Windows and `~/.vim` elsewhere, and spells `guifont` the way each GUI expects.
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
| `copy` / `paste` | The system clipboard on Linux, macOS, WSL and over SSH (see [Clipboard](#clipboard)) |

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

- **`olecharms-shell.sh`** — sources all `shell/*.sh` files (resolving its own directory at runtime to find `shell/`), activates autojump, loads the secrets file, sets up the zsh extras, loads the aliases and defines the `olecharms()` wrapper
- **`olecharms-hook.sh`** — shell-hook dispatcher; resolves its own directory at runtime to find sibling scripts and `.last-run/`
- **`cleanup-downloads.sh`** — a launcher for `olecharms cleanup --scheduled`, which reads folder, age and action from the config at run time (see [Downloads Cleanup Engine](#3c-downloads-cleanup-engine-lines-1822-2392)). The engine works on the folder's resolved path — on WSL `~/downloads` is usually a symlink into `/mnt/c`, and plain `find` does not descend into a symlinked starting point
- **`paranoid-cleanup.sh`** — every 12 hours, permanently deletes shell history (plus the shell's own `$HISTFILE`, which the hook passes as an argument: only a history-named file inside home), other tools' histories (less, python, node, sqlite, psql, mysql, irb, redis-cli, wget HSTS), the cleanup log, `~/.viminfo` and vim swap/undo files; on WSL also the Windows gVim's `_viminfo` and `vimfiles` swap/undo files
- **`doctor-daily.sh`** — launcher for the daily `doctor --quiet` run
- **`.last-run/`** — directory of timestamp files used by the hook to enforce intervals

Each generated script carries `# olecharms-generator: N`; `doctor` flags any older than the running script.

## Config Versioning

Persistent settings are stored in `~/.config/olecharms/config` (XDG-compliant). The system uses a version-driven migration mechanism.

### Config file format
Simple `key=value` pairs. Parsed safely without `source` — only alphanumeric keys and underscores are allowed.

### Migration mechanism
- `CURRENT_CONFIG_VERSION` in `olecharms.sh` defines the target version
- `config_ensure()` runs on every subcommand: bootstraps if no config exists, otherwise reads and migrates
- `migrate_config()` loops from the file's `CONFIG_VERSION` up to `CURRENT_CONFIG_VERSION`, calling `migrate_config_N_to_M()` functions if they exist
- To add a new config flag: increment `CURRENT_CONFIG_VERSION`, add a `migrate_config_N_to_M()` function that calls `config_set` for the new key, and update `config_write_all()` to include it

### Current config keys (v4)
- `downloads_cleanup_enabled` (true/false)
- `downloads_cleanup_dir` (path)
- `downloads_cleanup_method` (hook/cron)
- `downloads_cleanup_max_age_days` (integer)
- `downloads_cleanup_action` (auto/trash/delete) — v3. `auto`: Windows Recycle Bin / macOS Trash when there is one, else quarantine
- `downloads_cleanup_quarantine_days` (integer, 30) — v4
- `paranoid_mode_enabled` (true/false)
- `paranoid_mode_method` (hook/cron)
- `windows_integration` (auto/off) — v3, WSL only
- `daily_doctor` (on/off) — v4
- `zsh_extras` (on/off, default on) — written only when changed
- `shared_keep_local` (space-separated shareable keys this machine keeps different) — written only when used
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
`error()` and `warn()` write to stderr, so a message from a function whose output is captured with `$(...)` still reaches the screen instead of the variable. `error()` increments `ERROR_COUNT` and `main()` exits non-zero when it is non-zero or when the subcommand itself returned non-zero (an `error()` inside a pipeline runs in a subshell and never reaches the counter), so `olecharms update && ...` and cron jobs see failures. `cmd_install()` hands over to a login zsh only when stdin and stdout are both terminals and the run was clean; otherwise it returns normally so the exit status survives. `doctor` exits 1 when any check fails.

### Smart package check
On Linux, `dpkg-query` checks each package's status (`ok installed`; a removed-but-not-purged package counts as missing) before invoking `sudo apt-get`. If all packages are already installed, `sudo` is never called. When the batch install fails — one name unknown to this release makes apt install nothing — it retries one by one and names the failures.

### Self-update with re-exec
`_self_update()` hashes `olecharms.sh` and `packages.conf` before and after the pull (`checkout_pull()`: no prompts, stalled transfers time out, an interrupted rebase is aborted and conflict markers never stay in files olecharms runs or sources). If either changed, it `bash -n`-checks the new file and then `exec bash`s it (not the file directly, which would abort the update half-way on a checkout that lost its exec bit) so the rest of the install runs with updated code. The re-exec sets `OLECHARMS_RELAUNCHED=1`, which makes the new process skip self-update entirely — a mis-comparing hash can never loop — and is unset right away so it cannot reach shells started later.

### Dual scheduling (hook + cron)
Cleanup features can be scheduled via shell hooks (checked on every shell open, throttled by timestamp files) or via cron jobs. The hook approach works without a cron daemon and runs even on systems where cron isn't available.

### Recoverable cleanup by default
The downloads cleanup defaults to `auto`: on WSL, files on a Windows drive go to the Windows Recycle Bin, and on macOS to the Trash. Where there is no such trash (plain Linux, or a Windows drive whose bin is off) they go to a quarantine instead: a timestamped batch keeping their relative paths and an `.origin` file, in `~/.local/share/olecharms/quarantine` when that is on the same filesystem (a rename), else in a hidden `.olecharms-quarantine` next to the cleaned folder. Batches older than `downloads_cleanup_quarantine_days` are deleted by later runs — only timestamp-named dirs holding `.origin`, directly in a quarantine folder. `cleanup --restore` undoes a batch. Only `action=delete` deletes outright. Every run is logged file by file, and the config menu shows what the first run would remove before enabling.

The Recycle Bin is only trusted when it works: `win_bin_status()` asks Windows whether the drive's bin is on (per-volume `NukeOnDelete`, the `NoRecycleFiles` policy, fixed drive) and how big it is. When it is off, `auto` means delete and the preview says so in plain words. `SHFileOperation` under `NOCONFIRMATION` silently deletes whatever the bin cannot take, so the recycler skips (keeps) files bigger than the bin or on a drive without one, and logs them as `kept`.

### Deletion safety
Every destructive path has two independent guards:

| What deletes | First guard | Second guard |
|---|---|---|
| Downloads cleanup | `cleanup_real_dir()`: refuses `/`, home and anything holding it, the checkout and anything inside it, hidden folders of home, system folders, whole drives/volumes, `C:\Users\<name>` itself; selection needs both mtime and ctime older than N days (extracted or copied files keep an old mtime), skips git checkouts (and olecharms) and never follows symlinks | `cleanup_verify_list()` re-checks every path right before removal (regular file, not a symlink, strictly inside the folder, not in `.git` or a checkout); mass-removal brake: a scheduled run over 300 files, 10 GB or half the folder is held (`cleanup.held`, announced in new shells and by `doctor`) until confirmed by typing the count |
| Empty folders after a cleanup | only folders this run emptied (`rmdir`, which cannot remove anything else) | long-empty ones only when old by mtime and ctime, never under `.git` or a checkout |
| Paranoid mode | `purge_dir()` resolves the folder and refuses home, its parents and `/` (a symlinked undodir) | only vim's own names, one level deep: undo files (`*%*`), swap files (`*.s[a-w][a-z]`) — and swap files only while no vim runs |
| Plugins (`rm -rf`, `rsync --delete`, `reset --hard`) | `plugin_name_valid()`: a plain folder name | `clone_or_pull()` / `mirror_dir()` refuse any destination that is not a plugin folder directly under `bundle/`; `reset --hard` only over a clean work tree; Windows copies are pruned only when stamped |
| Self-update conflicts (`checkout_pull()`) | does nothing while a merge or rebase is in progress | resets a conflicted file only when git's autostash grew and holds that very file |
| Crontab | entries matched by marker | `crontab -r` only when every remaining line is olecharms' own |
| Quarantine expiry | only batches older than the configured days | `cleanup_quarantine_is_batch()`: a real dir named `YYYYMMDD-HHMMSS`, directly in a folder named `quarantine` or `.olecharms-quarantine`, holding `.origin` |
| Retiring unlisted plugins | only names olecharms recorded as its own clones | moved to `bundle_disabled`, never deleted; refused when most managed plugins would go at once (a packages.conf that lost entries) |
| `aliaslast` snapshot | basename `olecharms.*`, a real directory | removes only the five file names it writes, then `rmdir` |
| Zsh plugin clone that failed | plugin names are plain folder names | removes only the folder that very `git clone` created (it did not exist before) |
| Lines moved out of RC files (`secret import`) | only unindented `NAME=literal` lines whose name looks like a secret, re-read right before the edit | the edited file must keep its line count minus those lines and still parse (`bash -n` / `zsh -n`); the lines themselves land in the secrets file first |
| Old `olevimrc` copy in `~/.vimrc`, broken git helper, Windows Terminal font | only on a `y` in `doctor --fix`, after the doctor listed any line that is the user's own | a timestamped backup of the file first |

### Windows side from WSL
Windows' gVim cannot follow WSL symlinks and should not depend on WSL running, so it gets copies: the plugins olecharms already cloned for the terminal vim (without `.git`), pathogen and `olevimrc.vim`. Copies are stamped so updates can remove what olecharms put there and never touch anything else. Fonts are installed per user (HKCU), which needs no admin rights.

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
| `# olecharms managed aliases - edit with 'olecharms alias'` | Header of `~/.config/olecharms/aliases` |

Blocks are added with `append_block()` (one blank separator line, none when the file is new) and removed with `rc_strip_block()`, which also absorbs that separator so repeated install/remove cycles do not accumulate blank lines.

## Testing

- **Syntax check:** `bash -n olecharms.sh`
- **Non-destructive:** `./olecharms.sh check` and `./olecharms.sh status`
- **Cleanup in tests:** a file's mtime can be back-dated but not its ctime, so tests set `OLECHARMS_TEST_IGNORE_CTIME=1`.
- **Sandboxed end-to-end:** point `HOME` and `XDG_CONFIG_HOME` at a scratch directory and run `update` twice against a copy of the checkout; the second run must report no errors and leave the RC files, config and crontab byte-identical. Put a fake `crontab` first on `PATH` too — the crontab belongs to the user, not to `$HOME` — and a copy of the checkout keeps the generated `scripts/` of the real one untouched.
