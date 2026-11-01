#!/bin/bash
# olecharms.sh — Environment management script for olecharms
# Usage: ./olecharms.sh {install|update|check|status|config|help}

# ─── Constants & Globals ─────────────────────────────────────────────────────

_src="${BASH_SOURCE[0]}"
_guard=0
while [ -L "$_src" ] && [ "$_guard" -lt 32 ]; do
    _dir="$(cd "$(dirname "$_src")" && pwd)" || break
    _src="$(readlink "$_src")" || break
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
    _guard=$((_guard + 1))
done
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
# Use the real filename rather than assuming "olecharms.sh", so a renamed
# checkout still symlinks and relaunches correctly.
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$_src")"
unset _src _dir _guard
CONF_FILE="$SCRIPT_DIR/packages.conf"
VIM_DIR="$HOME/.vim"
VIMRC="$HOME/.vimrc"
BUNDLED_DIR="$SCRIPT_DIR/vimthings"
BUNDLED_STAMP=".olecharms-bundled"
PATHOGEN_STAGING="$VIM_DIR/.pathogen-repo"
FONTS_STAGING="$VIM_DIR/.fonts-repo"
ERROR_COUNT=0
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
CLEANUP_SCRIPT="$SCRIPTS_DIR/cleanup-downloads.sh"
DOWNLOADS_MAX_AGE_DAYS=30
PARANOID_SCRIPT="$SCRIPTS_DIR/paranoid-cleanup.sh"
# Paranoid mode keeps downloads at most this old (enables or lowers the cleanup)
PARANOID_MAX_AGE_DAYS=15
HOOK_SCRIPT="$SCRIPTS_DIR/olecharms-hook.sh"
HOOK_MARKER="# olecharms managed hook - do not remove this line"
LASTRUN_DIR="$SCRIPTS_DIR/.last-run"
DOWNLOADS_INTERVAL=86400
PARANOID_INTERVAL=43200
CRON_MARKER_DOWNLOADS="# olecharms:downloads-cleanup"
DOWNLOADS_CRON_HOUR=16
DOWNLOADS_CRON_MIN=0
CRON_MARKER_PARANOID="# olecharms:paranoid-cleanup"
PARANOID_CRON_SCHEDULE="0 */12 * * *"
SHELL_DIR="$SCRIPT_DIR/shell"
SHELL_LOADER="$SCRIPTS_DIR/olecharms-shell.sh"
SHELL_MARKER="# olecharms shell commands - do not remove this line"
BIN_DIR="$HOME/.local/bin"
BIN_MARKER="# olecharms PATH - do not remove this line"
EDITOR_MARKER="# olecharms editor - do not remove this line"
OLECHARMS_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/olecharms"
OLECHARMS_CONFIG_FILE="$OLECHARMS_CONFIG_DIR/config"
# User aliases live next to the config, not in the gitignored scripts/ dir, so
# they survive a fresh clone and a moved checkout.
ALIAS_FILE="$OLECHARMS_CONFIG_DIR/aliases"
ALIAS_MARKER="# olecharms managed aliases - edit with 'olecharms alias'"
# Global aliases live in the repo, so every machine gets them on update.
# Loaded before the per-machine file, which therefore wins on a shared name.
GLOBAL_ALIAS_FILE="$SCRIPT_DIR/global-aliases.sh"
# Settings shared by every machine (olecharms config → Shared settings)
SHARED_CONFIG_FILE="$SCRIPT_DIR/shared-config"
# API keys and tokens kept out of the RC files (olecharms secret)
SECRETS_FILE="$OLECHARMS_CONFIG_DIR/secrets"
# zsh plugins olecharms keeps (olecharms config → Zsh extras); fzf comes
# from the package lists
ZSH_EXTRAS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/olecharms/zsh-plugins"
ZSH_EXTRA_PLUGINS=(
    "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions.git"
    "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git"
)
# Per-machine package/plugin additions, sourced after the tracked packages.conf
# so local changes never collide with a self-update's git pull.
LOCAL_CONF_FILE="$OLECHARMS_CONFIG_DIR/packages.local.conf"
OLECHARMS_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/olecharms"
CLEANUP_LOG="$OLECHARMS_STATE_DIR/cleanup.log"
CLEANUP_LOG_MAX_LINES=10000
# Mass-removal brake: a scheduled run that would take more than this is held
# until confirmed by hand (typing the file count); `cleanup --yes` needs --force
CLEANUP_HELD="$OLECHARMS_STATE_DIR/cleanup.held"
CLEANUP_BATCH_FILES=300
CLEANUP_BATCH_KB=$((10 * 1024 * 1024))
CLEANUP_BATCH_PERCENT=50
# Where no trash is available, "auto" moves files to a quarantine kept this
# many days (downloads_cleanup_quarantine_days); `cleanup --restore` undoes
CLEANUP_QUARANTINE_DAYS=30
QUARANTINE_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/olecharms/quarantine"
QUARANTINE_SIBLING=".olecharms-quarantine"
# Daily background doctor run from the shell hook (config daily_doctor)
DOCTOR_SCRIPT="$SCRIPTS_DIR/doctor-daily.sh"
DOCTOR_PROBLEMS="$OLECHARMS_STATE_DIR/doctor.problems"
DOCTOR_INTERVAL=86400
# Time and commit of the last successful pull of the checkout
LAST_PULL_FILE="$OLECHARMS_STATE_DIR/last-pull"
# Fingerprint of shared-config when this machine last went through it
SHARED_SEEN_FILE="$OLECHARMS_STATE_DIR/shared-seen"
# Plugins olecharms cloned, so dropping one from packages.conf retires it
MANAGED_PLUGINS_FILE="$OLECHARMS_STATE_DIR/managed-plugins"
# Stamped into every generated script; `doctor` flags older ones.
GENERATOR_VERSION=5
GENERATOR_STAMP="# olecharms-generator:"
# Marks the plugin copies olecharms owns inside Windows' vimfiles\bundle
WIN_MANAGED_STAMP=".olecharms-managed"
WIN_VIMRC_LINE="source ~/vimfiles/olecharms/olevimrc.vim"
CURRENT_CONFIG_VERSION=4

# olecharms is a userland install: everything it writes lives under $HOME
# (plus the checkout itself). Nothing here needs root except optional system
# package installation, which is delegated to sudo.
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ] || [ ! -w "$HOME" ]; then
    echo "olecharms: \$HOME is unset, missing or not writable — cannot continue" >&2
    exit 1
fi

# Source line we manage in ~/.vimrc
SOURCE_MARKER="\" olecharms managed config - do not remove this line"
# :source takes a bare path, so spaces and other vim-special characters have to
# be backslash-escaped rather than quoted.
_vim_escape() { printf '%s' "$1" | sed 's/[ \\|"%#]/\\&/g'; }
SOURCE_LINE="source $(_vim_escape "$SCRIPT_DIR/vimthings/olevimrc.vim")"

# ─── Color / Output Helpers ──────────────────────────────────────────────────

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info()  { echo -e "${GREEN}[+]${NC} $*"; }
# Diagnostics go to stderr: inside $(...) they would otherwise end up in the
# captured value instead of on screen.
warn()  { echo -e "${YELLOW}[!]${NC} $*" >&2; }
error() { echo -e "${RED}[-]${NC} $*" >&2; ERROR_COUNT=$((ERROR_COUNT + 1)); }

# ─── Utility Functions ───────────────────────────────────────────────────────

load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        error "Config file not found: $CONF_FILE"
        return 1
    fi
    detect_os
    # Let packages.local.conf branch per machine without parsing uname itself
    OLECHARMS_OS="$OS"
    OLECHARMS_WSL="$IS_WSL"
    # shellcheck source=packages.conf
    source "$CONF_FILE"
    if [ -f "$LOCAL_CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$LOCAL_CONF_FILE" || warn "Errors while loading $LOCAL_CONF_FILE"
    fi
}

# Create a commented packages.local.conf so the override mechanism is
# discoverable. Never touches an existing file.
ensure_local_conf_template() {
    [ -e "$LOCAL_CONF_FILE" ] && return 0
    mkdir -p "$OLECHARMS_CONFIG_DIR" 2>/dev/null || return 0
    cat > "$LOCAL_CONF_FILE" <<'LOCAL_EOF'
# olecharms packages.local.conf — additions and overrides for THIS machine.
# Sourced (plain bash) after packages.conf in the olecharms checkout. Updates
# never touch this file, so keep per-machine changes here rather than editing
# packages.conf, where they would collide with `git pull`.
#
# Available: $OLECHARMS_OS (linux | macos)   $OLECHARMS_WSL (1 on WSL, else empty)
#
# APT_PACKAGES+=( htop jq )
# BREW_PACKAGES+=( htop jq )
# VIM_PLUGINS+=( "commentary|https://github.com/tpope/vim-commentary.git" )
# FONT_FAMILIES+=( "SourceCodePro" )
# [ "$OLECHARMS_OS" = macos ] && BREW_PACKAGES+=( coreutils )
# [ -n "$OLECHARMS_WSL" ] && POST_INSTALL_COMMANDS+=( "echo running on WSL" )
LOCAL_EOF
    info "Created $LOCAL_CONF_FILE for per-machine packages and plugins"
}

detect_os() {
    # Idempotent: several entry points call it
    [ -n "${OS:-}" ] && return 0
    IS_WSL=""
    case "$(uname -s)" in
        Linux*)
            OS="linux"
            PKG_MANAGER="apt-get"
            FONT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
            if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
               || grep -qi microsoft /proc/version 2>/dev/null; then
                IS_WSL=1
            fi
            ;;
        Darwin*)
            OS="macos"
            PKG_MANAGER="brew"
            FONT_DIR="$HOME/Library/Fonts"
            ;;
        *)
            OS="unknown"
            PKG_MANAGER=""
            FONT_DIR="$HOME/.fonts"
            warn "Unknown OS: $(uname -s). Package installation may not work."
            ;;
    esac
}

backup_file() {
    local file="$1" backup
    [ -e "$file" ] || return 0
    backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    # -L: back up the content behind a symlinked dotfile (stow, chezmoi), not a
    # second link to the very file we are about to rewrite.
    if ! cp -RLp "$file" "$backup"; then
        error "Could not back up $file"
        return 1
    fi
    info "Backed up $file → $backup"
}

# git for third-party repos: never stop to ask for credentials (GitHub answers
# a renamed or deleted repo with an auth prompt) and give up on a stalled
# transfer instead of hanging the whole update.
_git_net() {
    GIT_TERMINAL_PROMPT=0 \
    GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}" \
    GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-60}" \
        git "$@"
}

# `git pull --rebase --autostash` of the checkout, safe to run unattended: a
# conflict must never stay behind in files olecharms runs or sources (every
# shell would then fail on the markers). A rebase that stops is aborted; local
# changes that clash with the update are reset to the updated version — git
# keeps them in the stash. Returns 1 on a conflict with local commits (left
# as they were), 2 when the pull itself failed (offline...) with git's message
# in CHECKOUT_PULL_ERR.
CHECKOUT_PULL_ERR=""
checkout_pull() {
    local dir="$SCRIPT_DIR" err rc gitdir unmerged f stash_before stash_after
    CHECKOUT_PULL_ERR=""
    gitdir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || return 2
    # Someone is in the middle of a merge or rebase here: leave it alone
    if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] || [ -f "$gitdir/MERGE_HEAD" ] ||
       [ -n "$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
        error "$dir has a merge or rebase in progress; not updating it until that is finished"
        return 1
    fi
    stash_before=$(git -C "$dir" stash list 2>/dev/null | wc -l | tr -d ' ')
    err=$(_git_net -C "$dir" pull --rebase --autostash -q 2>&1)
    rc=$?
    if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
        git -C "$dir" rebase --abort >/dev/null 2>&1
        error "Local commits in $dir conflict with the update; left as they were."
        error "Resolve by hand: git -C \"$dir\" pull --rebase"
        return 1
    fi
    unmerged=$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null)
    stash_after=$(git -C "$dir" stash list 2>/dev/null | wc -l | tr -d ' ')
    if [ -n "$unmerged" ]; then
        # Only when git kept the local changes in the stash: then the conflict
        # markers are the sole copy of nothing and can go
        if [ "$stash_after" -le "$stash_before" ]; then
            error "Conflict markers left in $dir: $(echo $unmerged) — fix them by hand"
            return 1
        fi
        # ...and each file is really in that stash entry
        local stashed
        stashed=$(git -C "$dir" stash show --name-only 'stash@{0}' 2>/dev/null)
        while IFS= read -r f; do
            if ! printf '%s\n' "$stashed" | grep -qxF -- "$f"; then
                error "Conflict markers left in $dir/$f and its local version is not in the stash — fix it by hand"
                return 1
            fi
        done <<< "$unmerged"
        while IFS= read -r f; do
            git -C "$dir" checkout -q HEAD -- "$f" 2>/dev/null
        done <<< "$unmerged"
        git -C "$dir" reset -q 2>/dev/null
    fi
    if [ -n "$unmerged" ] || [ "$stash_after" -gt "$stash_before" ]; then
        warn "Your local changes clashed with the update and were set aside in git stash."
        [ -n "$unmerged" ] && warn "These files now match the update: $(echo $unmerged)"
        warn "Inspect them with: git -C \"$dir\" stash show -p"
    fi
    if [ "$rc" -ne 0 ]; then
        CHECKOUT_PULL_ERR=$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 1)
        return 2
    fi
    mkdir -p "$OLECHARMS_STATE_DIR" 2>/dev/null
    printf '%s %s\n' "$(date +%s)" "$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" > "$LAST_PULL_FILE" 2>/dev/null
    return 0
}

clone_or_pull() {
    local url="$1"
    local dest="$2"
    local name="$3"
    local fallback="$4"  # optional bundled fallback path

    # Second guard for the rm -rf / mv below: dest is a plugin folder directly
    # under bundle/, or one of the fixed staging dirs — nothing else
    case "$dest" in
        "$VIM_DIR/bundle/"*/*|"$VIM_DIR/bundle/") error "Refusing to manage $dest"; return 1 ;;
        "$VIM_DIR/bundle/"?*|"$PATHOGEN_STAGING"|"$FONTS_STAGING") ;;
        *) error "Refusing to manage $dest"; return 1 ;;
    esac

    if [ -d "$dest/.git" ]; then
        info "Updating $name..."
        plugin_follow_default_branch "$dest" "$name" && return 0
        if _git_net -C "$dest" pull --ff-only 2>/dev/null; then
            return 0
        fi
        warn "git pull failed for $name, trying reset"
        if _git_net -C "$dest" fetch origin 2>/dev/null; then
            local branch
            branch=$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null)
            if [ -z "$branch" ]; then
                # Detached HEAD: fall back to the remote's default branch
                branch=$(git -C "$dest" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
                branch="${branch#origin/}"
            fi
            [ -z "$branch" ] && branch="master"
            # reset --hard would silently throw away edits made to the plugin
            if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
                warn "$name has local changes; not resetting it (git -C \"$dest\" status)"
                return 1
            fi
            git -C "$dest" reset --hard "origin/$branch" 2>/dev/null && return 0
        fi
        warn "Could not update $name (may be offline)"
        return 1
    fi

    # A copy we made from the bundled fallback on a previous offline run. Try to
    # upgrade it to a real clone, but keep it untouched if we are still offline.
    # (Without this, every offline run would shunt it into bundle_disabled and
    # re-copy it, which grows without bound.)
    if [ -d "$dest" ] && [ -f "$dest/$BUNDLED_STAMP" ]; then
        local tmp_clone="${dest}.clone.$$"
        rm -rf "$tmp_clone"
        if _git_net clone --depth 1 "$url" "$tmp_clone" 2>/dev/null; then
            rm -rf "$dest"
            if mv "$tmp_clone" "$dest"; then
                info "Replaced bundled $name with a fresh clone"
                return 0
            fi
            error "Could not install fresh clone of $name"
            return 1
        fi
        rm -rf "$tmp_clone"
        info "Keeping bundled copy of $name (offline)"
        return 0
    fi

    # Directory exists but is neither a git repo nor one of ours: preserve it.
    if [ -d "$dest" ]; then
        warn "$name exists but is not a git repo. Moving to bundle_disabled and re-cloning."
        local disabled_dest="$VIM_DIR/bundle_disabled/${name}.replaced.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$VIM_DIR/bundle_disabled"
        if ! mv "$dest" "$disabled_dest"; then
            error "Could not move $dest out of the way"
            return 1
        fi
        info "Moved $dest → $disabled_dest"
    fi

    mkdir -p "$(dirname "$dest")"
    info "Cloning $name..."
    if _git_net clone --depth 1 "$url" "$dest" 2>/dev/null; then
        return 0
    fi

    # Fallback to bundled copy
    if [ -n "$fallback" ] && [ -d "$fallback" ]; then
        warn "Clone failed for $name. Using bundled copy from $fallback"
        rm -rf "$dest"
        if cp -r "$fallback" "$dest"; then
            : > "$dest/$BUNDLED_STAMP"
            return 0
        fi
        error "Could not copy bundled $name from $fallback"
        return 1
    fi

    warn "Could not fetch $name and no bundled fallback is available"
    return 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Resolve a symlink chain to its final target. Portable: `readlink -f` is GNU
# and only reached macOS in Monterey.
resolve_link() {
    local path="$1" dir guard=0
    while [ -L "$path" ] && [ "$guard" -lt 32 ]; do
        dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd) || break
        path=$(readlink "$path") || break
        case "$path" in
            /*) ;;
            *)  path="$dir/$path" ;;
        esac
        guard=$((guard + 1))
    done
    echo "$path"
}

# Replace $2's contents with $1's. Writes through symlinks (so stow/chezmoi
# dotfiles keep working) and swaps in via rename, so an interrupted run cannot
# leave a half-written RC file behind. Preserves the original mode/ownership.
write_file_contents() {
    local src="$1" dest="$2"
    local target tmp
    if [ ! -f "$src" ]; then
        error "Internal error: temp file $src is missing"
        return 1
    fi

    target=$(resolve_link "$dest")
    [ -n "$target" ] || target="$dest"
    tmp="${target}.olecharms.$$"

    # Seed the temp file next to the target so the rename below stays atomic,
    # copying the target's permissions and ownership where we can.
    if [ -e "$target" ]; then
        cp -p "$target" "$tmp" 2>/dev/null || : > "$tmp" 2>/dev/null
    else
        : > "$tmp" 2>/dev/null
    fi

    if [ ! -f "$tmp" ]; then
        # Directory not writable — fall back to an in-place rewrite
        if ! cat "$src" > "$target"; then
            error "Could not write to $target"
            return 1
        fi
        return 0
    fi

    if ! cat "$src" > "$tmp"; then
        rm -f "$tmp"
        error "Could not write to $target"
        return 1
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        error "Could not replace $target"
        return 1
    fi
    return 0
}

# Portable in-place sed: BSD/macOS sed requires an argument to -i, GNU does not.
sed_inplace() {
    local file="$1"; shift
    local tmpfile status
    tmpfile=$(mktemp) || { error "mktemp failed"; return 1; }
    if ! sed "$@" "$file" > "$tmpfile"; then
        rm -f "$tmpfile"
        error "sed failed on $file"
        return 1
    fi
    write_file_contents "$tmpfile" "$file"
    status=$?
    rm -f "$tmpfile"
    return $status
}

# Remove an olecharms-managed block from an RC file: the marker line, any line
# containing $3, and the blank line we insert before each block (so repeated
# install/remove cycles do not accumulate blank lines).
rc_strip_block() {
    local rc="$1" marker="$2" pat="${3:-}"
    local tmpfile status
    [ -f "$rc" ] || return 0
    tmpfile=$(mktemp) || { error "mktemp failed"; return 1; }
    if ! awk -v marker="$marker" -v pat="$pat" '
        function flush() { if (pending) { print ""; pending = 0 } }
        {
            if (index($0, marker) > 0 || (pat != "" && index($0, pat) > 0)) {
                pending = 0
                next
            }
            if ($0 == "") { flush(); pending = 1; next }
            flush()
            print
        }
    ' "$rc" > "$tmpfile"; then
        rm -f "$tmpfile"
        error "Could not rewrite $rc"
        return 1
    fi
    write_file_contents "$tmpfile" "$rc"
    status=$?
    rm -f "$tmpfile"
    return $status
}

# Append a block to $1, preceded by one blank separator line — but not when the
# file is new or empty, which would leave a stray blank line at the top. Makes
# sure the file ends with a newline first.
append_block() {
    local file="$1"; shift
    if [ -s "$file" ]; then
        [ -n "$(tail -c 1 "$file" 2>/dev/null)" ] && printf '\n' >> "$file"
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$@" >> "$file"
}

# The RC files we manage, one per line. Falls back to ~/.bashrc if none exist.
managed_rc_files() {
    local rc found=0
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        if [ -f "$rc" ]; then
            echo "$rc"
            found=1
        fi
    done
    [ "$found" -eq 0 ] && echo "$HOME/.bashrc"
    return 0
}

# Quote a path for a crontab command line: cron hands the line to /bin/sh, and
# an unescaped % is turned into a newline.
cron_quote_path() {
    local path="$1"
    path=${path//\'/\'\\\'\'}
    path=${path//%/\\%}
    printf "'%s'" "$path"
}

# Print the user's crontab (nothing when they have none). Fails — instead of
# printing an empty table — when it cannot be read, so a caller never rewrites
# the crontab from a blank read and wipes the user's other jobs.
cron_read() {
    local out errf status
    errf=$(mktemp) || { error "mktemp failed"; return 1; }
    out=$(LC_ALL=C crontab -l 2>"$errf")
    status=$?
    if [ "$status" -ne 0 ] && ! grep -qi 'no crontab' "$errf"; then
        error "Could not read crontab: $(head -1 "$errf")"
        rm -f "$errf"
        return 1
    fi
    rm -f "$errf"
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

# Replace (or, with an empty $2, remove) the crontab entry tagged with marker $1.
cron_replace_entry() {
    local marker="$1" entry="${2:-}"
    local current existing new_content
    if ! check_command crontab; then
        error "crontab is not available"
        return 1
    fi
    current=$(cron_read) || return 1
    existing=$(printf '%s\n' "$current" | grep -vF "$marker")
    if [ -n "$entry" ]; then
        if [ -n "$existing" ]; then
            new_content=$(printf '%s\n%s' "$existing" "$entry")
        else
            new_content="$entry"
        fi
    else
        new_content="$existing"
    fi
    # Already as wanted: leave the crontab alone (install/update call this on
    # every run).
    [ "$new_content" = "$current" ] && return 0
    if [ -z "$new_content" ]; then
        # Second check: everything we would drop is ours
        if [ -n "$(printf '%s\n' "$current" | grep -v '^[[:space:]]*$' | grep -vF '# olecharms:')" ]; then
            error "Not removing the crontab: it holds lines that are not olecharms'"
            return 1
        fi
        crontab -r 2>/dev/null || true
        return 0
    fi
    if ! printf '%s\n' "$new_content" | crontab -; then
        error "Could not update crontab"
        return 1
    fi
}

# Having the crontab command does not mean anything runs the jobs: WSL and many
# containers ship it with no daemon started. macOS starts cron on demand
# through launchd, so there is no process to look for there.
cron_daemon_running() {
    [ "$(uname -s)" = "Darwin" ] && return 0
    check_command pgrep || return 0
    pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
}

warn_if_no_cron_daemon() {
    cron_daemon_running && return 0
    warn "No cron daemon is running, so cron jobs will not fire. Start one (e.g. 'sudo service cron start'; on WSL enable systemd in /etc/wsl.conf) or use the shell hook."
}

_file_hash() {
    if check_command md5sum; then
        md5sum "$1" 2>/dev/null | cut -d' ' -f1
    elif check_command md5; then
        md5 -q "$1" 2>/dev/null
    else
        cksum "$1" 2>/dev/null | cut -d' ' -f1
    fi
}

# Candidate downloads folders, one per line. On WSL this includes the Windows
# user's real Downloads folder (wherever Windows says it is — it may be
# redirected or in OneDrive), so a fresh WSL with no ~/Downloads still works.
# Folders reaching the same place are listed once.
find_downloads_dirs() {
    local results d real seen="|" found=""
    results=$(find -L "$HOME" -maxdepth 1 -iname "downloads" -type d 2>/dev/null)
    if [ -n "${IS_WSL:-}" ] && win_env_load && [ -n "$WIN_DOWNLOADS" ] && [ -d "$WIN_DOWNLOADS" ]; then
        results="$results"$'\n'"$WIN_DOWNLOADS"
    fi
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        real=$(cd -P "$d" 2>/dev/null && pwd) || continue
        case "$seen" in *"|$real|"*) continue ;; esac
        seen="$seen$real|"
        echo "$d"
        found=1
    done <<< "$results"
    [ -n "$found" ]
}

is_downloads_cleanup_enabled() {
    [ -x "$CLEANUP_SCRIPT" ]
}

is_paranoid_mode_enabled() {
    [ -x "$PARANOID_SCRIPT" ]
}

is_downloads_cron_enabled() {
    check_command crontab && crontab -l 2>/dev/null | grep -qF "$CRON_MARKER_DOWNLOADS"
}

is_paranoid_cron_enabled() {
    check_command crontab && crontab -l 2>/dev/null | grep -qF "$CRON_MARKER_PARANOID"
}

# scripts/ lives inside the checkout; bail out clearly if it is read-only
# instead of writing broken half-generated files.
ensure_scripts_dir() {
    if ! mkdir -p "$SCRIPTS_DIR" 2>/dev/null || [ ! -w "$SCRIPTS_DIR" ]; then
        error "Cannot write to $SCRIPTS_DIR — is the olecharms checkout read-only?"
        return 1
    fi
    return 0
}

# Move a freshly written generated script into place. The rename stays within
# one directory, so it is atomic: a shell starting mid-update never sources
# half a file, and cron never runs one.
commit_generated() {
    local tmp="$1" dest="$2"
    if [ -s "$tmp" ] && chmod +x "$tmp" && mv -f "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    error "Could not write $dest"
    return 1
}

generate_hook_script() {
    ensure_scripts_dir || return 1
    local tmp="$HOOK_SCRIPT.tmp.$$"

    {
        cat <<'HOOK_EOF'
#!/bin/bash
# olecharms-hook.sh — sourced from shell profile for scheduled cleanups.
# Generated by olecharms and rewritten on every install/update.

_olecharms_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_olecharms_check_and_run() {
    local script="$1" name="$2" interval="$3"
    shift 3
    [ -x "$script" ] || return 0
    local lastrun_dir="$_olecharms_hook_dir/.last-run"
    local lastrun_file="$lastrun_dir/$name"
    local now last=0
    now=$(date +%s)
    [ -f "$lastrun_file" ] && last=$(cat "$lastrun_file" 2>/dev/null)
    # A truncated or corrupt timestamp must not break every new shell
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -ge "$interval" ]; then
        mkdir -p "$lastrun_dir" 2>/dev/null
        echo "$now" > "$lastrun_file" 2>/dev/null
        # Backgrounded from a subshell, so it stays out of the job table and
        # bash/zsh print no "[1] 1234" / "done" notices into the new prompt.
        ( "$script" "$@" >/dev/null 2>&1 & )
    fi
    return 0
}
HOOK_EOF
        echo "$GENERATOR_STAMP $GENERATOR_VERSION"

        # Only features scheduled through the hook (not cron). The intervals
        # are numeric constants, fine to bake in.
        if is_downloads_cleanup_enabled && ! is_downloads_cron_enabled; then
            echo "_olecharms_check_and_run \"\$_olecharms_hook_dir/cleanup-downloads.sh\" \"downloads-cleanup\" $DOWNLOADS_INTERVAL"
        fi
        if is_downloads_cleanup_enabled; then
            # A held mass removal waits for the user: say so in every new shell
            echo "[ -f $(printf '%q' "$CLEANUP_HELD") ] && echo \"[olecharms] Downloads cleanup on hold: \$(cat $(printf '%q' "$CLEANUP_HELD") 2>/dev/null). Review with: olecharms cleanup\""
        fi
        if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
            # The shell's own HISTFILE may be a custom one: hand it over
            echo "_olecharms_check_and_run \"\$_olecharms_hook_dir/paranoid-cleanup.sh\" \"paranoid-cleanup\" $PARANOID_INTERVAL \"\${HISTFILE:-}\""
        fi
        if daily_doctor_enabled; then
            echo "_olecharms_check_and_run \"\$_olecharms_hook_dir/doctor-daily.sh\" \"doctor-daily\" $DOCTOR_INTERVAL"
            echo "[ -s $(printf '%q' "$DOCTOR_PROBLEMS") ] && echo \"[olecharms] doctor: \$(cat $(printf '%q' "$DOCTOR_PROBLEMS") 2>/dev/null) — see: olecharms doctor\""
        fi

        echo ""
        echo "unset -f _olecharms_check_and_run"
        echo "unset _olecharms_hook_dir"
    } > "$tmp"
    commit_generated "$tmp" "$HOOK_SCRIPT"
}

# True if an enabled feature is scheduled through the shell hook.
hook_needed() {
    { is_downloads_cleanup_enabled && ! is_downloads_cron_enabled; } ||
        { is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; } ||
        daily_doctor_enabled
}

daily_doctor_enabled() {
    [ "$(config_get daily_doctor on)" != off ]
}

# The daily doctor's launcher (a thin one, like the cleanup's), or none
generate_doctor_launcher() {
    if ! daily_doctor_enabled; then
        rm -f "$DOCTOR_SCRIPT" "$DOCTOR_PROBLEMS" "$LASTRUN_DIR/doctor-daily"
        return 0
    fi
    ensure_scripts_dir || return 1
    local tmp="$DOCTOR_SCRIPT.tmp.$$"
    cat > "$tmp" <<DOCTOR_EOF
#!/bin/bash
# Generated by olecharms — daily background health check; new shells mention
# what it finds. Switch it off in 'olecharms config'.
$GENERATOR_STAMP $GENERATOR_VERSION
_olecharms_root="\$(cd "\$(dirname "\$0")/.." && pwd)" || exit 1
exec bash "\$_olecharms_root"/$(printf '%q' "$(basename "$SCRIPT_PATH")") doctor --quiet
DOCTOR_EOF
    commit_generated "$tmp" "$DOCTOR_SCRIPT"
}

# The single place that brings the hook in line with the enabled features:
# regenerate it and make sure the RC files source it when something uses it,
# remove both otherwise. Without this, switching a feature from hook to cron
# left it running from both.
sync_shell_hook() {
    if hook_needed; then
        generate_hook_script && install_shell_hook
    else
        remove_shell_hook
    fi
}

install_shell_hook() {
    local rc_files=() rc
    while IFS= read -r rc; do rc_files+=("$rc"); done < <(managed_rc_files)

    for rc in "${rc_files[@]}"; do
        if grep -qF "$HOOK_MARKER" "$rc" 2>/dev/null; then
            if grep -qF "source \"$HOOK_SCRIPT\"" "$rc" 2>/dev/null; then
                continue
            fi
            rc_strip_block "$rc" "$HOOK_MARKER" "olecharms-hook.sh" || return 1
        fi
        append_block "$rc" \
            "$HOOK_MARKER" \
            "[ -f \"$HOOK_SCRIPT\" ] && source \"$HOOK_SCRIPT\""
        info "Shell hook installed in $rc"
    done
}

remove_shell_hook() {
    local rc
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        [ ! -f "$rc" ] && continue
        if grep -qF "$HOOK_MARKER" "$rc" 2>/dev/null; then
            rc_strip_block "$rc" "$HOOK_MARKER" "olecharms-hook.sh" \
                && info "Shell hook removed from $rc"
        fi
    done
    rm -f "$HOOK_SCRIPT"
}

generate_shell_loader() {
    ensure_scripts_dir || return 1
    local tmp="$SHELL_LOADER.tmp.$$"

    # The two absolute paths are written separately so the heredoc below stays
    # unexpanded. %q output is valid in both bash and zsh.
    {
        echo "#!/bin/bash"
        echo "# olecharms-shell.sh — sources shell command files and user aliases"
        echo "$GENERATOR_STAMP $GENERATOR_VERSION"
        echo "_olecharms_alias_file=$(printf '%q' "$ALIAS_FILE")"
        echo "_olecharms_global_alias_file=$(printf '%q' "$GLOBAL_ALIAS_FILE")"
        echo "_olecharms_bin=$(printf '%q' "$SCRIPT_PATH")"
        echo "_olecharms_secrets=$(printf '%q' "$SECRETS_FILE")"
        echo "_olecharms_zsh_extras=$(printf '%q' "$(config_get zsh_extras on)")"
        echo "_olecharms_zsh_plugins=$(printf '%q' "$ZSH_EXTRAS_DIR")"
        cat <<'LOADER_EOF'
_olecharms_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source the shell command files with alias expansion off. Shells expand
# aliases when a function is *defined*, and this loader usually runs after
# oh-my-zsh, so e.g. common-aliases' cp='cp -i' would be baked into every
# function using cp (and an alias named like a function is a parse error in
# zsh). null_glob: an empty shell/ must not abort startup with "no matches".
# Variables are prefixed: the files run inside this function's scope.
_olecharms_source_dir() {
    local _olecharms_f _olecharms_ea=""
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt local_options null_glob no_aliases
    elif shopt -q expand_aliases 2>/dev/null; then
        shopt -u expand_aliases; _olecharms_ea=1
    fi
    for _olecharms_f in "$1"/*.sh; do
        [ -f "$_olecharms_f" ] && . "$_olecharms_f"
    done
    if [ -n "$_olecharms_ea" ]; then shopt -s expand_aliases; fi
    return 0
}
_olecharms_source_dir "${_olecharms_dir%/*}/shell"
unset -f _olecharms_source_dir
unset _olecharms_dir

# autojump: the package installs it but nothing activates it. Source the
# script for *this* shell (not $SHELL's) from the first install found — manual
# ~/.autojump, Debian/Ubuntu, Homebrew — unless something already defined `j`.
if ! command -v j >/dev/null 2>&1; then
    _olecharms_aj=""
    if [ -n "${ZSH_VERSION:-}" ]; then _olecharms_aj=zsh
    elif [ -n "${BASH_VERSION:-}" ]; then _olecharms_aj=bash
    fi
    if [ -n "$_olecharms_aj" ]; then
        for _olecharms_f in "$HOME/.autojump/share/autojump" /usr/share/autojump \
                            /opt/homebrew/share/autojump /usr/local/share/autojump; do
            if [ -f "$_olecharms_f/autojump.$_olecharms_aj" ]; then
                . "$_olecharms_f/autojump.$_olecharms_aj"
                break
            fi
        done
    fi
    unset _olecharms_aj _olecharms_f
fi

# Secrets (olecharms secret): API keys and tokens kept out of the RC files,
# in a file only you can read. Not loaded if someone else owns it.
if [ -f "$_olecharms_secrets" ] && [ -O "$_olecharms_secrets" ]; then
    . "$_olecharms_secrets"
fi

# Zsh extras (olecharms config → Zsh extras), interactive shells only: fzf's
# keys in bash and zsh (Ctrl-R history, Ctrl-T file paths, Alt-C folders),
# and in zsh, suggestions as you type plus syntax colours — that one last,
# as zsh-syntax-highlighting asks. Each is skipped if already loaded (e.g.
# by an oh-my-zsh plugin).
case $- in *i*) _olecharms_i=1 ;; *) _olecharms_i="" ;; esac
if [ "$_olecharms_zsh_extras" = on ] && [ -n "$_olecharms_i" ]; then
    _olecharms_sh=""
    if [ -n "${ZSH_VERSION:-}" ]; then _olecharms_sh=zsh
    elif [ -n "${BASH_VERSION:-}" ]; then _olecharms_sh=bash
    fi
    if [ -n "$_olecharms_sh" ] && command -v fzf >/dev/null 2>&1 &&
       ! type fzf-history-widget >/dev/null 2>&1 && ! type __fzf_history__ >/dev/null 2>&1; then
        # fzf >= 0.48 prints its own setup; older ones ship the scripts
        if _olecharms_f=$(fzf --$_olecharms_sh 2>/dev/null) && [ -n "$_olecharms_f" ]; then
            eval "$_olecharms_f"
        else
            for _olecharms_f in /usr/share/doc/fzf/examples /usr/share/fzf /usr/share/fzf/shell \
                                /opt/homebrew/opt/fzf/shell /usr/local/opt/fzf/shell "$HOME/.fzf/shell"; do
                if [ -f "$_olecharms_f/key-bindings.$_olecharms_sh" ]; then
                    . "$_olecharms_f/key-bindings.$_olecharms_sh"
                    [ -f "$_olecharms_f/completion.$_olecharms_sh" ] && . "$_olecharms_f/completion.$_olecharms_sh"
                    break
                fi
            done
        fi
    fi
    if [ "$_olecharms_sh" = zsh ]; then
        _olecharms_f="$_olecharms_zsh_plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
        if [ -f "$_olecharms_f" ] && ! type _zsh_autosuggest_start >/dev/null 2>&1; then
            # History alone is thin when history is not saved: completions too
            ZSH_AUTOSUGGEST_STRATEGY=(history completion)
            . "$_olecharms_f"
        fi
        _olecharms_f="$_olecharms_zsh_plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
        if [ -f "$_olecharms_f" ] && [ -z "${ZSH_HIGHLIGHT_VERSION:-}" ]; then
            . "$_olecharms_f"
        fi
    fi
    unset _olecharms_sh _olecharms_f
fi
unset _olecharms_i

# Drop the aliases loaded last time, then load the current set: global ones
# (in the repo, shared by every machine) first, so per-machine ones win. Run at
# shell start, and again by the wrapper below after alias changes and updates.
_olecharms_reload_aliases() {
    local _olecharms_n
    while IFS= read -r _olecharms_n; do
        [ -n "$_olecharms_n" ] && unalias "$_olecharms_n" 2>/dev/null
    done <<< "${_olecharms_loaded_aliases:-}"
    _olecharms_loaded_aliases=""
    # Alias files written by older versions defined these
    unset -f _olecharms_unload_aliases _olecharms_unload_global_aliases 2>/dev/null
    _olecharms_load_alias_file "$_olecharms_global_alias_file"
    _olecharms_load_alias_file "$_olecharms_alias_file"
    return 0
}

# Source alias file $1 and remember its names for the next reload
_olecharms_load_alias_file() {
    local _olecharms_l _olecharms_n
    [ -f "$1" ] || return 0
    . "$1"
    while IFS= read -r _olecharms_l; do
        case "$_olecharms_l" in
            "alias "*=*)
                _olecharms_n=${_olecharms_l#alias }
                _olecharms_loaded_aliases="$_olecharms_loaded_aliases${_olecharms_n%%=*}
"
                ;;
        esac
    done < "$1"
    return 0
}
_olecharms_reload_aliases

# What `olecharms aliaslast` needs from this shell and cannot see from a child
# process: the in-memory history (there may be no history file at all) and the
# names already taken here. zsh: exact entries from $history, NUL-separated,
# since `fc -l` prints a newline and a typed \n alike. The zsh-only syntax sits
# in eval strings so bash can still parse this file.
_olecharms_snapshot() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval 'local -a _k; _k=(${(onk)history}); (( ${#_k} > 300 )) && _k=(${_k[-300,-1]})
              local _i; for _i in $_k; do print -rN -- "${history[$_i]}"; done' > "$1/history.nul"
        alias -L > "$1/aliases" 2>/dev/null
        eval 'print -rl -- ${(k)functions}' > "$1/functions" 2>/dev/null
        eval 'print -rl -- ${(k)builtins} ${(k)reswords}' > "$1/builtins" 2>/dev/null
    else
        fc -l -300 > "$1/history.fc" 2>/dev/null
        alias -p > "$1/aliases" 2>/dev/null
        compgen -A function > "$1/functions" 2>/dev/null
        { compgen -b; compgen -k; } > "$1/builtins" 2>/dev/null
    fi
    return 0
}

# True if this shell has jobs. zsh's $(jobs) runs in a subshell that sees none.
_olecharms_has_jobs() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '(( ${#jobstates} > 0 ))'
    else
        [ -n "$(jobs -p 2>/dev/null)" ]
    fi
}

# A child process cannot change its parent shell, so wrap the command and act
# here: reload aliases after `olecharms alias`, and after a clean `install`
# replace this shell with a fresh login zsh — instead of the child nesting a
# new shell inside this one, where `exit` would drop back to the stale shell.
olecharms() {
    # The child bash cannot see this shell's aliases and functions (oh-my-zsh
    # defines hundreds), so tell `alias add` what the name means here.
    local _olecharms_what="" _olecharms_rc _olecharms_snap=""
    if [ "${1:-}" = alias ] && [ "${2:-}" = add ] && [ -n "${3:-}" ]; then
        _olecharms_what=$(type -- "$3" 2>/dev/null) || _olecharms_what=""
        _olecharms_what=${_olecharms_what%%$'\n'*}
    fi
    if [ "${1:-}" = aliaslast ]; then
        _olecharms_snap=$(mktemp -d "${TMPDIR:-/tmp}/olecharms.XXXXXX" 2>/dev/null) || _olecharms_snap=""
        [ -n "$_olecharms_snap" ] && _olecharms_snapshot "$_olecharms_snap"
    fi
    OLECHARMS_SHELL_WRAPPER=1 OLECHARMS_NAME_TYPE="$_olecharms_what" \
        OLECHARMS_SHELL_SNAPSHOT="$_olecharms_snap" "$_olecharms_bin" "$@"
    _olecharms_rc=$?
    [ -n "$_olecharms_snap" ] && rm -rf "$_olecharms_snap"
    case "${1:-}" in
        alias|aliaslast|update|sync|doctor) _olecharms_reload_aliases ;;
        secret)
            # Make the change visible in this shell too
            if [ $_olecharms_rc -eq 0 ]; then
                case "${2:-}" in
                    rm|remove|delete) [ -n "${3:-}" ] && unset "$3" 2>/dev/null ;;
                esac
                [ -f "$_olecharms_secrets" ] && [ -O "$_olecharms_secrets" ] && . "$_olecharms_secrets"
            fi
            ;;
        install)
            if [ $_olecharms_rc -eq 0 ] && [ -t 0 ] && [ -t 1 ] && command -v zsh >/dev/null 2>&1; then
                # exec would orphan stopped jobs (a suspended vim with unsaved
                # edits) out of reach of the new shell
                if _olecharms_has_jobs; then
                    echo "[!] This shell has stopped or background jobs; run 'exec zsh -l' once they are done."
                else
                    echo "[+] Reloading this shell as a login zsh..."
                    exec zsh -l
                fi
            fi
            ;;
    esac
    return $_olecharms_rc
}
LOADER_EOF
    } > "$tmp"
    commit_generated "$tmp" "$SHELL_LOADER"
}

install_shell_commands() {
    # Installed even with an empty shell/ dir: the loader also carries user
    # aliases and the `olecharms` wrapper, which must not depend on it.
    # Cheap and idempotent, and the loader lives in the gitignored scripts/ dir,
    # so regenerate unconditionally rather than only when an RC file changes.
    generate_shell_loader || return 1

    local rc_files=() rc
    while IFS= read -r rc; do rc_files+=("$rc"); done < <(managed_rc_files)

    for rc in "${rc_files[@]}"; do
        if grep -qF "$SHELL_MARKER" "$rc" 2>/dev/null; then
            if grep -qF "source \"$SHELL_LOADER\"" "$rc" 2>/dev/null; then
                loader_before_omz "$rc" || continue
                info "Moving the olecharms shell commands after oh-my-zsh in $rc"
            fi
            rc_strip_block "$rc" "$SHELL_MARKER" "olecharms-shell.sh" || return 1
        fi
        append_block "$rc" \
            "$SHELL_MARKER" \
            "[ -f \"$SHELL_LOADER\" ] && source \"$SHELL_LOADER\""
        info "Shell commands installed in $rc"
    done
}

# True if $1 sources the olecharms loader before oh-my-zsh.sh. oh-my-zsh
# defines its aliases (git plugin, common-aliases...) when it is sourced, so
# anything loaded earlier — including the user's olecharms aliases — loses.
loader_before_omz() {
    local rc="$1" loader omz
    loader=$(grep -nF "source \"$SHELL_LOADER\"" "$rc" 2>/dev/null | head -n 1 | cut -d: -f1)
    omz=$(grep -nE '^[[:space:]]*(source|\.)[[:space:]].*oh-my-zsh\.sh' "$rc" 2>/dev/null | head -n 1 | cut -d: -f1)
    [ -n "$loader" ] && [ -n "$omz" ] && [ "$loader" -lt "$omz" ]
}

remove_shell_commands() {
    local rc
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        [ ! -f "$rc" ] && continue
        if grep -qF "$SHELL_MARKER" "$rc" 2>/dev/null; then
            rc_strip_block "$rc" "$SHELL_MARKER" "olecharms-shell.sh" \
                && info "Shell commands removed from $rc"
        fi
    done
    rm -f "$SHELL_LOADER"
}

install_binary() {
    if ! mkdir -p "$BIN_DIR" 2>/dev/null; then
        error "Could not create $BIN_DIR"
        return 1
    fi
    # The launcher symlink and the shell wrapper execute the script directly
    if [ ! -x "$SCRIPT_PATH" ] && ! chmod +x "$SCRIPT_PATH" 2>/dev/null; then
        warn "$SCRIPT_PATH is not executable; run it as: bash $SCRIPT_PATH"
    fi

    if [ -L "$BIN_DIR/olecharms" ]; then
        local existing_target
        existing_target="$(readlink "$BIN_DIR/olecharms")"
        # readlink may return a relative path; resolve it against the link's dir
        case "$existing_target" in
            /*) ;;
            *)  existing_target="$BIN_DIR/$existing_target" ;;
        esac
        if [ -f "$existing_target" ] && [ "$existing_target" != "$SCRIPT_PATH" ]; then
            info "olecharms binary already linked to $existing_target (keeping existing)"
        else
            ln -sf "$SCRIPT_PATH" "$BIN_DIR/olecharms"
            info "Symlinked olecharms → $BIN_DIR/olecharms"
        fi
    else
        ln -sf "$SCRIPT_PATH" "$BIN_DIR/olecharms"
        info "Symlinked olecharms → $BIN_DIR/olecharms"
    fi

    # Check if ~/.local/bin is already on PATH
    if echo "$PATH" | tr ':' '\n' | grep -qxF -- "$BIN_DIR" 2>/dev/null; then
        return
    fi

    local rc_files=() rc
    while IFS= read -r rc; do rc_files+=("$rc"); done < <(managed_rc_files)

    for rc in "${rc_files[@]}"; do
        if grep -qF "$BIN_MARKER" "$rc" 2>/dev/null; then
            continue
        fi
        append_block "$rc" \
            "$BIN_MARKER" \
            "export PATH=\"\$HOME/.local/bin:\$PATH\""
        info "Added ~/.local/bin to PATH in $rc"
    done
}

install_editor_env() {
    local rc_files=() rc
    while IFS= read -r rc; do rc_files+=("$rc"); done < <(managed_rc_files)

    for rc in "${rc_files[@]}"; do
        if grep -qF "$EDITOR_MARKER" "$rc" 2>/dev/null; then
            continue
        fi
        append_block "$rc" \
            "$EDITOR_MARKER" \
            "export EDITOR=vim" \
            "export VISUAL=vim"
        info "Added EDITOR=vim to $rc"
    done
}

enable_downloads_cleanup() {
    local downloads_dir="$1"
    local mode="${2:-hook}"
    local max_age="${3:-$(config_get downloads_cleanup_max_age_days $DOWNLOADS_MAX_AGE_DAYS)}"

    if [ -z "$downloads_dir" ] || [ ! -d "$downloads_dir" ]; then
        error "Downloads directory not found: ${downloads_dir:-<empty>}"
        return 1
    fi
    if ! [[ "$max_age" =~ ^[0-9]+$ ]] || [ "$max_age" -lt 1 ]; then
        warn "Invalid max age '$max_age'; using $DOWNLOADS_MAX_AGE_DAYS days"
        max_age="$DOWNLOADS_MAX_AGE_DAYS"
    fi
    if [ "$mode" = "cron" ] && ! check_command crontab; then
        warn "crontab is not available; falling back to the shell hook"
        mode="hook"
    fi

    ensure_scripts_dir || return 1
    local tmp="$CLEANUP_SCRIPT.tmp.$$"

    # A thin launcher: folder, age and action are read from the config at run
    # time by `olecharms cleanup --scheduled`, which also logs, locks and can
    # send files to the trash. It finds the checkout relative to itself, so a
    # moved install keeps working until the next update rewrites the paths.
    cat > "$tmp" <<CLEANUP_EOF
#!/bin/bash
# Generated by olecharms — scheduled downloads cleanup. Settings live in
# $OLECHARMS_CONFIG_FILE; preview with 'olecharms cleanup --dry-run'.
$GENERATOR_STAMP $GENERATOR_VERSION
_olecharms_root="\$(cd "\$(dirname "\$0")/.." && pwd)" || exit 1
exec bash "\$_olecharms_root"/$(printf '%q' "$(basename "$SCRIPT_PATH")") cleanup --scheduled
CLEANUP_EOF
    commit_generated "$tmp" "$CLEANUP_SCRIPT" || return 1

    if [ "$mode" = "cron" ]; then
        local new_entry="$DOWNLOADS_CRON_MIN $DOWNLOADS_CRON_HOUR * * * $(cron_quote_path "$CLEANUP_SCRIPT") $CRON_MARKER_DOWNLOADS"
        cron_replace_entry "$CRON_MARKER_DOWNLOADS" "$new_entry" || return 1
        warn_if_no_cron_daemon
    elif is_downloads_cron_enabled; then
        cron_replace_entry "$CRON_MARKER_DOWNLOADS" "" || return 1
    fi
    sync_shell_hook

    # Sync to config file
    config_set downloads_cleanup_enabled true
    config_set downloads_cleanup_dir "$downloads_dir"
    config_set downloads_cleanup_method "$mode"
    config_set downloads_cleanup_max_age_days "$max_age"
}

disable_downloads_cleanup() {
    if ! is_downloads_cleanup_enabled; then
        warn "Downloads auto-cleanup is already disabled"
        return
    fi

    # Remove cron entry if present
    if is_downloads_cron_enabled; then
        cron_replace_entry "$CRON_MARKER_DOWNLOADS" ""
    fi

    rm -f "$CLEANUP_SCRIPT"
    rm -f "$LASTRUN_DIR/downloads-cleanup"
    rm -f "$CLEANUP_HELD"

    sync_shell_hook
    info "Downloads auto-cleanup disabled"

    # Sync to config file
    config_set downloads_cleanup_enabled false
    config_set downloads_cleanup_dir ""
    config_set downloads_cleanup_method hook
}

# True when paranoid mode also purges the Windows gVim's history: on WSL, with
# the Windows integration on and Windows reachable. Sets WIN_VIM_HOME. Not
# meant for $(...): win_env_load caches in this shell and costs ~1s.
paranoid_covers_windows() {
    [ -n "${IS_WSL:-}" ] || return 1
    [ "$(config_get windows_integration auto)" = "off" ] && return 1
    win_env_load && [ -n "${WIN_VIM_HOME:-}" ] && [ -d "$WIN_VIM_HOME" ]
}

# What each paranoid run deletes, as menu bullet lines
paranoid_print_targets() {
    echo "    - Shell history (~/.bash_history, ~/.zsh_history and the shell's own \$HISTFILE)"
    echo "    - Other histories: less, python, node, sqlite, psql, mysql, irb, redis-cli, wget HSTS"
    echo "    - Vim history: commands, searches, registers, marks (~/.viminfo)"
    echo "    - Vim undo files ($VIM_DIR/undodir/), and swap files ($VIM_DIR/swapfiles/)"
    echo "      when no vim is running — they are an open vim's crash recovery"
    if paranoid_covers_windows; then
        echo "    - Windows gVim: $WIN_VIM_HOME/_viminfo, vimfiles/undodir/, vimfiles/swapfiles/"
    fi
    echo "    - The downloads cleanup log, which lists every file it removed"
}

enable_paranoid_mode() {
    local mode="${1:-hook}"

    if [ "$mode" = "cron" ] && ! check_command crontab; then
        warn "crontab is not available; falling back to the shell hook"
        mode="hook"
    fi

    ensure_scripts_dir || return 1
    local tmp="$PARANOID_SCRIPT.tmp.$$"

    # Paths go in through %q so a quote or $ in them cannot break the script
    {
        cat <<PARANOID_EOF
#!/bin/bash
# Generated by olecharms — edit via 'olecharms config', not by hand.
$GENERATOR_STAMP $GENERATOR_VERSION
HOME_DIR=$(printf '%q' "$HOME")
VIM_DIR=$(printf '%q' "$VIM_DIR")
CLEANUP_LOG=$(printf '%q' "$CLEANUP_LOG")

# Delete the files directly in dir \$1 whose names match \$2 — only when it
# really is a folder of its own (a symlinked undodir pointing at home or /
# must not take them along), and only vim's own file names in it
purge_dir() {
    local real
    real=\$(cd -P "\$1" 2>/dev/null && pwd) || return 0
    case "\$HOME_DIR/" in "\$real"/*) return 0 ;; esac
    [ "\$real" = / ] && return 0
    find "\$real" -mindepth 1 -maxdepth 1 -type f -name "\$2" -delete 2>/dev/null
}
# Undo files are named after the full path ('%' for '/'); swap files end in
# .swp, .swo... (.s[a-w][a-z])
UNDO_NAMES='*%*'
SWAP_NAMES='*.s[a-w][a-z]'

# Purge shell history: the usual files, and the shell's own HISTFILE that the
# hook passes as \$1 — only a regular file inside home with a history-like name
rm -f "\$HOME_DIR/.bash_history" "\$HOME_DIR/.zsh_history" 2>/dev/null
if [ -n "\${1:-}" ] && [ -f "\$1" ] && [ ! -L "\$1" ]; then
    case "\$1" in
        "\$HOME_DIR"/*) case "\${1##*/}" in *[hH][iI][sS][tT]*) rm -f "\$1" ;; esac ;;
    esac
fi

# Other tools' histories: less, Python, Node, SQLite, PostgreSQL, MySQL, Ruby,
# Redis, and wget's record of HSTS hosts
for f in .lesshst .python_history .node_repl_history .sqlite_history .psql_history \
         .mysql_history .irb_history .rediscli_history .wget-hsts; do
    rm -f "\$HOME_DIR/\$f" 2>/dev/null
done

# The downloads cleanup log lists the path of every file it removed
rm -f "\$CLEANUP_LOG" 2>/dev/null

# Purge vim history (commands, searches, registers, marks) and undo files
rm -f "\$HOME_DIR/.viminfo" 2>/dev/null
purge_dir "\$VIM_DIR/undodir" "\$UNDO_NAMES"

# Swap files are a running vim's crash recovery and its "already being
# edited" guard, and vim never recreates a deleted one: leave them while any
# vim of this user runs (and when that cannot be told).
if command -v pgrep >/dev/null 2>&1 &&
   ! pgrep -u "\$(id -u)" -x 'g?vim|nvim|vi|view|gview|vimdiff|mvim' >/dev/null 2>&1; then
    purge_dir "\$VIM_DIR/swapfiles" "\$SWAP_NAMES"
fi
PARANOID_EOF
        # The Windows gVim keeps the same traces on the Windows side. Its home
        # is resolved now (PowerShell is too slow for every run) and baked in.
        if paranoid_covers_windows; then
            local tasklist
            tasklist=$(command -v tasklist.exe 2>/dev/null) || tasklist=/mnt/c/Windows/System32/tasklist.exe
            cat <<PARANOID_EOF

# Same for the Windows gVim (swap files only while no Windows vim runs)
WIN_VIM_HOME=$(printf '%q' "$WIN_VIM_HOME")
TASKLIST=$(printf '%q' "$tasklist")
if [ -d "\$WIN_VIM_HOME" ]; then
    rm -f "\$WIN_VIM_HOME/_viminfo" 2>/dev/null
    purge_dir "\$WIN_VIM_HOME/vimfiles/undodir" "\$UNDO_NAMES"
    if [ -x "\$TASKLIST" ] && running=\$("\$TASKLIST" /NH 2>/dev/null) && [ -n "\$running" ] &&
       ! printf '%s\\n' "\$running" | grep -qiE '^(g?vim|gvimd)\\.exe'; then
        purge_dir "\$WIN_VIM_HOME/vimfiles/swapfiles" "\$SWAP_NAMES"
    fi
fi
PARANOID_EOF
        fi
        echo "exit 0"
    } > "$tmp"
    commit_generated "$tmp" "$PARANOID_SCRIPT" || return 1

    if [ "$mode" = "cron" ]; then
        local new_entry="$PARANOID_CRON_SCHEDULE $(cron_quote_path "$PARANOID_SCRIPT") $CRON_MARKER_PARANOID"
        cron_replace_entry "$CRON_MARKER_PARANOID" "$new_entry" || return 1
        warn_if_no_cron_daemon
    elif is_paranoid_cron_enabled; then
        cron_replace_entry "$CRON_MARKER_PARANOID" "" || return 1
    fi
    sync_shell_hook

    # Sync to config file
    config_set paranoid_mode_enabled true
    config_set paranoid_mode_method "$mode"
}

disable_paranoid_mode() {
    if ! is_paranoid_mode_enabled; then
        warn "Paranoid mode is already disabled"
        return
    fi

    # Remove cron entry if present
    if is_paranoid_cron_enabled; then
        cron_replace_entry "$CRON_MARKER_PARANOID" ""
    fi

    rm -f "$PARANOID_SCRIPT"
    rm -f "$LASTRUN_DIR/paranoid-cleanup"

    sync_shell_hook
    info "Paranoid mode disabled"

    # Sync to config file
    config_set paranoid_mode_enabled false
    config_set paranoid_mode_method hook

    if is_downloads_cleanup_enabled; then
        info "Downloads auto-cleanup stays on ($(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS") days) — change it under 'Downloads auto-cleanup'"
    fi
}

# ─── Aliases ─────────────────────────────────────────────────────────────────

# Alias names have to be usable as a shell word.
alias_name_valid() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]
}

# Wrap a command in single quotes for `alias name=...`, escaping any it holds.
alias_quote() {
    local cmd="$1"
    cmd=${cmd//\'/\'\\\'\'}
    printf "'%s'" "$cmd"
}

# The alias functions below take an optional file: the per-machine
# $ALIAS_FILE by default, or $GLOBAL_ALIAS_FILE.

# Emit "name<TAB>command" for every stored alias. awk rather than sed: BSD/macOS
# sed has no \t in replacements. Plain POSIX awk, so mawk and BWK awk work too.
alias_list_raw() {
    local file="${1:-$ALIAS_FILE}"
    [ -f "$file" ] || return 0
    awk -v q="'" '
        index($0, "alias ") == 1 {
            line = substr($0, 7)
            eq = index(line, "=")
            if (eq < 2) next
            name = substr(line, 1, eq - 1)
            cmd = substr(line, eq + 1)
            # Command is single-quoted; embedded quotes are stored as q \ q q
            if (length(cmd) < 2 || substr(cmd, 1, 1) != q || substr(cmd, length(cmd), 1) != q) next
            cmd = substr(cmd, 2, length(cmd) - 2)
            esc = q "\\" q q
            out = ""
            while ((i = index(cmd, esc)) > 0) {
                out = out substr(cmd, 1, i - 1) q
                cmd = substr(cmd, i + length(esc))
            }
            printf "%s\t%s\n", name, out cmd
        }' "$file"
}

# Every stored alias except $1, compared exactly: a grep pattern would treat
# the "." allowed in names as a wildcard and drop "gas" along with "g.s".
alias_list_except() {
    alias_list_raw "${2:-}" | awk -F'\t' -v n="$1" '$1 != n'
}

alias_get() {
    local name="$1"
    alias_list_raw "${2:-}" | awk -F'\t' -v n="$name" '$1 == n { print substr($0, index($0, "\t") + 1); exit }'
}

alias_names() {
    alias_list_raw "${1:-}" | cut -f1
}

alias_count() {
    alias_list_raw "${1:-}" | grep -c . || true
}

# Rewrite alias file $1 (default: per-machine) from "name<TAB>command" lines
# on stdin.
alias_write_all() {
    local file="${1:-$ALIAS_FILE}" tmpfile status
    local header="# Sourced by scripts/olecharms-shell.sh from your shell rc files."
    if [ "$file" = "$GLOBAL_ALIAS_FILE" ]; then
        header="# Global: in git, loaded on every machine with olecharms (before the per-machine ones)."
    fi
    mkdir -p "$(dirname "$file")" || { error "Could not create $(dirname "$file")"; return 1; }
    tmpfile=$(mktemp) || { error "mktemp failed"; return 1; }

    {
        echo "$ALIAS_MARKER"
        echo "$header"
        # One alias per line and nothing else: the loader reads the names back
        # to unalias them on reload, and global-aliases.sh stays mergeable.
        local name cmd
        while IFS=$'\t' read -r name cmd; do
            [ -n "$name" ] || continue
            echo "alias ${name}=$(alias_quote "$cmd")"
        done
    } > "$tmpfile"

    write_file_contents "$tmpfile" "$file"
    status=$?
    rm -f "$tmpfile"
    return $status
}

alias_set() {
    local name="$1" cmd="$2" file="${3:-}"
    { alias_list_except "$name" "$file"; printf '%s\t%s\n' "$name" "$cmd"; } \
        | sort -f | alias_write_all "$file"
}

alias_unset() {
    alias_list_except "$1" "${2:-}" | alias_write_all "${2:-}"
}

# Ask before changing anything, defaulting to no (Enter and EOF decline).
confirm_default_no() {
    local prompt="$1" answer
    if [ -t 0 ]; then
        read -rp "$prompt [y/N] " answer || return 1
    else
        read -r answer || return 1
    fi
    case "$answer" in
        [yY]|[yY][eE][sS]|[sS]|[sS][iI]|[sS]í) return 0 ;;
        *)                                    return 1 ;;
    esac
}

# Ask before changing anything. Enter means yes, and so does EOF — but a piped
# answer is still honoured, so `echo n | olecharms ...` declines.
confirm_default_yes() {
    local prompt="$1" answer
    if [ -t 0 ]; then
        read -rp "$prompt [Y/n] " answer || return 0
    else
        read -r answer || return 0
    fi
    case "$answer" in
        [nN]|[nN][oO]) return 1 ;;
        *)             return 0 ;;
    esac
}

# ─── aliaslast: history, picker, name checks ─────────────────────────────────

# Recent commands for `aliaslast`, oldest first, one per line: distinct
# single-line entries (an alias holds one line), latest occurrence kept. From
# the snapshot the shell wrapper hands over; without one (script run
# directly), from the history file as a best effort.
aliaslast_history() {
    local snap="${OLECHARMS_SHELL_SNAPSHOT:-}" hist soh
    soh=$(printf '\001')
    {
        if [ -n "$snap" ] && [ -f "$snap/history.nul" ]; then
            # zsh, exact entries: a newline inside one becomes \001 (dropped below)
            tr '\012\000' '\001\012' < "$snap/history.nul"
        elif [ -n "$snap" ] && [ -f "$snap/history.fc" ]; then
            # bash `fc -l`: "N<TAB> cmd"; unnumbered lines continue a multi-line entry
            awk '
                /^[0-9]+[*]?\t/ {
                    if (have && !multi) print cur
                    cur = $0; sub(/^[0-9]+[*]?\t ?/, "", cur); have = 1; multi = 0; next
                }
                { multi = 1 }
                END { if (have && !multi) print cur }' "$snap/history.fc"
        else
            hist="${HISTFILE:-}"
            if [ -z "$hist" ]; then
                case "$(login_shell)" in
                    *zsh) hist="$HOME/.zsh_history" ;;
                    *)    hist="$HOME/.bash_history" ;;
                esac
            fi
            # zsh ": <time>:<secs>;cmd" lines, bash "#<time>" lines; a trailing
            # backslash continues a multi-line entry
            [ -f "$hist" ] && tail -n 3000 "$hist" | awk '
                cont { if ($0 !~ /\\$/) cont = 0; next }
                /^#[0-9]+$/ { next }
                { line = $0; sub(/^: [0-9]+:[0-9]+;/, "", line) }
                line ~ /\\$/ { cont = 1; next }
                { print line }'
        fi
    } | awk -v soh="$soh" '
        index($0, soh) || index($0, "\t") { next }
        { sub(/[ ]+$/, "") }
        !NF { next }
        /^[ ]*([^ ]*\/)?olecharms(\.sh)?[ ]+aliaslast([ ]|$)/ { next }
        { line[++n] = $0 }
        END {
            for (i = n; i >= 1 && kept < 300; i--)
                if (!(line[i] in seen)) { seen[line[i]] = 1; out[++kept] = line[i] }
            for (i = kept; i >= 1; i--) print out[i]
        }'
}

# Pick one of the PICK_ITEMS array with the arrow keys, cursor starting on the
# last item; sets PICK_INDEX, returns 1 if cancelled. ↑↓ / j k, PgUp PgDn,
# Home End, Enter selects, q or Esc cancels. Without a terminal it falls back
# to a numbered prompt whose default is the last item.
pick_item() {
    local n=${#PICK_ITEMS[@]} sel top h rows cols i line key rest drawn=""
    [ "$n" -gt 0 ] || return 1
    sel=$((n - 1))

    # fzf, when installed: the same list, newest at the cursor, and typing
    # filters it
    if [ -t 0 ] && [ -t 2 ] && [ -z "${OLECHARMS_NO_FZF:-}" ] && check_command fzf; then
        local picked
        picked=$(for ((i = n - 1; i >= 0; i--)); do printf '%d\t%s\0' "$i" "${PICK_ITEMS[$i]}"; done |
            fzf --read0 --delimiter="$(printf '\t')" --with-nth=2.. --no-sort --height=40% \
                --prompt='> ' --header='type to filter · ↑↓ move · Enter select · Esc cancel') || return 1
        picked=${picked%%$'\t'*}
        [[ "$picked" =~ ^[0-9]+$ ]] && [ "$picked" -lt "$n" ] || return 1
        PICK_INDEX=$picked
        return 0
    fi

    if [ ! -t 0 ] || [ ! -t 2 ]; then
        for i in "${!PICK_ITEMS[@]}"; do
            printf '  %3d) %s\n' $((i + 1)) "${PICK_ITEMS[$i]}" >&2
        done
        printf '  Select [%d]: ' "$n" >&2
        read -r key || return 1
        [ -z "$key" ] && key=$n
        [[ "$key" =~ ^[0-9]+$ ]] && [ "$key" -ge 1 ] && [ "$key" -le "$n" ] || return 1
        PICK_INDEX=$((key - 1))
        return 0
    fi

    set -- $(stty size 2>/dev/null)
    rows=${1:-0} cols=${2:-0}
    # Some ptys report 0 0
    [[ "$rows" =~ ^[0-9]+$ ]] && [ "$rows" -gt 0 ] || rows=24
    [[ "$cols" =~ ^[0-9]+$ ]] && [ "$cols" -ge 20 ] || cols=80
    h=$((rows - 8))
    [ "$h" -gt 15 ] && h=15
    [ "$h" -lt 3 ] && h=3
    [ "$h" -gt "$n" ] && h=$n
    top=$((n - h))

    local old_traps status
    old_traps=$(trap -p INT TERM)
    status="· ↑↓ move · Enter select · q cancel"
    [ "$cols" -lt 60 ] && status=""
    printf '\033[?25l' >&2
    trap 'printf "\033[?25h\n" >&2; exit 130' INT TERM
    while :; do
        [ "$sel" -lt "$top" ] && top=$sel
        [ "$sel" -ge $((top + h)) ] && top=$((sel - h + 1))
        [ -n "$drawn" ] && printf '\033[%dA' $((h + 1)) >&2
        drawn=1
        for ((i = top; i < top + h; i++)); do
            line=${PICK_ITEMS[$i]}
            [ ${#line} -gt $((cols - 6)) ] && line="${line:0:$((cols - 7))}…"
            if [ "$i" -eq "$sel" ]; then
                printf '\r\033[2K  \033[7m> %s\033[0m\n' "$line" >&2
            else
                printf '\r\033[2K    %s\n' "$line" >&2
            fi
        done
        printf '\r\033[2K  \033[2m%d/%d %s\033[0m\n' $((sel + 1)) "$n" "$status" >&2

        key=""
        IFS= read -rsn1 key || key=q
        case "$key" in
            $'\033')
                rest=""
                IFS= read -rsn2 -t 1 rest
                case "$rest" in
                    '[A'|'OA') key=up ;;
                    '[B'|'OB') key=down ;;
                    '[H'|'OH') key=home ;;
                    '[F'|'OF') key=end ;;
                    '[5') IFS= read -rsn1 -t 1 rest; key=pgup ;;
                    '[6') IFS= read -rsn1 -t 1 rest; key=pgdn ;;
                    '')   key=q ;;
                    *)    key="" ;;
                esac
                ;;
            k) key=up ;;
            j) key=down ;;
            '') key=enter ;;
        esac
        case "$key" in
            up)    [ "$sel" -gt 0 ] && sel=$((sel - 1)) ;;
            down)  [ "$sel" -lt $((n - 1)) ] && sel=$((sel + 1)) ;;
            pgup)  sel=$((sel - h)); [ "$sel" -lt 0 ] && sel=0 ;;
            pgdn)  sel=$((sel + h)); [ "$sel" -gt $((n - 1)) ] && sel=$((n - 1)) ;;
            home)  sel=0 ;;
            end)   sel=$((n - 1)) ;;
            enter|q|Q) break ;;
        esac
    done
    # Wipe the list; the caller prints the choice
    printf '\033[%dA\r\033[J\033[?25h' $((h + 1)) >&2
    trap - INT TERM
    eval "$old_traps"
    case "$key" in q|Q) return 1 ;; esac
    PICK_INDEX=$sel
    return 0
}

# Remove the wrapper's snapshot dir $1 — only the files it writes, then the
# (by then empty) dir: the path comes from the environment, never rm -rf it.
snapshot_remove() {
    local d="$1"
    [ -d "$d" ] && [ ! -L "$d" ] || return 0
    rm -f "$d/history.nul" "$d/history.fc" "$d/aliases" "$d/functions" "$d/builtins"
    rmdir "$d" 2>/dev/null
    return 0
}

# Value of alias $1 in the user's shell, from the wrapper's snapshot (zsh
# `alias -L` / bash `alias -p` lines). Fails if it has none.
snapshot_alias_value() {
    local snap="${OLECHARMS_SHELL_SNAPSHOT:-}"
    [ -n "$snap" ] && [ -f "$snap/aliases" ] || return 1
    awk -v n="$1" -v q="'" '
        {
            line = $0
            sub(/^alias +/, "", line)
            while (line ~ /^-[a-zA-Z-]* +/) sub(/^-[a-zA-Z-]* +/, "", line)
            eq = index(line, "=")
            if (eq < 2 || substr(line, 1, eq - 1) != n) next
            v = substr(line, eq + 1)
            if (length(v) >= 2 && substr(v, 1, 1) == q && substr(v, length(v), 1) == q) {
                v = substr(v, 2, length(v) - 2)
                gsub(q "\\\\" q q, q, v)
            }
            print v; found = 1; exit
        }
        END { exit !found }' "$snap/aliases"
}

# Say what name $1 already means and return 0 if it is taken: an olecharms
# alias (this machine or global); from the wrapper's snapshot of the user's
# shell, an alias (oh-my-zsh, rc files), a function or a builtin; or a command
# on PATH.
alias_conflicts() {
    local name="$1" snap="${OLECHARMS_SHELL_SNAPSHOT:-}" v taken=1 ours="" kind=""
    if v=$(alias_get "$name") && [ -n "$v" ]; then
        warn "  '$name' is already one of your aliases on this machine: $v"
        taken=0 ours=1
    fi
    if v=$(alias_get "$name" "$GLOBAL_ALIAS_FILE") && [ -n "$v" ]; then
        warn "  '$name' is already a global alias: $v"
        taken=0 ours=1
    fi
    if [ -z "$ours" ] && v=$(snapshot_alias_value "$name"); then
        warn "  '$name' is already an alias in your shell (oh-my-zsh or your rc files): $v"
        taken=0
    fi
    if [ -n "$snap" ] && grep -qxF -- "$name" "$snap/functions" 2>/dev/null; then
        warn "  '$name' is a shell function"
        taken=0
    fi
    if [ -n "$snap" ]; then
        grep -qxF -- "$name" "$snap/builtins" 2>/dev/null && kind=builtin
    else
        kind=$(type -t "$name" 2>/dev/null)
    fi
    case "$kind" in
        builtin|keyword) warn "  '$name' is a shell builtin or keyword"; taken=0 ;;
    esac
    if v=$(type -P "$name" 2>/dev/null) && [ -n "$v" ]; then
        warn "  '$name' is a command: $v"
        taken=0
    fi
    return $taken
}

# ─── Global aliases: publish through git ────────────────────────────────────

# True when the GitHub CLI is signed in (it can then act as git's credentials)
gh_logged_in() {
    check_command gh && gh auth status -h github.com >/dev/null 2>&1
}

# Extra git options for pushes; set by global_push_access to borrow gh's
# login when git's own credentials do not work (for this run only)
GLOBAL_PUSH_OPTS=()

# "remote/branch" the checkout's branch tracks: where global aliases go, and
# what every other machine pulls on update.
global_alias_upstream() {
    git -C "$SCRIPT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null
}

# GitHub "owner/repo" from remote URL $1, if it is a GitHub one
github_slug() {
    local slug
    case "$1" in
        https://github.com/*)   slug=${1#https://github.com/} ;;
        git@github.com:*)       slug=${1#git@github.com:} ;;
        ssh://git@github.com/*) slug=${1#ssh://git@github.com/} ;;
        *) return 1 ;;
    esac
    slug=${slug%/}
    printf '%s\n' "${slug%.git}"
}

# How to let this machine push to remote URL $1 (remote name $2)
global_push_help() {
    local url="$1" remote="$2" slug key found="" ssh_url="<ssh url>"
    slug=$(github_slug "$url") || slug=""
    [ -n "$slug" ] && ssh_url="git@github.com:$slug.git"
    case "$url" in
        http://*|https://*)
            echo "  Git has no credentials here that can push over HTTPS. Either:"
            if check_command gh; then
                echo "    - let gh provide them: gh auth login (if needed) && gh auth setup-git"
            else
                echo "    - sign in with write access, e.g. install the GitHub CLI, then: gh auth login && gh auth setup-git"
            fi
            echo "    - or push over SSH (pulls stay as they are):"
            echo "        git -C \"$SCRIPT_DIR\" remote set-url --push $remote $ssh_url"
            echo "      and give this machine's SSH key write access:"
            ;;
        *)
            echo "  Give this machine's SSH key write access to the repository:"
            ;;
    esac
    for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
        [ -f "$key" ] || continue
        found=1
        echo "      $key:"
        echo "        $(cat "$key")"
    done
    [ -n "$found" ] || echo "      (no SSH key yet — create one with: ssh-keygen -t ed25519)"
    if [ -n "$slug" ]; then
        echo "      Add it at https://github.com/settings/keys (all your repositories), or as a"
        echo "      deploy key with \"Allow write access\" at https://github.com/$slug/settings/keys"
    fi
}

# Wait until this machine can push to branch $2 of remote $1. The test is a
# dry run pushing the remote's own commit back — always a fast-forward, so
# only access can make it fail. While it fails, explain how to grant access
# and wait for the user. Returns 1 if they give up.
global_push_access() {
    local remote="$1" branch="$2" url tip err answer
    url=$(git -C "$SCRIPT_DIR" remote get-url --push "$remote" 2>/dev/null) || url="$remote"
    tip=$(git -C "$SCRIPT_DIR" rev-parse "$remote/$branch" 2>/dev/null) || return 1
    info "Checking that this machine can push to $url..."
    GLOBAL_PUSH_OPTS=()
    while ! err=$(_git_net ${GLOBAL_PUSH_OPTS[@]+"${GLOBAL_PUSH_OPTS[@]}"} -C "$SCRIPT_DIR" push --dry-run -q "$remote" "$tip:refs/heads/$branch" 2>&1); do
        # git's own credentials failed: a signed-in gh can stand in, for this
        # run only (nothing in the git config changes)
        if [ ${#GLOBAL_PUSH_OPTS[@]} -eq 0 ] && github_slug "$url" >/dev/null && gh_logged_in; then
            GLOBAL_PUSH_OPTS=(-c credential.helper= -c "credential.helper=!\"$(command -v gh)\" auth git-credential")
            if _git_net "${GLOBAL_PUSH_OPTS[@]}" -C "$SCRIPT_DIR" push --dry-run -q "$remote" "$tip:refs/heads/$branch" >/dev/null 2>&1; then
                info "git's own credentials did not work; pushing with your gh login instead"
                return 0
            fi
            GLOBAL_PUSH_OPTS=()
        fi
        echo ""
        warn "This machine cannot push to $url"
        printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 3 | sed 's/^/      /'
        echo ""
        global_push_help "$url" "$remote"
        echo ""
        if [ -t 0 ]; then
            read -rp "  Press Enter to try again once that is done, or 'l' to keep the alias on this machine only: " answer || return 1
        else
            read -r answer || return 1
        fi
        case "$answer" in [lLqQnN]*) return 1 ;; esac
        info "Checking again..."
    done
    return 0
}

# Run "$@" — an alias_set/alias_unset on $GLOBAL_ALIAS_FILE — on top of the
# latest remote state, then commit just that file (message $1) and push it.
# Returns 1 when nothing changed (nowhere to publish, no access, user gave
# up), 2 when the change is here but could not be committed or pushed.
global_alias_publish() {
    local msg="$1"; shift
    local upstream remote branch ahead try
    if ! upstream=$(global_alias_upstream); then
        error "$SCRIPT_DIR is not on a branch that tracks a remote one: nowhere to publish to"
        return 1
    fi
    remote=${upstream%%/*}
    branch=${upstream#*/}
    if [ -z "$(git -C "$SCRIPT_DIR" config user.email 2>/dev/null)" ]; then
        error "git has no identity on this machine; set it with:"
        echo "    git config --global user.name \"Your Name\"; git config --global user.email you@example.com"
        return 1
    fi
    info "Updating $SCRIPT_DIR from $upstream..."
    checkout_pull
    case $? in
        1) return 1 ;;
        2) error "Could not update the checkout from $upstream${CHECKOUT_PULL_ERR:+: $CHECKOUT_PULL_ERR}"; return 1 ;;
    esac
    global_push_access "$remote" "$branch" || return 1
    ahead=$(git -C "$SCRIPT_DIR" rev-list --count "$upstream..HEAD" 2>/dev/null) || ahead=0
    if [ "$ahead" -gt 0 ]; then
        warn "$branch has $ahead local commit(s) not on $upstream yet; publishing pushes them too"
        confirm_default_no "  Push them along with the alias?" || return 1
    fi

    "$@" || return 1
    global_alias_commit "$msg" || return 2
    for try in 1 2 3; do
        _git_net ${GLOBAL_PUSH_OPTS[@]+"${GLOBAL_PUSH_OPTS[@]}"} -C "$SCRIPT_DIR" push -q "$remote" "HEAD:refs/heads/$branch" && return 0
        [ "$try" -lt 3 ] || break
        # Rejected: most likely another machine pushed meanwhile. Redo the
        # change on top of the new remote state instead of rebasing — two
        # edits to the alias file can conflict textually even when they touch
        # different aliases. Only when our commit is the sole one ahead;
        # otherwise rebase (aborted cleanly on a conflict).
        _git_net -C "$SCRIPT_DIR" fetch -q "$remote" || break
        if [ "$ahead" -eq 0 ] && git -C "$SCRIPT_DIR" reset -q --keep "$upstream" 2>/dev/null; then
            "$@" && global_alias_commit "$msg" || return 2
        else
            checkout_pull || break
        fi
    done
    error "Committed but not pushed; push later with: git -C \"$SCRIPT_DIR\" push"
    return 2
}

# Commit just the published file: the global alias file, or the one a
# caller names in GLOBAL_PUBLISH_FILE (shared settings)
global_alias_commit() {
    local file="${GLOBAL_PUBLISH_FILE:-$GLOBAL_ALIAS_FILE}"
    if ! git -C "$SCRIPT_DIR" add -- "$file"; then
        error "Could not commit $file; the change is only on this machine"
        return 1
    fi
    # Same content as already committed (e.g. sharing unchanged settings)
    git -C "$SCRIPT_DIR" diff --cached --quiet HEAD -- "$file" 2>/dev/null && return 0
    if ! git -C "$SCRIPT_DIR" commit -q -m "$1" -- "$file"; then
        error "Could not commit $file; the change is only on this machine"
        return 1
    fi
}

# Make alias $1=$2 global. A per-machine alias of the same name is dropped,
# as it would shadow the global one here. Returns as global_alias_publish.
alias_save_global() {
    local name="$1" cmd="$2" verb=Add rc
    [ -n "$(alias_get "$name" "$GLOBAL_ALIAS_FILE")" ] && verb=Update
    global_alias_publish "$verb global alias $name" alias_set "$name" "$cmd" "$GLOBAL_ALIAS_FILE"
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ -n "$(alias_get "$name")" ] && alias_unset "$name"
    if [ "$rc" -eq 0 ]; then
        info "Alias '$name' is global: every machine gets it with its next 'olecharms update'"
    fi
    alias_activation_note
    return "$rc"
}

# ─── Shared settings: the same preferences on every machine ─────────────────
# shared-config in the checkout holds the settings you chose to share; it
# travels like global-aliases.sh (committed, pushed, pulled by every machine).
# A machine never applies them on its own: settings that delete things show
# their preview and ask, exactly as in `olecharms config`. New machines are
# offered them at install; others after a sync/update brings a change, and
# `olecharms doctor` lists differences. A setting can be kept different on
# one machine (shared_keep_local), and is then left out of the comparison.

# Shareable keys, in the order they are applied (age and action before
# enabling the cleanup, whose preview uses them). Folders, scheduling method
# and Windows integration stay per machine.
SHARED_KEYS="downloads_cleanup_max_age_days downloads_cleanup_action downloads_cleanup_quarantine_days downloads_cleanup_enabled paranoid_mode_enabled daily_doctor zsh_extras"

# Value of key $1 in the shared file ("" when unset or no file)
shared_get() {
    [ -f "$SHARED_CONFIG_FILE" ] || return 0
    sed -n "s/^$1=//p" "$SHARED_CONFIG_FILE" | tail -n 1
}

# This machine's value for shareable key $1, defaults filled in
shared_local_value() {
    case "$1" in
        downloads_cleanup_enabled)         config_get downloads_cleanup_enabled false ;;
        downloads_cleanup_max_age_days)    config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS" ;;
        downloads_cleanup_action)          config_get downloads_cleanup_action auto ;;
        downloads_cleanup_quarantine_days) config_get downloads_cleanup_quarantine_days "$CLEANUP_QUARANTINE_DAYS" ;;
        paranoid_mode_enabled)             config_get paranoid_mode_enabled false ;;
        daily_doctor)                      config_get daily_doctor on ;;
        zsh_extras)                        config_get zsh_extras on ;;
    esac
}

# Human wording of key $1 with value $2
shared_describe() {
    case "$1=$2" in
        downloads_cleanup_enabled=true)  echo "downloads auto-cleanup on" ;;
        downloads_cleanup_enabled=*)     echo "downloads auto-cleanup off" ;;
        downloads_cleanup_max_age_days=*) echo "downloads kept $2 days" ;;
        downloads_cleanup_action=*)      echo "cleanup action $2" ;;
        downloads_cleanup_quarantine_days=*) echo "quarantine kept $2 days" ;;
        paranoid_mode_enabled=true)      echo "paranoid mode on" ;;
        paranoid_mode_enabled=*)         echo "paranoid mode off" ;;
        daily_doctor=on)                 echo "daily health check on" ;;
        daily_doctor=*)                  echo "daily health check off" ;;
        zsh_extras=on)                   echo "zsh extras on" ;;
        zsh_extras=*)                    echo "zsh extras off" ;;
        *)                               echo "$1=$2" ;;
    esac
}

shared_kept_local() {
    case " $(config_get shared_keep_local "") " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Shareable keys where this machine differs from the shared file (and has
# not chosen to differ), one per line. The age and action of a cleanup that
# is off on both sides make no difference and are not listed.
shared_differences() {
    local key want have
    [ -f "$SHARED_CONFIG_FILE" ] || return 0
    for key in $SHARED_KEYS; do
        want=$(shared_get "$key")
        [ -n "$want" ] || continue
        shared_kept_local "$key" && continue
        have=$(shared_local_value "$key")
        [ "$want" = "$have" ] && continue
        case "$key" in
            downloads_cleanup_max_age_days|downloads_cleanup_action|downloads_cleanup_quarantine_days)
                [ "$(shared_get downloads_cleanup_enabled)" != true ] &&
                    [ "$(shared_local_value downloads_cleanup_enabled)" != true ] && continue ;;
        esac
        echo "$key"
    done
}

# One line: "here X → shared Y; ..." for the doctor and notices
shared_differences_summary() {
    local key out=""
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        out="$out${out:+; }$(shared_describe "$key" "$(shared_local_value "$key")") here, $(shared_describe "$key" "$(shared_get "$key")") shared"
    done <<< "$(shared_differences)"
    printf '%s\n' "$out"
}

# The shared file from this machine's values
shared_write() {
    local key tmp
    tmp=$(mktemp) || return 1
    {
        echo "# olecharms shared settings — written by 'olecharms config' → Shared settings."
        echo "# Every machine is offered these (it asks before anything that deletes files)."
        for key in $SHARED_KEYS; do
            printf '%s=%s\n' "$key" "$(shared_local_value "$key")"
        done
    } > "$tmp"
    mv "$tmp" "$SHARED_CONFIG_FILE"
}

# Publish this machine's settings for every machine
shared_publish() {
    local GLOBAL_PUBLISH_FILE="$SHARED_CONFIG_FILE" key rc
    echo "  These settings of this machine will be shared:"
    for key in $SHARED_KEYS; do
        echo "    - $(shared_describe "$key" "$(shared_local_value "$key")")"
    done
    echo "  (folders, scheduling and Windows integration stay per machine)"
    echo ""
    confirm_default_yes "  Share them with all your machines?" || { info "Not shared"; return 0; }
    global_alias_publish "Update shared settings" shared_write
    rc=$?
    case "$rc" in
        0) info "Shared: your other machines are offered these settings after their next update"
           shared_mark_seen ;;
        2) warn "Saved in $SHARED_CONFIG_FILE but not published yet" ;;
    esac
    return "$rc"
}

shared_fingerprint() {
    [ -f "$SHARED_CONFIG_FILE" ] && cksum < "$SHARED_CONFIG_FILE" | cut -d' ' -f1
}

shared_mark_seen() {
    mkdir -p "$OLECHARMS_STATE_DIR" 2>/dev/null
    shared_fingerprint > "$SHARED_SEEN_FILE" 2>/dev/null
}

# Go through the differences and ask about each one, applying it the way
# `olecharms config` does (with previews for anything that deletes files)
shared_apply() {
    local key want have answer changed=""
    if [ -z "$(shared_differences)" ]; then
        info "This machine already follows your shared settings"
        shared_mark_seen
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "  Your shared settings differ here: $(shared_differences_summary)"
        echo "  Apply them in a terminal: olecharms config → Shared settings"
        return 0
    fi
    # A plain list, not a loop reading a pipe: the steps below ask on stdin
    for key in $(shared_differences); do
        want=$(shared_get "$key")
        have=$(shared_local_value "$key")
        echo ""
        echo -e "  ${BOLD}$(shared_describe "$key" "$want")${NC} (shared)  —  here: $(shared_describe "$key" "$have")"
        read -rp "  Apply here? [y]es / [n]ot now / [k]eep this machine different: " answer || answer=n
        case "$answer" in
            [yYsS]*) ;;
            [kK]*)
                config_set shared_keep_local "$(config_get shared_keep_local "") $key"
                info "Kept as it is on this machine (olecharms config → Shared settings to follow them again)"
                continue ;;
            *) info "Left as it is for now"; continue ;;
        esac
        case "$key" in
            downloads_cleanup_max_age_days)
                if is_downloads_cleanup_enabled; then
                    config_cleanup_age "$want"
                else
                    config_set "$key" "$want"
                fi ;;
            downloads_cleanup_action)
                if [ "$want" = trash ] && ! cleanup_trash_backend "$(cleanup_real_dir "$(config_get downloads_cleanup_dir)" 2>/dev/null)" >/dev/null 2>&1 &&
                   is_downloads_cleanup_enabled; then
                    warn "No trash for the downloads folder here; keeping '$have'"
                    continue
                fi
                config_set "$key" "$want"
                info "Cleanup action: $want" ;;
            downloads_cleanup_quarantine_days)
                config_set "$key" "$want"
                info "Quarantine kept $want days" ;;
            downloads_cleanup_enabled)
                if [ "$want" = true ]; then
                    config_downloads_cleanup
                else
                    disable_downloads_cleanup
                fi ;;
            paranoid_mode_enabled)
                if [ "$want" = true ]; then
                    config_paranoid_mode
                else
                    disable_paranoid_mode
                fi ;;
            daily_doctor)
                config_set daily_doctor "$want"
                generate_doctor_launcher
                sync_shell_hook
                info "Daily health check $want" ;;
            zsh_extras)
                config_set zsh_extras "$want"
                [ "$want" = on ] && install_zsh_extras
                install_shell_commands >/dev/null
                info "Zsh extras $want (new shells)" ;;
        esac
        changed=1
    done
    shared_mark_seen
    [ -n "$changed" ] && info "Done. 'olecharms doctor' shows how this machine stands."
    return 0
}

# After a sync or update: offer the shared settings when they changed since
# this machine last looked (a terminal is needed to ask)
shared_offer_after_pull() {
    [ -f "$SHARED_CONFIG_FILE" ] || return 0
    [ "$(cat "$SHARED_SEEN_FILE" 2>/dev/null)" = "$(shared_fingerprint)" ] && return 0
    if [ -z "$(shared_differences)" ]; then
        shared_mark_seen
        return 0
    fi
    echo ""
    info "Your shared settings (from your other machines) differ here: $(shared_differences_summary)"
    if [ -t 0 ] && [ -t 1 ]; then
        shared_apply
    else
        echo "  Apply them with: olecharms config → Shared settings"
    fi
}

config_shared_settings() {
    local diffs choice key kept
    diffs=$(shared_differences)
    kept=$(config_get shared_keep_local "")
    if [ ! -f "$SHARED_CONFIG_FILE" ]; then
        echo "  Nothing shared yet: your machines each keep their own settings."
    elif [ -z "$diffs" ]; then
        echo -e "  This machine ${GREEN}follows${NC} your shared settings."
    else
        echo -e "  This machine ${YELLOW}differs${NC}: $(shared_differences_summary)"
    fi
    [ -n "${kept// /}" ] && echo "  Kept different here on purpose: $(for key in $kept; do shared_describe "$key" "$(shared_local_value "$key")"; done | paste -sd, - | sed 's/,/, /g')"
    echo ""
    echo "    1) Share this machine's settings with all machines"
    [ -n "$diffs" ] && echo "    2) Apply the shared settings here"
    [ -n "${kept// /}" ] && echo "    3) Follow the shared settings again for the ones kept different"
    echo ""
    echo "    0) Back"
    echo ""
    read -rp "  Select: " choice
    case "$choice" in
        1) echo ""; shared_publish ;;
        2) [ -n "$diffs" ] && shared_apply ;;
        3)
            if [ -n "${kept// /}" ]; then
                config_set shared_keep_local ""
                info "Following all shared settings again"
                shared_apply
            fi ;;
        *) info "No changes made" ;;
    esac
}

# ─── Downloads Cleanup Engine ───────────────────────────────────────────────
# One implementation behind `olecharms cleanup`, its --dry-run, the config
# menu preview and the scheduled runs (the generated scripts/cleanup-downloads.sh
# only calls `olecharms cleanup --scheduled`).

# Resolve the folder to clean to its real path, refusing anything that is — or
# leads to — $HOME or /. Prints the real path.
cleanup_real_dir() {
    local dir="$1" real home_real p rest
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    real=$(cd -P "$dir" 2>/dev/null && pwd) || return 1
    real=${real%/}
    [ -n "$real" ] || return 1
    home_real=$(cd -P "$HOME" 2>/dev/null && pwd)
    # Never a folder that holds the home folder, the olecharms checkout or its
    # config — the folder itself or any parent of them
    for p in "$HOME" "$home_real" "$SCRIPT_DIR" "$OLECHARMS_CONFIG_DIR"; do
        [ -n "$p" ] || continue
        case "${p%/}/" in "$real"/*) return 1 ;; esac
    done
    # ...nor anything inside the checkout or a hidden folder of home
    # (~/.ssh, ~/.config, ~/.vim...)
    p=$(cd -P "$SCRIPT_DIR" 2>/dev/null && pwd)
    case "$real/" in
        "${p:-/nonexistent}"/*|"${home_real%/}"/.*|"${HOME%/}"/.*) return 1 ;;
    esac
    # Nor system locations, a whole drive or volume, or a user profile: a typo
    # in the config must not turn the cleanup loose on everything below it
    case "$real" in
        /bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*|\
        /opt|/opt/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/snap|/snap/*|/srv|/srv/*|\
        /sys|/sys/*|/usr|/usr/*|/var|/var/*|/home|/mnt|/mnt/wsl|/mnt/wsl/*|/mnt/wslg|/mnt/wslg/*|/media|/tmp|/Users|/Volumes|\
        /System|/System/*|/Library|/Library/*|/Applications|/Applications/*|/private|/private/*|\
        /mnt/[a-zA-Z]|/mnt/[a-zA-Z]/Users|/mnt/[a-zA-Z]/Windows|/mnt/[a-zA-Z]/Windows/*|\
        /mnt/[a-zA-Z]/Program\ Files*|/mnt/[a-zA-Z]/ProgramData|/mnt/[a-zA-Z]/ProgramData/*)
            return 1 ;;
        /mnt/[a-zA-Z]/Users/*|/Users/*|/home/*|/Volumes/*|/media/*)
            # the profile / home / volume itself, one level down
            rest=${real#/mnt/?/Users/}
            [ "$rest" = "$real" ] && rest=${real#/*/}
            case "$rest" in */*) ;; *) return 1 ;; esac
            ;;
    esac
    printf '%s\n' "$real"
}

# Files older than $2 days under real dir $1, NUL-separated into file $3.
# "Older" means both unmodified (mtime) and in the folder (ctime) for that
# long: tar, unzip, wget, cp -p or an Explorer copy keep the original mtime,
# so mtime alone would remove a file the moment it arrives — ctime cannot be
# set back. Files inside a git checkout are never taken. desktop.ini
# (Windows) and .localized (macOS) are old by nature but
# give the folder its localized name ("Descargas"), so they always stay.
# OLECHARMS_TEST_IGNORE_CTIME: tests cannot make a file's ctime old.
CLEANUP_PROTECT=""
cleanup_collect() {
    local root="$1" days="$2" out="$3" raw protect f p keep
    raw=$(mktemp) || { : > "$out"; return 1; }
    if [ -n "${OLECHARMS_TEST_IGNORE_CTIME:-}" ]; then
        find "$root" -type f -mtime "+$days" ! -name desktop.ini ! -name .localized -print0 2>/dev/null > "$raw"
    else
        find "$root" -type f -mtime "+$days" -ctime "+$days" ! -name desktop.ini ! -name .localized -print0 2>/dev/null > "$raw"
    fi
    # Never take files out of a git checkout — a cloned project, or olecharms
    # itself: losing old files under .git corrupts the repository
    protect=$(find "$root" -name .git -prune -print 2>/dev/null | sed 's#/\.git$##')
    protect=$(printf '%s\n%s' "$protect" "$(cd -P "$SCRIPT_DIR" 2>/dev/null && pwd)")
    CLEANUP_PROTECT=$protect
    while IFS= read -r -d '' f; do
        keep=""
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$f" in "$p"/*) keep=1; break ;; esac
        done <<< "$protect"
        [ -n "$keep" ] || printf '%s\0' "$f"
    done < "$raw" > "$out"
    rm -f "$raw"
}

# ─── Quarantine: recoverable removal where there is no trash ───

# Filesystem id of path $1 (GNU stat, then BSD)
fs_id() {
    stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null
}

# Where files of real dir $1 go: the data dir when it is on the same
# filesystem (a rename — instant, no extra space), else a hidden folder next
# to the cleaned one (on WSL: C:\Users\<name>\.olecharms-quarantine).
cleanup_quarantine_base() {
    local real="$1" id
    mkdir -p "$QUARANTINE_DATA_DIR" 2>/dev/null
    id=$(fs_id "$real")
    if [ -n "$id" ] && [ "$id" = "$(fs_id "$QUARANTINE_DATA_DIR")" ]; then
        echo "$QUARANTINE_DATA_DIR"
    else
        echo "${real%/*}/$QUARANTINE_SIBLING"
    fi
}

cleanup_quarantine_days() {
    local days
    days=$(config_get downloads_cleanup_quarantine_days "$CLEANUP_QUARANTINE_DAYS")
    [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] || days=$CLEANUP_QUARANTINE_DAYS
    echo "$days"
}

# Move NUL list $1 (files under real dir $2) into a new timestamped batch,
# keeping their paths relative to $2 (written to .origin) for --restore
cleanup_quarantine_move() {
    local list="$1" root="$2" base batch f rel
    base=$(cleanup_quarantine_base "$root")
    batch="$base/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$batch" || return 1
    printf '%s\n' "$root" > "$batch/.origin"
    while IFS= read -r -d '' f; do
        rel=${f#"$root"/}
        mkdir -p "$batch/$(dirname "$rel")" 2>/dev/null
        mv "$f" "$batch/$rel" 2>/dev/null
    done < "$list"
}

# The quarantine batches of real dir $1 (both possible places), one per line
cleanup_quarantine_batches() {
    local base d
    for base in "$QUARANTINE_DATA_DIR" "${1%/*}/$QUARANTINE_SIBLING"; do
        [ -d "$base" ] && [ ! -L "$base" ] || continue
        for d in "$base"/[0-9]*-[0-9]*; do
            cleanup_quarantine_is_batch "$d" && printf '%s\n' "$d"
        done
    done
}

# A batch is a real dir named YYYYMMDD-HHMMSS directly inside a quarantine
# folder, holding the .origin file olecharms writes — nothing else qualifies
cleanup_quarantine_is_batch() {
    local d="$1" parent
    [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/.origin" ] || return 1
    parent=${d%/*}
    case "${parent##*/}" in quarantine|"$QUARANTINE_SIBLING") ;; *) return 1 ;; esac
    case "${d##*/}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
    esac
    return 1
}

# Delete batches of real dir $1 older than the quarantine period
cleanup_quarantine_purge() {
    local days d
    days=$(cleanup_quarantine_days)
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -n "$(find "$d" -maxdepth 0 -mtime "+$days" 2>/dev/null)" ] || continue
        cleanup_quarantine_is_batch "$d" || continue
        rm -rf "$d" && cleanup_log_line "quarantine: deleted ${d##*/} (older than $days days)"
    done <<< "$(cleanup_quarantine_batches "$1")"
    rmdir "${1%/*}/$QUARANTINE_SIBLING" 2>/dev/null
    return 0
}

# "2026-10-31 17:45" from a batch path
cleanup_batch_label() {
    local n="${1##*/}"
    echo "${n:0:4}-${n:4:2}-${n:6:2} ${n:9:2}:${n:11:2}"
}

# `cleanup --restore`: pick a batch (newest preselected), put its files back
# where they were. Never overwrites: a name taken meanwhile is reported.
cleanup_quarantine_restore() {
    local dir real d origin f rel target n kb restored=0 taken=0 batches=()
    dir=$(config_get downloads_cleanup_dir)
    real=$(cleanup_real_dir "$dir") || real="${dir%/}"
    PICK_ITEMS=()
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        n=$(find "$d" -type f ! -name .origin 2>/dev/null | wc -l | tr -d ' ')
        kb=$(du -sk "$d" 2>/dev/null | cut -f1)
        batches+=("$d")
        PICK_ITEMS+=("$(cleanup_batch_label "$d")  $n files, $(human_kb "${kb:-0}")")
    done <<< "$(cleanup_quarantine_batches "$real")"
    if [ ${#batches[@]} -eq 0 ]; then
        info "The quarantine is empty"
        return 0
    fi
    echo -e "${BOLD}Restore a cleanup from the quarantine${NC} (kept $(cleanup_quarantine_days) days)"
    echo ""
    pick_item || { info "Cancelled"; return 0; }
    d=${batches[$PICK_INDEX]}
    origin=$(head -n 1 "$d/.origin")
    if [ -z "$origin" ] || [ ! -d "$origin" ]; then
        error "Its folder ${origin:-<unknown>} does not exist any more; the files are in $d"
        return 1
    fi
    while IFS= read -r -d '' f; do
        rel=${f#"$d"/}
        target="$origin/$rel"
        if [ -e "$target" ] || [ -L "$target" ]; then
            taken=$((taken + 1))
            continue
        fi
        mkdir -p "$(dirname "$target")" 2>/dev/null
        mv "$f" "$target" 2>/dev/null && restored=$((restored + 1))
    done < <(find "$d" -type f ! -path "$d/.origin" -print0 2>/dev/null)
    cleanup_log_line "restore: $restored files from ${d##*/} back to $origin"
    # Drop the batch once it is empty
    find "$d" -mindepth 1 -depth -type d -empty -exec rmdir {} \; 2>/dev/null
    if [ -z "$(find "$d" -type f ! -name .origin 2>/dev/null | head -n 1)" ]; then
        rm -f "$d/.origin"
        rmdir "$d" 2>/dev/null
    fi
    info "Restored $restored files to $origin"
    [ "$taken" -gt 0 ] && warn "$taken files were not restored: their names are taken again in $origin (they stay in $d)"
    return 0
}

# Second, independent check right before anything is removed: each path must
# be a regular file (not a symlink) strictly inside real dir $1, outside .git
# and outside the trees cleanup_collect protects. Reads NUL list $2, writes
# the paths that pass to $3 and logs the others to $4 as skipped.
cleanup_verify_list() {
    local root="$1" in="$2" out="$3" log="$4" f p bad
    while IFS= read -r -d '' f; do
        bad=""
        case "$f" in
            */../*|*/./*) bad="not a plain path" ;;
            "$root"/*)    ;;
            *)            bad="outside $root" ;;
        esac
        case "$f" in */.git/*) bad="inside .git" ;; esac
        if [ -z "$bad" ] && { [ -L "$f" ] || [ ! -f "$f" ]; }; then
            bad="not a regular file"
        fi
        if [ -z "$bad" ]; then
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                case "$f" in "$p"/*) bad="inside a git checkout"; break ;; esac
            done <<< "${CLEANUP_PROTECT:-}"
        fi
        if [ -n "$bad" ]; then
            printf 'skipped  %s (%s)\n' "$f" "$bad" >> "$log"
        else
            printf '%s\0' "$f"
        fi
    done < "$in" > "$out"
}

# True when removing $1 files ($2 KB) from real dir $3 is a mass removal:
# more than CLEANUP_BATCH_FILES files, CLEANUP_BATCH_KB, or over
# CLEANUP_BATCH_PERCENT of the folder's files. Sets CLEANUP_LARGE_WHY.
cleanup_is_large() {
    local count="$1" kb="$2" root="$3" total
    CLEANUP_LARGE_WHY=""
    if [ "$count" -gt "$CLEANUP_BATCH_FILES" ]; then
        CLEANUP_LARGE_WHY="$count files (more than $CLEANUP_BATCH_FILES)"
    elif [ "${kb:-0}" -gt "$CLEANUP_BATCH_KB" ]; then
        CLEANUP_LARGE_WHY="$(human_kb "$kb") (more than $(human_kb "$CLEANUP_BATCH_KB"))"
    elif [ "$count" -gt 20 ]; then
        total=$(find "$root" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [ "$total" -gt 0 ] && [ $((count * 100 / total)) -gt "$CLEANUP_BATCH_PERCENT" ]; then
            CLEANUP_LARGE_WHY="$count of the $total files in the folder"
        fi
    fi
    [ -n "$CLEANUP_LARGE_WHY" ]
}

# Remove the folders this run emptied (walking up towards root $1), plus
# empty folders that have themselves been left alone for $3 days. A folder
# created a minute ago, or the empty dirs of a project just extracted, stay.
cleanup_prune_dirs() {
    local root="$1" list="$2" days="$3" f d p skip
    while IFS= read -r -d '' f; do
        d=${f%/*}
        while [ "$d" != "$root" ] && [ "${d#"$root"/}" != "$d" ]; do
            rmdir "$d" 2>/dev/null || break
            d=${d%/*}
        done
    done < "$list"
    # Long-empty folders, but nothing under .git or inside a git checkout
    # (cleanup_collect's CLEANUP_PROTECT); rmdir only ever removes empty ones
    find "$root" -mindepth 1 -name .git -prune -o -type d -empty -mtime "+$days" -ctime "+$days" -print0 2>/dev/null |
        while IFS= read -r -d '' d; do
            skip=""
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                case "$d/" in "$p"/*) skip=1; break ;; esac
            done <<< "${CLEANUP_PROTECT:-}"
            [ -n "$skip" ] || rmdir "$d" 2>/dev/null
        done
    return 0
}

cleanup_count() {
    tr -cd '\0' < "$1" | wc -c | tr -d ' '
}

# Total size in KB of the files in list $1 ($2 = their count; GNU xargs would
# run du on the current directory for an empty list).
cleanup_size_kb() {
    [ "${2:-0}" -gt 0 ] || { echo 0; return 0; }
    xargs -0 du -k < "$1" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'
}

human_kb() {
    awk -v k="${1:-0}" 'BEGIN {
        if (k < 1024) printf "%d KB", k
        else if (k < 1048576) printf "%.1f MB", k / 1024
        else printf "%.1f GB", k / 1048576
    }'
}

# The trash for files under real dir $1: recycle-bin (a Windows drive seen from
# WSL), macos-trash, gio or trash-put. Fails when there is none.
cleanup_trash_backend() {
    local dir="$1" win
    if [ -n "$IS_WSL" ] && check_command wslpath; then
        win=$(wslpath -w "$dir" 2>/dev/null)
        case "$win" in
            [A-Za-z]:*)
                # A Windows drive: its Recycle Bin or nothing (a Linux trash
                # would park the files in a hidden folder on C:)
                if win_powershell >/dev/null && win_bin_status "$dir"; then
                    echo recycle-bin
                    return 0
                fi
                return 1
                ;;
        esac
    fi
    if [ "$OS" = "macos" ]; then
        echo macos-trash
        return 0
    fi
    if check_command gio; then
        echo gio
        return 0
    fi
    if check_command trash-put; then
        echo trash-put
        return 0
    fi
    return 1
}

# Backend for action $2 on real dir $1: "auto" trashes only where the trash is
# one the user actually empties (Windows Recycle Bin, macOS Trash) — a desktop
# trash on a headless Linux box would just grow — and deletes otherwise.
# Fails for "trash" when there is no trash at all.
cleanup_effective_backend() {
    local dir="$1" action="${2:-auto}" backend
    case "$action" in
        delete)
            echo delete
            ;;
        trash)
            backend=$(cleanup_trash_backend "$dir") || return 1
            echo "$backend"
            ;;
        *)
            backend=$(cleanup_trash_backend "$dir")
            case "$backend" in
                recycle-bin|macos-trash) echo "$backend" ;;
                *)                       echo quarantine ;;
            esac
            ;;
    esac
}

cleanup_backend_label() {
    case "$1" in
        recycle-bin)   echo "move to the Windows Recycle Bin" ;;
        macos-trash)   echo "move to the macOS Trash" ;;
        gio|trash-put) echo "move to the desktop trash ($1)" ;;
        delete)        echo "delete permanently" ;;
        quarantine)    echo "move to quarantine, restorable for $(cleanup_quarantine_days) days (olecharms cleanup --restore)" ;;
        *)             echo "$1" ;;
    esac
}

cleanup_macos_trash() {
    local list="$1" f base dest n
    if [ -x /usr/bin/trash ]; then
        # macOS 15+ ships a trash command that keeps "Put Back" working
        xargs -0 /usr/bin/trash < "$list" 2>/dev/null
        return 0
    fi
    mkdir -p "$HOME/.Trash" 2>/dev/null
    while IFS= read -r -d '' f; do
        base=$(basename "$f")
        dest="$HOME/.Trash/$base"
        n=1
        while [ -e "$dest" ]; do
            dest="$HOME/.Trash/$base $n"
            n=$((n + 1))
        done
        mv "$f" "$dest" 2>/dev/null
    done < "$list"
}

# Act on NUL-separated list $1 with backend $2 (files all under real dir $4).
# Whatever is gone afterwards counts as done, so a backend that fails halfway
# is still reported truthfully. Appends one line per file to log $3 and prints
# "<done> <failed>".
cleanup_apply() {
    local backend="$2" log="$3" root="$4" f verb n_done=0 n_failed=0 n_kept=0 i=0 skip=" " list
    list=$(mktemp) || { echo "0 0 0"; return 1; }
    cleanup_verify_list "$root" "$1" "$list" "$log"
    case "$backend" in
        delete)      xargs -0 rm -f < "$list" 2>/dev/null ;;
        gio)         xargs -0 gio trash < "$list" 2>/dev/null ;;
        trash-put)   xargs -0 trash-put < "$list" 2>/dev/null ;;
        macos-trash) cleanup_macos_trash "$list" ;;
        quarantine)  cleanup_quarantine_move "$list" "$root" ;;
        recycle-bin)
            # Positions of files the bin could not take (kept, not deleted)
            skip=" $(win_recycle "$list" "$root" | awk '$1 == "SKIP" { printf "%s ", $2 }')"
            ;;
    esac
    verb=trashed
    [ "$backend" = delete ] && verb=deleted
    [ "$backend" = quarantine ] && verb=quarant.
    while IFS= read -r -d '' f; do
        if [ ! -e "$f" ]; then
            n_done=$((n_done + 1))
            printf '%-8s %s\n' "$verb" "$f"
        else
            case "$skip" in
                *" $i "*) n_kept=$((n_kept + 1)); printf 'kept     %s (the Recycle Bin cannot take it)\n' "$f" ;;
                *)        n_failed=$((n_failed + 1)); printf 'failed   %s\n' "$f" ;;
            esac
        fi
        i=$((i + 1))
    done < "$list" >> "$log"
    rm -f "$list"
    echo "$n_done $n_failed $n_kept"
}

cleanup_log_line() {
    mkdir -p "$OLECHARMS_STATE_DIR" 2>/dev/null || return 0
    printf '=== %s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$CLEANUP_LOG"
}

cleanup_trim_log() {
    local n tmp
    [ -f "$CLEANUP_LOG" ] || return 0
    n=$(wc -l < "$CLEANUP_LOG" | tr -d ' ')
    [ "$n" -gt "$CLEANUP_LOG_MAX_LINES" ] || return 0
    tmp="$CLEANUP_LOG.tmp.$$"
    tail -n "$CLEANUP_LOG_MAX_LINES" "$CLEANUP_LOG" > "$tmp" && mv -f "$tmp" "$CLEANUP_LOG"
}

cleanup_show_log() {
    if [ ! -s "$CLEANUP_LOG" ]; then
        info "No cleanups logged yet ($CLEANUP_LOG)"
        return 0
    fi
    echo -e "${BOLD}Recent downloads cleanups${NC}  (newest last; full list of files in $CLEANUP_LOG)"
    echo ""
    grep '^=== ' "$CLEANUP_LOG" | tail -n 20 | sed 's/^=== /  /'
}

CLEANUP_LOCK=""
cleanup_release_lock() {
    [ -n "$CLEANUP_LOCK" ] && rmdir "$CLEANUP_LOCK" 2>/dev/null
    CLEANUP_LOCK=""
}

# One cleanup pass: lock, collect, act, log. $4 is the trigger (scheduled or
# manual); $5 an already collected list to act on. Scheduled runs are silent —
# they run in the background of a new shell — and leave their trace in the log.
cleanup_run() {
    local dir="$1" days="$2" action="$3" trigger="$4" list="${5:-}"
    local own_list="" real backend count kb result n_done n_failed n_kept=0 lock
    if ! real=$(cleanup_real_dir "$dir"); then
        cleanup_log_line "$trigger: skipped — ${dir:-<no folder>} is missing or a protected location"
        [ "$trigger" = scheduled ] || error "Cannot clean ${dir:-<no folder>}: missing, or a protected location (home, system folder, whole drive, user profile)"
        return 1
    fi
    if ! backend=$(cleanup_effective_backend "$real" "$action"); then
        cleanup_log_line "$trigger: skipped — action is 'trash' but $real has no trash"
        [ "$trigger" = scheduled ] || error "No trash available for $real; set the action to auto or delete in 'olecharms config'"
        return 1
    fi

    mkdir -p "$OLECHARMS_STATE_DIR" 2>/dev/null
    lock="$OLECHARMS_STATE_DIR/cleanup.lock"
    # mkdir is atomic, so two shells opening at once cannot both run. A lock
    # older than a day is left over from a killed run.
    if ! mkdir "$lock" 2>/dev/null; then
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +1440 2>/dev/null)" ]; then
            rmdir "$lock" 2>/dev/null
            mkdir "$lock" 2>/dev/null || return 0
        else
            [ "$trigger" = scheduled ] || warn "Another cleanup is running right now; try again in a moment"
            return 0
        fi
    fi
    CLEANUP_LOCK="$lock"
    trap cleanup_release_lock EXIT
    trap 'cleanup_release_lock; exit 130' INT TERM
    cleanup_quarantine_purge "$real"

    if [ -z "$list" ]; then
        list=$(mktemp) || { cleanup_release_lock; return 1; }
        own_list=1
        cleanup_collect "$real" "$days" "$list"
    fi
    count=$(cleanup_count "$list")
    n_done=0
    n_failed=0
    [ "$count" -gt 0 ] && kb=$(cleanup_size_kb "$list" "$count")
    # Unattended runs never remove in bulk: hold it, and say so in new shells,
    # until it is confirmed by hand with 'olecharms cleanup'
    if [ "$trigger" = scheduled ] && [ "$count" -gt 0 ] && cleanup_is_large "$count" "$kb" "$real"; then
        printf '%s files (%s) are due in %s — more than a scheduled run removes on its own\n' \
            "$count" "$(human_kb "$kb")" "$real" > "$CLEANUP_HELD" 2>/dev/null
        cleanup_log_line "scheduled: held — $CLEANUP_LARGE_WHY; confirm with 'olecharms cleanup'"
        [ -n "$own_list" ] && rm -f "$list"
        cleanup_release_lock
        trap - EXIT INT TERM
        return 0
    fi
    rm -f "$CLEANUP_HELD" 2>/dev/null
    if [ "$count" -gt 0 ]; then
        cleanup_log_line "$trigger  $real  >${days}d  $backend  $count files, $(human_kb "$kb")"
        result=$(cleanup_apply "$list" "$backend" "$CLEANUP_LOG" "$real")
        read -r n_done n_failed n_kept <<< "$result"
        cleanup_prune_dirs "$real" "$list" "$days"
        cleanup_trim_log
    fi
    [ -n "$own_list" ] && rm -f "$list"
    cleanup_release_lock
    trap - EXIT INT TERM

    if [ "$trigger" != scheduled ]; then
        if [ "$count" -eq 0 ]; then
            info "Nothing older than $days days in $real"
        else
            info "Done: $n_done of $count files ($(human_kb "$kb")) — $(cleanup_backend_label "$backend")"
            [ "$n_failed" -gt 0 ] && warn "$n_failed files could not be removed (in use or no permission); see 'olecharms cleanup --log'"
            [ "${n_kept:-0}" -gt 0 ] && warn "$n_kept files were kept: the Recycle Bin cannot take them (too big, or no bin on that drive)"
        fi
    fi
    [ "$n_failed" -eq 0 ]
}

# Print the cleanup summary for real dir $1 / list $2; with $3, also the first
# $3 matching files.
cleanup_print_preview() {
    local dir="$1" real="$2" days="$3" backend="$4" list="$5" limit="${6:-}" count kb
    count=$(cleanup_count "$list")
    kb=$(cleanup_size_kb "$list" "$count")
    echo "  Folder:   $dir"
    [ "$real" != "$dir" ] && echo "            → $real"
    echo "  Rule:     files untouched and in the folder for over $days days (desktop.ini and .localized stay)"
    echo "  Action:   $(cleanup_backend_label "$backend")"
    # On a Windows drive, "delete" usually means the bin is off: say so
    if [ "$backend" != recycle-bin ] && [ -n "${IS_WSL:-}" ] && [ "${real#/mnt/[a-zA-Z]/}" != "$real" ] &&
       ! win_bin_status "$real"; then
        if [ "$backend" = delete ]; then
            echo "            (the Windows Recycle Bin is ${WIN_BIN_WHY:-unavailable} — files would be gone for good)"
        else
            echo "            (the Windows Recycle Bin is ${WIN_BIN_WHY:-unavailable})"
        fi
    fi
    echo "  Matches:  $count files, $(human_kb "$kb")"
    if [ -n "$limit" ] && [ "$count" -gt 0 ]; then
        echo ""
        tr '\0' '\n' < "$list" | sort | head -n "$limit" | sed 's/^/    /'
        [ "$count" -gt "$limit" ] && echo "    … and $((count - limit)) more (full list: olecharms cleanup --dry-run)"
    fi
}

# ─── Windows (WSL) Integration ──────────────────────────────────────────────
# From WSL, olecharms also manages the Windows side: Windows' own gVim gets the
# same config and plugins as the terminal vim, and the Powerline fonts are
# installed for the Windows user (Windows Terminal and gVim draw with Windows
# fonts, so the Linux-side copies do nothing for them). PowerShell scripts are
# defined here at top level — not as heredocs inside $(...), which the bash 3.2
# shipped with macOS misparses when they contain quotes.

# Everything needed from Windows in one PowerShell start (~1s each).
IFS= read -r -d '' PS_WIN_ENV <<'PS_EOF' || true
$dl = $null
try { $dl = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
if (-not $dl) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
"USERPROFILE=$env:USERPROFILE"
"LOCALAPPDATA=$env:LOCALAPPDATA"
"HOME=$env:HOME"
"HOMEDRIVE=$env:HOMEDRIVE"
"HOMEPATH=$env:HOMEPATH"
"DOWNLOADS=$dl"
"PROGRAMFILES=$env:ProgramFiles"
"PROGRAMFILES86=${env:ProgramFiles(x86)}"
foreach ($k in 'HKLM:\SOFTWARE\Vim\Gvim', 'HKLM:\SOFTWARE\WOW6432Node\Vim\Gvim') {
    try { $p = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).path; if ($p) { "GVIM_REG=$p"; break } } catch {}
}
$g = Get-Command gvim.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($g) { "GVIM_PATH=$($g.Source)" }
foreach ($k in 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') {
    try {
        $props = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
        foreach ($pr in $props.PSObject.Properties) {
            if ($pr.Name -notlike 'PS*') { "FONT=$([IO.Path]::GetFileName([string]$pr.Value))" }
        }
    } catch {}
}
PS_EOF

# Register already-copied font files ($Fonts) for the current user and load
# them into the running session, as Explorer's "Install for me" does.
IFS= read -r -d '' PS_FONTS <<'PS_EOF' || true
Add-Type -Namespace Olecharms -Name Gdi -MemberDefinition '[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);'
$key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
foreach ($f in $Fonts) {
    $name = [IO.Path]::GetFileNameWithoutExtension($f) + ' (TrueType)'
    New-ItemProperty -Path $key -Name $name -Value $f -PropertyType String -Force | Out-Null
    [void][Olecharms.Gdi]::AddFontResource($f)
    "INSTALLED $f"
}
PS_EOF

# Send each file listed in $ListFile (UTF-8, one Windows path per line) to the
# Recycle Bin. SHFileOperation with NOERRORUI/SILENT/NOCONFIRMATION never opens
# a dialog — this runs in the background of a new shell.
# Whether the Recycle Bin of the drive holding $path can take files, and how
# much. SHFileOperation deletes outright — silently, under NOCONFIRMATION —
# whatever the bin cannot hold: the bin is switched off for that drive
# (NukeOnDelete, or the NoRecycleFiles policy), the drive is not a fixed one
# (USB sticks, network shares have no bin), or the file is bigger than the
# bin. Default size when unset: 5% of the volume, as Windows does.
IFS= read -r -d '' PS_BIN_FUNC <<'PS_EOF' || true
function Get-OlecharmsBin([string]$path) {
    $r = [IO.Path]::GetPathRoot($path)
    try { $d = New-Object IO.DriveInfo($r) } catch { return @{ On = $false; Limit = 0; Why = 'unknown drive' } }
    if ("$($d.DriveType)" -ne 'Fixed') { return @{ On = $false; Limit = 0; Why = "$($d.DriveType) drive, no Recycle Bin" } }
    foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer') {
        try { if ((Get-ItemProperty -LiteralPath $k -ErrorAction Stop).NoRecycleFiles -eq 1) { return @{ On = $false; Limit = 0; Why = 'turned off by policy' } } } catch {}
    }
    $limit = [int64]($d.TotalSize * 0.05)
    try {
        $v = Get-CimInstance Win32_Volume -Filter ("DriveLetter='" + $r.Substring(0, 2) + "'") -ErrorAction Stop
        if ($v.DeviceID -match '(\{[^}]+\})') {
            $p = Get-ItemProperty -LiteralPath ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\' + $Matches[1]) -ErrorAction Stop
            if ($p.NukeOnDelete -eq 1) { return @{ On = $false; Limit = 0; Why = "turned off for $($r.Substring(0, 2))" } }
            if ($p.MaxCapacity) { $limit = [int64]$p.MaxCapacity * 1MB }
        }
    } catch {}
    return @{ On = $true; Limit = $limit; Why = '' }
}
PS_EOF

IFS= read -r -d '' PS_BIN_STATUS <<'PS_EOF' || true
$b = Get-OlecharmsBin $Root
if ($b.On) { "BIN on $($b.Limit)" } else { "BIN off $($b.Why)" }
PS_EOF

IFS= read -r -d '' PS_RECYCLE <<'PS_EOF' || true
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OlecharmsRecycle {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
    public static int Recycle(string path) {
        SHFILEOPSTRUCT op = new SHFILEOPSTRUCT();
        op.wFunc = 3;                                     // FO_DELETE
        op.pFrom = path + "\0\0";                         // double-NUL terminated
        op.fFlags = (ushort)(0x0040 | 0x0010 | 0x0004 | 0x0400); // ALLOWUNDO|NOCONFIRMATION|SILENT|NOERRORUI
        return SHFileOperation(ref op);
    }
}
'@
$ok = 0; $fail = 0; $skip = 0; $i = -1; $bins = @{}
foreach ($p in [IO.File]::ReadAllLines($ListFile, [Text.Encoding]::UTF8)) {
    $i++
    if ($p -eq '') { continue }
    # Never let "recycle" turn into a silent permanent delete: keep what the
    # bin cannot take, and report it by its position in the list
    $r = [IO.Path]::GetPathRoot($p)
    if (-not $bins.ContainsKey($r)) { $bins[$r] = Get-OlecharmsBin $p }
    $len = 0
    try { $len = (Get-Item -LiteralPath $p -Force -ErrorAction Stop).Length } catch {}
    if (-not $bins[$r].On -or $len -gt $bins[$r].Limit) { "SKIP $i"; $skip++; continue }
    $null = [OlecharmsRecycle]::Recycle($p)
    if (Test-Path -LiteralPath $p) { $fail++ } else { $ok++ }
}
"RESULT $ok $fail $skip"
PS_EOF

# A PowerShell single-quoted literal
ps_quote() {
    local s=${1//\'/\'\'}
    printf "'%s'" "$s"
}

# Path to powershell.exe. Cron's PATH has no Windows dirs, so fall back to the
# standard location.
win_powershell() {
    local p
    p=$(command -v powershell.exe 2>/dev/null)
    if [ -z "$p" ]; then
        for p in /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
                 /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe ""; do
            [ -n "$p" ] && [ -x "$p" ] && break
        done
    fi
    [ -n "$p" ] || return 1
    printf '%s\n' "$p"
}

# Run PowerShell code on the Windows side: $1 is a prelude (variable
# assignments), $2 the script. It travels as -EncodedCommand (UTF-16LE base64):
# nothing to quote through the interop layer, no execution-policy prompt, no
# temp .ps1. Output comes back as UTF-8 with the CRs stripped.
win_ps_run() {
    local ps encoded limit="${WIN_PS_TIMEOUT:-300}"
    ps=$(win_powershell) || return 1
    encoded=$(printf '%s\n%s\n%s\n' \
        '[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ProgressPreference = "SilentlyContinue"' \
        "$1" "$2" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n') || return 1
    (
        # A Windows cwd: from a \\wsl$ one Windows tools print UNC warnings
        cd "$(dirname "$ps")" 2>/dev/null
        # stdin from /dev/null: powershell.exe otherwise swallows whatever is
        # waiting on ours — the rest of the user's typed (or piped) answers.
        if check_command timeout; then
            timeout "$limit" "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded" </dev/null
        else
            "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded" </dev/null
        fi
    ) 2>/dev/null | tr -d '\r'
}

# Load the Windows-side paths once per run into WIN_* (WSL paths). Fails when
# not on WSL or when Windows cannot be reached (interop disabled, no PowerShell).
WIN_ENV_STATE=""
win_env_load() {
    case "$WIN_ENV_STATE" in
        ok)   return 0 ;;
        fail) return 1 ;;
    esac
    WIN_ENV_STATE=fail
    [ -n "${IS_WSL:-}" ] && check_command wslpath && check_command iconv || return 1
    local out line key val
    out=$(win_ps_run "" "$PS_WIN_ENV")
    [ -n "$out" ] || return 1
    WIN_USERPROFILE="" WIN_LOCALAPPDATA="" WIN_DOWNLOADS="" WIN_PROGRAMFILES=""
    WIN_PROGRAMFILES86="" WIN_GVIM_REG="" WIN_GVIM_PATH="" WIN_HOME_RAW="" WIN_FONT_FILES=""
    local homedrive="" homepath=""
    while IFS= read -r line; do
        key=${line%%=*}
        val=${line#*=}
        [ -n "$val" ] || continue
        case "$key" in
            USERPROFILE)    WIN_USERPROFILE=$(wslpath -u "$val" 2>/dev/null) ;;
            LOCALAPPDATA)   WIN_LOCALAPPDATA=$(wslpath -u "$val" 2>/dev/null) ;;
            HOME)           WIN_HOME_RAW=$val ;;
            HOMEDRIVE)      homedrive=$val ;;
            HOMEPATH)       homepath=$val ;;
            DOWNLOADS)      WIN_DOWNLOADS=$(wslpath -u "$val" 2>/dev/null) ;;
            PROGRAMFILES)   WIN_PROGRAMFILES=$(wslpath -u "$val" 2>/dev/null) ;;
            PROGRAMFILES86) WIN_PROGRAMFILES86=$(wslpath -u "$val" 2>/dev/null) ;;
            GVIM_REG)       WIN_GVIM_REG=$val ;;
            GVIM_PATH)      WIN_GVIM_PATH=$val ;;
            FONT)           WIN_FONT_FILES="$WIN_FONT_FILES$val"$'\n' ;;
        esac
    done <<< "$out"
    [ -n "$WIN_USERPROFILE" ] && [ -d "$WIN_USERPROFILE" ] || return 1

    # Where Windows Vim looks for _vimrc and vimfiles (:h $HOME-windows):
    # %HOME% if set, else %HOMEDRIVE%%HOMEPATH% (a mapped home drive on
    # managed machines), else %USERPROFILE%.
    WIN_VIM_HOME="$WIN_USERPROFILE"
    if [ -n "$homedrive" ] && [ -n "$homepath" ]; then
        val=$(wslpath -u "$homedrive$homepath" 2>/dev/null)
        [ -n "$val" ] && [ -d "$val" ] && WIN_VIM_HOME="$val"
    fi
    if [ -n "$WIN_HOME_RAW" ]; then
        val=$(wslpath -u "$WIN_HOME_RAW" 2>/dev/null)
        [ -n "$val" ] && [ -d "$val" ] && WIN_VIM_HOME="$val"
    fi
    # Lets tests point everything at a scratch folder
    [ -n "${OLECHARMS_WIN_VIM_HOME:-}" ] && WIN_VIM_HOME="$OLECHARMS_WIN_VIM_HOME"
    WIN_ENV_STATE=ok
    return 0
}

# gvim.exe on the Windows side: the installer's registry key, the usual install
# folders (newest vimNN first), Scoop, then %PATH%. Prints its WSL path.
win_find_gvim() {
    local p cand
    win_env_load || return 1
    for cand in "$WIN_GVIM_REG" "$WIN_GVIM_PATH"; do
        [ -n "$cand" ] || continue
        p=$(wslpath -u "$cand" 2>/dev/null)
        if [ -n "$p" ] && [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    for cand in "$WIN_PROGRAMFILES" "$WIN_PROGRAMFILES86"; do
        [ -n "$cand" ] || continue
        p=$(ls -d "$cand"/Vim/vim[0-9]*/gvim.exe 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    p="$WIN_USERPROFILE/scoop/apps/vim/current/gvim.exe"
    if [ -f "$p" ]; then
        printf '%s\n' "$p"
        return 0
    fi
    return 1
}

# "9.2" from .../Vim/vim92/gvim.exe; empty when the folder does not say.
win_gvim_version() {
    local d
    d=$(basename "$(dirname "$1")")
    case "$d" in
        vim[0-9][0-9]*) d=${d#vim}; echo "${d%?}.${d#?}" ;;
    esac
}

win_font_registered() {
    printf '%s' "$WIN_FONT_FILES" | grep -qixF -- "$1"
}

# Where the font files come from: the powerline clone, else the bundled copy.
font_source_dir() {
    if [ -d "$FONTS_STAGING" ] && [ -n "$(ls -A "$FONTS_STAGING" 2>/dev/null)" ]; then
        echo "$FONTS_STAGING"
    elif [ -d "$BUNDLED_DIR/fonts/powerline" ]; then
        echo "$BUNDLED_DIR/fonts/powerline"
    else
        return 1
    fi
}

# Font files of FONT_FAMILIES not yet installed for the Windows user, one per line.
win_missing_fonts() {
    local src family f
    src=$(font_source_dir) || return 0
    for family in "${FONT_FAMILIES[@]}"; do
        for f in "$src/$family"/*.ttf "$src/$family"/*.otf; do
            [ -f "$f" ] || continue
            win_font_registered "$(basename "$f")" || printf '%s\n' "$f"
        done
    done
}

# Install FONT_FAMILIES for the Windows user — no admin needed: copy into
# %LOCALAPPDATA%\Microsoft\Windows\Fonts, register under HKCU, load them.
install_windows_fonts() {
    local fontdir f base prelude out n=0 missing
    missing=$(win_missing_fonts)
    if [ -z "$missing" ]; then
        info "Windows fonts already installed (${FONT_FAMILIES[*]})"
        return 0
    fi
    fontdir="$WIN_LOCALAPPDATA/Microsoft/Windows/Fonts"
    if [ -z "$WIN_LOCALAPPDATA" ] || ! mkdir -p "$fontdir" 2>/dev/null; then
        error "Cannot reach the Windows user fonts folder"
        return 1
    fi
    prelude='$Fonts = @('
    while IFS= read -r f; do
        base=$(basename "$f")
        cp "$f" "$fontdir/$base" 2>/dev/null || { error "Could not copy $base to Windows"; continue; }
        prelude="$prelude$(ps_quote "$(wslpath -w "$fontdir/$base")"),"
    done <<< "$missing"
    prelude="${prelude%,})"
    out=$(win_ps_run "$prelude" "$PS_FONTS")
    n=$(printf '%s\n' "$out" | grep -c '^INSTALLED ')
    if [ "$n" -gt 0 ]; then
        info "Installed $n font files for the Windows user (${FONT_FAMILIES[*]})"
    else
        error "Could not register fonts on Windows"
        return 1
    fi
}

copy_if_changed() {
    local src="$1" dest="$2"
    [ -f "$src" ] || return 1
    cmp -s "$src" "$dest" 2>/dev/null && return 0
    cp "$src" "$dest"
}

# Mirror a plugin into Windows' vimfiles: no .git (Windows Vim does not need
# it and it is most of the size), symlinks resolved, our stamp preserved.
mirror_dir() {
    local src="$1" dest="$2"
    # --delete / rm -rf on dest: it must be a plugin folder, never bundle/
    case "$(basename "$dest")" in ""|.|..|bundle|vimfiles) return 1 ;; esac
    [ -d "$src" ] || return 1
    if check_command rsync; then
        rsync -rtLq --delete --modify-window=2 --exclude .git --exclude "$WIN_MANAGED_STAMP" "$src/" "$dest/"
    else
        rm -rf "$dest" && cp -RL "$src" "$dest" && rm -rf "$dest/.git"
    fi
}

# Copy every plugin from ~/.vim/bundle into vimfiles\bundle and drop copies we
# made earlier of plugins packages.conf no longer lists. A plugin folder
# olecharms did not create is never touched.
win_sync_plugins() {
    local bundle="$1" entry name src dest wanted="|" synced=0
    for entry in "${VIM_PLUGINS[@]}"; do
        name="${entry%%|*}"
        plugin_name_valid "$name" || continue
        wanted="$wanted$name|"
        src="$VIM_DIR/bundle/$name"
        dest="$bundle/$name"
        if [ ! -d "$src" ]; then
            warn "Plugin $name is not installed in $VIM_DIR; not copied to Windows"
            continue
        fi
        if [ -d "$dest" ] && [ ! -f "$dest/$WIN_MANAGED_STAMP" ]; then
            warn "$dest was not installed by olecharms; leaving it alone"
            continue
        fi
        if mirror_dir "$src" "$dest"; then
            : > "$dest/$WIN_MANAGED_STAMP"
            synced=$((synced + 1))
        else
            error "Could not copy plugin $name to $dest"
        fi
    done
    for dest in "$bundle"/*; do
        [ -f "$dest/$WIN_MANAGED_STAMP" ] || continue
        name=$(basename "$dest")
        case "$wanted" in
            *"|$name|"*) ;;
            *) rm -rf "$dest" && info "Removed $name from Windows vimfiles (no longer in packages.conf)" ;;
        esac
    done
    info "Windows vim plugins in sync ($synced/${#VIM_PLUGINS[@]})"
}

# Make Windows' user _vimrc source the olecharms config — the same one-block
# setup ~/.vimrc gets. Keeps the file's own line endings (a new file gets
# CRLF). A user _vimrc takes precedence over the system $VIM\_vimrc.
win_install_vimrc() {
    local vimrc="$1" exact=0 stale=0 markers=0 line eol
    if [ -f "$vimrc" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%$'\r'}
            case "$line" in
                "$SOURCE_MARKER")           markers=$((markers + 1)) ;;
                "$WIN_VIMRC_LINE")          exact=$((exact + 1)) ;;
                *"olecharms/olevimrc.vim"*) stale=$((stale + 1)) ;;
            esac
        done < "$vimrc"
        if [ "$exact" -eq 1 ] && [ "$stale" -eq 0 ] && [ "$markers" -eq 1 ]; then
            info "Windows _vimrc already sources olecharms"
            return 0
        fi
        backup_file "$vimrc" || return 1
        if [ $((exact + stale + markers)) -gt 0 ]; then
            rc_strip_block "$vimrc" "$SOURCE_MARKER" "olecharms/olevimrc.vim" || return 1
        fi
    fi
    eol=$'\r\n'
    if [ -s "$vimrc" ] && ! head -n 1 "$vimrc" | grep -q $'\r$'; then
        eol=$'\n'
    fi
    {
        if [ -s "$vimrc" ]; then
            [ -n "$(tail -c 1 "$vimrc")" ] && printf '%s' "$eol"
            printf '%s' "$eol"
        fi
        printf '%s%s%s%s' "$SOURCE_MARKER" "$eol" "$WIN_VIMRC_LINE" "$eol"
    } >> "$vimrc" || { error "Could not write $vimrc"; return 1; }
    info "Windows _vimrc now sources the olecharms config ($vimrc)"
}

# Give Windows' gVim the same config, pathogen and plugins as the terminal vim.
install_windows_vim() {
    local gvim vf pathogen
    if ! gvim=$(win_find_gvim); then
        info "gVim not found on Windows — skipping (install it with: winget install vim.vim)"
        return 0
    fi
    info "Configuring Windows Vim $(win_gvim_version "$gvim") ($gvim)"
    vf="$WIN_VIM_HOME/vimfiles"
    if ! mkdir -p "$vf/autoload" "$vf/bundle" "$vf/olecharms" "$vf/undodir" "$vf/swapfiles" 2>/dev/null; then
        error "Cannot create $vf"
        return 1
    fi
    pathogen="$VIM_DIR/autoload/pathogen.vim"
    [ -f "$pathogen" ] || pathogen="$BUNDLED_DIR/autoload/pathogen.vim"
    copy_if_changed "$pathogen" "$vf/autoload/pathogen.vim" || error "Could not copy pathogen.vim to Windows"
    copy_if_changed "$BUNDLED_DIR/olevimrc.vim" "$vf/olecharms/olevimrc.vim" || error "Could not copy olevimrc.vim to Windows"
    win_sync_plugins "$vf/bundle"
    win_install_vimrc "$WIN_VIM_HOME/_vimrc"
}

# install/update hook: everything on the Windows side, unless switched off
sync_windows_side() {
    [ -n "${IS_WSL:-}" ] || return 0
    [ "$(config_get windows_integration auto)" = "off" ] && return 0
    if ! win_env_load; then
        warn "Windows is not reachable from WSL (interop off or no PowerShell); skipping gVim and Windows fonts"
        return 0
    fi
    install_windows_fonts
    install_windows_vim
}

# Windows Recycle Bin for list $1 (NUL-separated WSL paths, all under real
# dir $2 on a Windows drive). Prints "RESULT <ok> <failed>".
win_recycle() {
    local list="$1" root="$2" winroot tmp f rel
    winroot=$(wslpath -w "$root" 2>/dev/null) || return 1
    tmp=$(mktemp) || return 1
    # One Windows path per line (Windows names cannot hold a newline). Mapping
    # the root once is far faster than a wslpath call per file.
    while IFS= read -r -d '' f; do
        rel="${f#"$root"}"
        printf '%s%s\n' "$winroot" "${rel//\//\\}"
    done < "$list" > "$tmp"
    WIN_PS_TIMEOUT=3600 win_ps_run "\$ListFile = $(ps_quote "$(wslpath -w "$tmp")")" "$PS_BIN_FUNC$PS_RECYCLE"
    rm -f "$tmp"
}

# Whether the Windows Recycle Bin of the drive holding WSL path $1 is usable;
# sets WIN_BIN_WHY when it is not. Cached per drive for this run.
WIN_BIN_CACHE=""
win_bin_status() {
    local win drive out entry
    win=$(wslpath -w "$1" 2>/dev/null) || return 1
    drive=${win%%:*}
    case "$WIN_BIN_CACHE" in
        *"|$drive=on|"*) return 0 ;;
    esac
    entry=$(printf '%s' "$WIN_BIN_CACHE" | tr '|' '\n' | grep "^$drive=off:" | head -n 1)
    if [ -n "$entry" ]; then
        WIN_BIN_WHY=${entry#*=off:}
        return 1
    fi
    out=$(win_ps_run "\$Root = $(ps_quote "$win")" "$PS_BIN_FUNC$PS_BIN_STATUS" | grep '^BIN ' | tail -n 1)
    case "$out" in
        "BIN on "*)
            WIN_BIN_CACHE="$WIN_BIN_CACHE|$drive=on|"
            return 0
            ;;
    esac
    WIN_BIN_WHY=${out#BIN off }
    [ -n "$out" ] || WIN_BIN_WHY="Windows could not be asked"
    WIN_BIN_CACHE="$WIN_BIN_CACHE|$drive=off:$WIN_BIN_WHY|"
    return 1
}

# ─── Config Versioning ──────────────────────────────────────────────────────

config_read() {
    # Parse config file into OLECHARMS_CFG_* variables (safe, no source)
    [ -f "$OLECHARMS_CONFIG_FILE" ] || return 1
    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        case "$key" in
            \#*|"") continue ;;
        esac
        # Sanitize key: only allow alphanumeric and underscore
        key=$(echo "$key" | tr -cd 'A-Za-z0-9_')
        [ -z "$key" ] && continue
        # A file saved from a Windows editor (WSL) has CRLF endings; a stray \r
        # would make "true" compare unequal and paths not exist.
        value=${value%$'\r'}
        printf -v "OLECHARMS_CFG_${key}" '%s' "$value"
    done < "$OLECHARMS_CONFIG_FILE"
}

config_get() {
    local key="$1" default="${2:-}"
    local var="OLECHARMS_CFG_${key}"
    if [ -n "${!var+x}" ]; then
        echo "${!var}"
    else
        echo "$default"
    fi
}

config_set() {
    local key="$1" value="$2" var="OLECHARMS_CFG_$1"
    mkdir -p "$OLECHARMS_CONFIG_DIR"

    # Unchanged and already on disk: install/update re-apply every feature on
    # each run, and should not rewrite the file to say the same thing.
    if [ -n "${!var+x}" ] && [ "${!var}" = "$value" ] \
       && [ -f "$OLECHARMS_CONFIG_FILE" ] && grep -q "^${key}=" "$OLECHARMS_CONFIG_FILE"; then
        return 0
    fi

    # Update in-memory
    printf -v "OLECHARMS_CFG_${key}" '%s' "$value"

    # Update on disk: replace existing line or append
    if [ -f "$OLECHARMS_CONFIG_FILE" ] && grep -q "^${key}=" "$OLECHARMS_CONFIG_FILE"; then
        local tmpfile
        tmpfile=$(mktemp) || { error "mktemp failed"; return 1; }
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "${key}="*) echo "${key}=${value}" ;;
                *)          echo "$line" ;;
            esac
        done < "$OLECHARMS_CONFIG_FILE" > "$tmpfile"
        write_file_contents "$tmpfile" "$OLECHARMS_CONFIG_FILE"
        rm -f "$tmpfile"
    else
        echo "${key}=${value}" >> "$OLECHARMS_CONFIG_FILE"
    fi
}

config_write_all() {
    mkdir -p "$OLECHARMS_CONFIG_DIR"
    cat > "$OLECHARMS_CONFIG_FILE" <<CFG_EOF
# olecharms configuration
CONFIG_VERSION=$(config_get CONFIG_VERSION "$CURRENT_CONFIG_VERSION")

downloads_cleanup_enabled=$(config_get downloads_cleanup_enabled false)
downloads_cleanup_dir=$(config_get downloads_cleanup_dir)
downloads_cleanup_method=$(config_get downloads_cleanup_method hook)
downloads_cleanup_max_age_days=$(config_get downloads_cleanup_max_age_days 30)
# auto: Windows Recycle Bin / macOS Trash when there is one, else quarantine
downloads_cleanup_action=$(config_get downloads_cleanup_action auto)
# Days the quarantine keeps files before they are deleted for good
downloads_cleanup_quarantine_days=$(config_get downloads_cleanup_quarantine_days $CLEANUP_QUARANTINE_DAYS)

paranoid_mode_enabled=$(config_get paranoid_mode_enabled false)
paranoid_mode_method=$(config_get paranoid_mode_method hook)

# WSL only: manage Windows' gVim and fonts too (auto | off)
windows_integration=$(config_get windows_integration auto)

# Run doctor once a day in the background; new shells mention problems (on | off)
daily_doctor=$(config_get daily_doctor on)

install_dir=$(config_get install_dir "$SCRIPT_DIR")
CFG_EOF
}

config_bootstrap() {
    # First run: detect existing state and create config from it
    info "Creating config file at $OLECHARMS_CONFIG_FILE"

    local dl_enabled=false dl_dir="" dl_method=hook dl_age="$DOWNLOADS_MAX_AGE_DAYS"
    local paranoid_enabled=false paranoid_method=hook

    if is_downloads_cleanup_enabled; then
        dl_enabled=true
        # Extract dir from existing cleanup script
        if [ -f "$CLEANUP_SCRIPT" ]; then
            dl_dir=$(grep '^DOWNLOADS_DIR=' "$CLEANUP_SCRIPT" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        fi
        if is_downloads_cron_enabled; then
            dl_method=cron
        fi
    fi

    if is_paranoid_mode_enabled; then
        paranoid_enabled=true
        if is_paranoid_cron_enabled; then
            paranoid_method=cron
        fi
    fi

    printf -v OLECHARMS_CFG_CONFIG_VERSION '%s' "$CURRENT_CONFIG_VERSION"
    printf -v OLECHARMS_CFG_downloads_cleanup_enabled '%s' "$dl_enabled"
    printf -v OLECHARMS_CFG_downloads_cleanup_dir '%s' "$dl_dir"
    printf -v OLECHARMS_CFG_downloads_cleanup_method '%s' "$dl_method"
    printf -v OLECHARMS_CFG_downloads_cleanup_max_age_days '%s' "$dl_age"
    printf -v OLECHARMS_CFG_paranoid_mode_enabled '%s' "$paranoid_enabled"
    printf -v OLECHARMS_CFG_paranoid_mode_method '%s' "$paranoid_method"
    printf -v OLECHARMS_CFG_downloads_cleanup_action '%s' auto
    printf -v OLECHARMS_CFG_windows_integration '%s' auto
    printf -v OLECHARMS_CFG_downloads_cleanup_quarantine_days '%s' "$CLEANUP_QUARANTINE_DAYS"
    printf -v OLECHARMS_CFG_daily_doctor '%s' on
    printf -v OLECHARMS_CFG_install_dir '%s' "$SCRIPT_DIR"

    config_write_all
}

migrate_config() {
    local current
    current=$(config_get CONFIG_VERSION 0)
    if ! [[ "$current" =~ ^[0-9]+$ ]]; then
        warn "Invalid CONFIG_VERSION '$current' in $OLECHARMS_CONFIG_FILE; treating as 0"
        current=0
    fi
    while [ "$current" -lt "$CURRENT_CONFIG_VERSION" ]; do
        local next=$((current + 1))
        local func="migrate_config_${current}_to_${next}"
        if declare -f "$func" >/dev/null 2>&1; then
            info "Migrating config v${current} → v${next}"
            "$func"
        fi
        config_set CONFIG_VERSION "$next"
        current=$next
    done
}

migrate_config_1_to_2() {
    config_set install_dir "$SCRIPT_DIR"
}

migrate_config_2_to_3() {
    config_set downloads_cleanup_action auto
    config_set windows_integration auto
}

migrate_config_3_to_4() {
    config_set downloads_cleanup_quarantine_days "$CLEANUP_QUARANTINE_DAYS"
    config_set daily_doctor on
}

config_ensure() {
    if [ ! -f "$OLECHARMS_CONFIG_FILE" ]; then
        config_bootstrap
    else
        config_read
        migrate_config
    fi
}

# Bring the generated scripts, crontab and RC hook lines in line with the
# config. scripts/ is gitignored, so a fresh clone (or a moved install) has no
# generated cleanup scripts even when the config says a feature is on. Every
# run regenerates them, not only missing ones: that is how a fix to their
# templates reaches an existing install. Cheap and idempotent — the crontab and
# config are only rewritten when something actually differs.
restore_scheduled_features() {
    local dl_enabled dl_dir dl_method dl_age p_enabled p_method

    dl_enabled=$(config_get downloads_cleanup_enabled false)
    if [ "$dl_enabled" = "true" ]; then
        dl_dir=$(config_get downloads_cleanup_dir)
        dl_method=$(config_get downloads_cleanup_method hook)
        dl_age=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
        if [ -z "$dl_dir" ] || [ ! -d "$dl_dir" ]; then
            # Often transient — /mnt/c not mounted on WSL, an external drive —
            # so keep the config and pick the feature back up next run.
            warn "Downloads auto-cleanup is enabled but ${dl_dir:-<unset>} is not reachable; skipping it this run"
        else
            if [ ! -x "$CLEANUP_SCRIPT" ] || { [ "$dl_method" = "cron" ] && ! is_downloads_cron_enabled; }; then
                info "Restoring downloads auto-cleanup ($dl_method)"
            fi
            enable_downloads_cleanup "$dl_dir" "$dl_method" "$dl_age" \
                || error "Could not restore downloads auto-cleanup"
        fi
    fi

    p_enabled=$(config_get paranoid_mode_enabled false)
    if [ "$p_enabled" = "true" ]; then
        p_method=$(config_get paranoid_mode_method hook)
        if [ ! -x "$PARANOID_SCRIPT" ] || { [ "$p_method" = "cron" ] && ! is_paranoid_cron_enabled; }; then
            info "Restoring paranoid mode ($p_method)"
        fi
        enable_paranoid_mode "$p_method" || error "Could not restore paranoid mode"
    fi

    generate_doctor_launcher || error "Could not write the daily doctor launcher"

    # Also covers a hook line lost from an RC file (the Oh My Zsh installer
    # replaces ~/.zshrc) and drops a hook nothing uses any more.
    sync_shell_hook
}

fix_moved_install() {
    local mode="${1:-fix}"
    local stored_dir
    stored_dir=$(config_get install_dir "")
    [ -z "$stored_dir" ] && return
    [ "$stored_dir" = "$SCRIPT_DIR" ] && return

    if [ "$mode" = "warn" ]; then
        warn "Install directory moved: $stored_dir → $SCRIPT_DIR"
        warn "Run 'olecharms install' or 'olecharms update' to fix stale paths."
        return
    fi

    warn "Install directory moved: $stored_dir → $SCRIPT_DIR"
    warn "Updating stale paths..."

    install_vimrc
    install_shell_commands
    install_binary
    # Cron entries, generated scripts and the hook's RC lines hold absolute
    # paths — rewrite them
    restore_scheduled_features

    config_set install_dir "$SCRIPT_DIR"
    info "All paths updated to new location."
}

# ─── Core Operations ─────────────────────────────────────────────────────────

install_packages() {
    local packages=()
    if [ "$OS" = "linux" ]; then
        packages=("${APT_PACKAGES[@]}")
    elif [ "$OS" = "macos" ]; then
        packages=("${BREW_PACKAGES[@]}")
    else
        warn "Skipping package install on unknown OS"
        return
    fi

    if [ ${#packages[@]} -eq 0 ]; then
        warn "No packages defined for this OS"
        return
    fi

    # Filter out already-installed packages
    local missing=()
    if [ "$OS" = "linux" ]; then
        if ! check_command dpkg || ! check_command apt-get; then
            warn "Not a Debian/Ubuntu system — install these yourself: ${packages[*]}"
            return
        fi
        # dpkg -s also succeeds for removed-but-not-purged packages
        # ("deinstall ok config-files"), which would then never come back
        for pkg in "${packages[@]}"; do
            if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
                missing+=("$pkg")
            fi
        done
    elif [ "$OS" = "macos" ]; then
        for pkg in "${packages[@]}"; do
            if ! brew list "$pkg" >/dev/null 2>&1; then
                missing+=("$pkg")
            fi
        done
    fi

    if [ ${#missing[@]} -eq 0 ]; then
        info "All system packages already installed"
        return
    fi

    info "Installing missing packages: ${missing[*]}"
    if [ "$OS" = "linux" ]; then
        # System packages are the one step that needs root; everything else
        # olecharms does stays in userland.
        local sudo_cmd=()
        if [ "$(id -u 2>/dev/null)" != "0" ]; then
            if ! check_command sudo; then
                error "sudo not available. Install packages manually: apt-get install ${missing[*]}"
                return
            fi
            # Without a terminal, sudo would block on a password prompt forever
            if [ ! -t 0 ] && ! sudo -n true 2>/dev/null; then
                warn "sudo needs a password and there is no terminal; skipping: ${missing[*]}"
                return
            fi
            sudo_cmd=(sudo)
        fi
        # One broken third-party source fails `apt-get update`; the packages we
        # want usually still install from the lists already on disk.
        if ! "${sudo_cmd[@]}" apt-get update -qq; then
            warn "apt-get update failed (a broken source?); trying to install anyway"
        fi
        # apt installs nothing when one name is unknown to this release, and
        # packages.conf is shared across distros: retry one by one then.
        if ! "${sudo_cmd[@]}" apt-get install -y -qq "${missing[@]}"; then
            local failed=()
            warn "Batch install failed; installing one package at a time"
            for pkg in "${missing[@]}"; do
                "${sudo_cmd[@]}" apt-get install -y -qq "$pkg" >/dev/null 2>&1 || failed+=("$pkg")
            done
            [ ${#failed[@]} -gt 0 ] && error "Could not install: ${failed[*]} (move distro-specific ones to $LOCAL_CONF_FILE)"
        fi
    elif [ "$OS" = "macos" ]; then
        if check_command brew; then
            if ! brew install "${missing[@]}"; then
                local failed=()
                for pkg in "${missing[@]}"; do
                    brew list "$pkg" >/dev/null 2>&1 || failed+=("$pkg")
                done
                [ ${#failed[@]} -gt 0 ] && error "Could not install: ${failed[*]}"
            fi
        else
            error "Homebrew not found. Install it from https://brew.sh"
        fi
    fi
}

create_vim_dirs() {
    local dirs=( "$VIM_DIR" "$VIM_DIR/autoload" "$VIM_DIR/bundle"
                 "$VIM_DIR/bundle_disabled" "$VIM_DIR/undodir" "$VIM_DIR/swapfiles" )
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
    done
    info "Vim directories created under $VIM_DIR"
}

install_pathogen() {
    # Older versions passed all of vimthings/ (~50MB, mostly fonts) as the
    # offline fallback for the pathogen clone. Reclaim that if we find it.
    if [ -d "$PATHOGEN_STAGING" ] && [ ! -d "$PATHOGEN_STAGING/.git" ] \
       && [ -d "$PATHOGEN_STAGING/fonts" ] && [ -d "$PATHOGEN_STAGING/bundle" ]; then
        warn "Removing oversized legacy pathogen staging dir $PATHOGEN_STAGING"
        rm -rf "$PATHOGEN_STAGING"
    fi

    # No bundled fallback here: pathogen is a single file and the copy below
    # already reads it straight out of vimthings/autoload/.
    clone_or_pull "$PATHOGEN_REPO" "$PATHOGEN_STAGING" "vim-pathogen"

    # Copy pathogen.vim to autoload
    if [ -f "$PATHOGEN_STAGING/autoload/pathogen.vim" ]; then
        cp "$PATHOGEN_STAGING/autoload/pathogen.vim" "$VIM_DIR/autoload/pathogen.vim"
        info "pathogen.vim installed to $VIM_DIR/autoload/"
    elif [ -f "$BUNDLED_DIR/autoload/pathogen.vim" ]; then
        cp "$BUNDLED_DIR/autoload/pathogen.vim" "$VIM_DIR/autoload/pathogen.vim"
        info "pathogen.vim installed from bundled copy"
    else
        error "Could not find pathogen.vim anywhere"
    fi
}

# A plugin name becomes a folder under bundle/, where it is pulled, reset,
# replaced, mirrored with --delete and pruned: it must be one plain folder
# name, or those would act on bundle/ itself or outside it.
plugin_name_valid() {
    case "$1" in
        ""|.|..|-*|*/*|*\\*) return 1 ;;
    esac
    [[ "$1" =~ ^[A-Za-z0-9._+-]+$ ]]
}

install_plugins() {
    if [ ${#VIM_PLUGINS[@]} -eq 0 ]; then
        warn "No plugins defined in packages.conf"
        return
    fi

    for entry in "${VIM_PLUGINS[@]}"; do
        local name="${entry%%|*}"
        local url="${entry#*|}"
        local dest="$VIM_DIR/bundle/$name"
        local fallback="$BUNDLED_DIR/bundle/$name"

        if ! plugin_name_valid "$name"; then
            error "Invalid plugin name '$name' in packages.conf (entry: $entry); skipped"
            continue
        fi
        if ! clone_or_pull "$url" "$dest" "$name" "$fallback"; then
            [ -d "$dest" ] || error "Plugin $name is not installed and could not be fetched"
        fi
    done
    plugins_retire_unlisted
}

# Plugins olecharms cloned that packages.conf no longer lists move to
# bundle_disabled — never deleted. Only names olecharms recorded as its own
# (MANAGED_PLUGINS_FILE) qualify: one put in bundle/ by hand is never
# touched. A mass retirement (packages.conf lost entries?) is not done.
plugins_retire_unlisted() {
    local wanted="|" entry name d n_managed=0 retire=()
    for entry in "${VIM_PLUGINS[@]}"; do
        name="${entry%%|*}"
        plugin_name_valid "$name" && wanted="$wanted$name|"
    done
    if [ -f "$MANAGED_PLUGINS_FILE" ]; then
        while IFS= read -r name; do
            plugin_name_valid "$name" || continue
            n_managed=$((n_managed + 1))
            case "$wanted" in *"|$name|"*) continue ;; esac
            d="$VIM_DIR/bundle/$name"
            [ -d "$d" ] && [ ! -L "$d" ] && retire+=("$name")
        done < "$MANAGED_PLUGINS_FILE"
    fi
    if [ ${#retire[@]} -gt 2 ] && [ $(( ${#retire[@]} * 2 )) -gt "$n_managed" ]; then
        warn "${#retire[@]} of $n_managed plugins are no longer listed — not retiring them in one go."
        warn "If that is intended, move them from $VIM_DIR/bundle by hand: ${retire[*]}"
        return 0
    fi
    for name in ${retire[@]+"${retire[@]}"}; do
        mkdir -p "$VIM_DIR/bundle_disabled"
        if mv "$VIM_DIR/bundle/$name" "$VIM_DIR/bundle_disabled/$name.removed.$(date +%Y%m%d_%H%M%S)"; then
            info "Plugin $name is no longer in packages.conf: moved to $VIM_DIR/bundle_disabled"
        fi
    done
    # What olecharms manages from now on: the listed plugins that are there
    mkdir -p "$OLECHARMS_STATE_DIR" 2>/dev/null
    for entry in "${VIM_PLUGINS[@]}"; do
        name="${entry%%|*}"
        plugin_name_valid "$name" && [ -d "$VIM_DIR/bundle/$name" ] && echo "$name"
    done > "$MANAGED_PLUGINS_FILE"
    return 0
}

# Plugins are cloned from the remote's default branch. When upstream renames
# it (master → main), the shallow single-branch clone keeps pulling the old
# one: stale if upstream left it behind, failing if it was deleted. Follow the
# remote's HEAD whenever it differs, over a clean tree only. Fails (and the
# caller just pulls) when nothing needs following or the remote is unreachable.
plugin_follow_default_branch() {
    local dest="$1" name="$2" head cur
    cur=$(git -C "$dest" symbolic-ref --short -q HEAD 2>/dev/null) || return 1
    head=$(_git_net -C "$dest" ls-remote --symref origin HEAD 2>/dev/null |
        awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }')
    [ -n "$head" ] && [ "$head" != "$cur" ] || return 1
    if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
        warn "$name: upstream's default branch is now $head, but the plugin has local changes; not switching"
        return 1
    fi
    git -C "$dest" remote set-branches origin "$head" 2>/dev/null &&
        _git_net -C "$dest" fetch -q --depth 1 origin "$head" 2>/dev/null &&
        git -C "$dest" checkout -q -B "$head" "origin/$head" 2>/dev/null || return 1
    info "$name: followed upstream's default branch rename to $head"
}

install_vimrc() {
    if [ -f "$VIMRC" ]; then
        # Count what is already there: our exact line, source lines pointing at
        # some other checkout, and marker comments.
        local exact=0 stale=0 markers=0 line
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$SOURCE_MARKER")            markers=$((markers + 1)) ;;
                "$SOURCE_LINE")              exact=$((exact + 1)) ;;
                *"/vimthings/olevimrc.vim"*) stale=$((stale + 1)) ;;
            esac
        done < "$VIMRC"

        if [ "$exact" -eq 1 ] && [ "$stale" -eq 0 ] && [ "$markers" -eq 1 ]; then
            info "vimrc source line already present in $VIMRC"
            return
        fi

        backup_file "$VIMRC" || return 1

        # Strip every olecharms entry (duplicates, stale paths, orphaned marker
        # comments) and re-append a single clean block below.
        if [ $((exact + stale + markers)) -gt 0 ]; then
            rc_strip_block "$VIMRC" "$SOURCE_MARKER" "/vimthings/olevimrc.vim" || return 1
            info "Removed stale olecharms entries from $VIMRC"
        fi
    fi

    # Append fresh
    append_block "$VIMRC" "$SOURCE_MARKER" "$SOURCE_LINE"
    info "Added source line to $VIMRC"
}

install_fonts() {
    mkdir -p "$FONT_DIR"

    # Try cloning the powerline fonts repo
    if [ -n "$POWERLINE_FONTS_REPO" ]; then
        clone_or_pull "$POWERLINE_FONTS_REPO" "$FONTS_STAGING" "powerline-fonts" \
            "$BUNDLED_DIR/fonts/powerline"
    fi

    # Determine source directory for fonts
    local font_source=""
    if [ -d "$FONTS_STAGING" ] && [ -n "$(ls -A "$FONTS_STAGING" 2>/dev/null)" ]; then
        font_source="$FONTS_STAGING"
    elif [ -d "$BUNDLED_DIR/fonts/powerline" ]; then
        font_source="$BUNDLED_DIR/fonts/powerline"
        info "Using bundled fonts"
    else
        error "No font source available"
        return
    fi

    # Copy selected font families
    local family f copied
    for family in "${FONT_FAMILIES[@]}"; do
        if [ ! -d "$font_source/$family" ]; then
            warn "Font family not found: $family"
            continue
        fi
        copied=0
        for f in "$font_source/$family"/*.ttf "$font_source/$family"/*.otf; do
            [ -f "$f" ] || continue
            cp "$f" "$FONT_DIR/" 2>/dev/null && copied=$((copied + 1))
        done
        if [ "$copied" -gt 0 ]; then
            info "Installed font family: $family ($copied files)"
        else
            warn "No font files found for family: $family"
        fi
    done

    # Rebuild font cache on Linux
    if [ "$OS" = "linux" ] && check_command fc-cache; then
        fc-cache -f "$FONT_DIR"
        info "Font cache updated"
    fi
}

# Make an existing ~/.zshrc load oh-my-zsh (kept by the installer): prepend
# the template's essentials, so the user's own lines still come after it and
# win over oh-my-zsh's aliases and settings.
omz_add_to_zshrc() {
    local omz_dir="$1" zshrc="$HOME/.zshrc" tmp zsh_path
    grep -qE '^[[:space:]]*(source|\.)[[:space:]].*oh-my-zsh\.sh' "$zshrc" 2>/dev/null && return 0
    zsh_path="$omz_dir"
    [ "$omz_dir" = "$HOME/.oh-my-zsh" ] && zsh_path='$HOME/.oh-my-zsh'
    backup_file "$zshrc"
    tmp=$(mktemp) || return 1
    {
        echo "# Oh My Zsh (added by olecharms; your own settings follow)"
        echo "export ZSH=\"$zsh_path\""
        echo 'ZSH_THEME="olecharms"'
        echo 'plugins=(git)'
        echo 'source $ZSH/oh-my-zsh.sh'
        echo ""
        cat "$zshrc"
    } > "$tmp"
    write_file_contents "$tmp" "$zshrc"
    rm -f "$tmp"
    info "Added Oh My Zsh to the top of your existing $zshrc"
}

install_omz() {
    if ! check_command zsh; then
        error "zsh is not installed. Install it manually: sudo apt-get install zsh"
        return 1
    fi

    # Honour $ZSH / $ZSH_CUSTOM: the upstream installer does, and reinstalling
    # over an existing non-default checkout fails on every run otherwise.
    local omz_dir="${ZSH:-$HOME/.oh-my-zsh}"

    # Install Oh My Zsh if not present
    if [ ! -d "$omz_dir" ]; then
        info "Installing Oh My Zsh into $omz_dir..."
        local url=https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh installer="" keep=no
        if check_command curl; then
            installer=$(curl -fsSL --connect-timeout 15 --max-time 120 "$url")
        elif check_command wget; then
            installer=$(wget -qO- -T 30 -t 2 "$url")
        else
            error "Neither curl nor wget available. Cannot install Oh My Zsh."
            return 1
        fi
        if [ -z "$installer" ]; then
            error "Could not download the Oh My Zsh installer (offline?)"
            return 1
        fi
        # The installer moves an existing ~/.zshrc aside and puts its template
        # in its place: the user's own config stops loading, and a dotfiles
        # symlink becomes a plain file. Keep it, and add oh-my-zsh to it.
        [ -e "$HOME/.zshrc" ] && keep=yes
        KEEP_ZSHRC=$keep sh -c "$installer" "" --unattended

        # Verify the install actually worked
        if [ ! -d "$omz_dir" ]; then
            error "Oh My Zsh installation failed"
            return 1
        fi
        [ "$keep" = yes ] && omz_add_to_zshrc "$omz_dir"
    else
        info "Oh My Zsh already installed ($omz_dir)"
    fi

    # Create custom theme with random host color (only on first install)
    local theme_dir="${ZSH_CUSTOM:-$omz_dir/custom}/themes"
    local theme_file="$theme_dir/olecharms.zsh-theme"

    if [ -f "$theme_file" ]; then
        info "olecharms theme already exists (preserving existing color)"
    else
        mkdir -p "$theme_dir"

        # Generate random HSL and convert to RGB for a bright, readable color
        # H: 0-359, S: 70-90%, L: 50-70%
        local h=$(( RANDOM % 360 ))
        local s=$(( 70 + RANDOM % 21 ))
        local l=$(( 50 + RANDOM % 21 ))
        local rgb
        rgb=$(awk -v h="$h" -v s="$s" -v l="$l" 'BEGIN {
            s = s / 100; l = l / 100
            c = (1 - (2*l - 1 < 0 ? 1 - 2*l : 2*l - 1)) * s
            hp = h / 60.0
            hmod2 = hp - 2 * int(hp / 2)
            x = c * (1 - (hmod2 - 1 < 0 ? 1 - hmod2 : hmod2 - 1))
            if (hp < 1)      { r1 = c; g1 = x; b1 = 0 }
            else if (hp < 2) { r1 = x; g1 = c; b1 = 0 }
            else if (hp < 3) { r1 = 0; g1 = c; b1 = x }
            else if (hp < 4) { r1 = 0; g1 = x; b1 = c }
            else if (hp < 5) { r1 = x; g1 = 0; b1 = c }
            else              { r1 = c; g1 = 0; b1 = x }
            m = l - c / 2
            printf "%d;%d;%d", int((r1+m)*255+0.5), int((g1+m)*255+0.5), int((b1+m)*255+0.5)
        }')

        cat > "$theme_file" <<THEME_EOF
# olecharms.zsh-theme — based on pmcgee with unique host color
if [ \$UID -eq 0 ]; then NCOLOR="red"; else NCOLOR="green"; fi

HOST_COLOR=\$'\\e[38;2;${rgb}m'

PROMPT='
%{\$fg[\$NCOLOR]%}%B%n@%{\$HOST_COLOR%}%m%b%{\$reset_color%} %{\$fg[white]%}%B\${PWD/#\$HOME/~}%b%{\$reset_color%}
\$(git_prompt_info)%(!.#.\$) '
RPROMPT='[%*]'

# git theming
ZSH_THEME_GIT_PROMPT_PREFIX="%{\$fg_no_bold[yellow]%}%B"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{\$reset_color%} "
ZSH_THEME_GIT_PROMPT_CLEAN=""
ZSH_THEME_GIT_PROMPT_DIRTY="%{\$fg_bold[red]%}*"

# LS colors, made with https://geoff.greer.fm/lscolors/
export LSCOLORS="Gxfxcxdxbxegedabagacad"
export LS_COLORS='no=00:fi=00:di=01;34:ln=00;36:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=41;33;01:ex=00;32:*.cmd=00;32:*.exe=01;32:*.com=01;32:*.bat=01;32:*.btm=01;32:*.dll=01;32:*.tar=00;31:*.tbz=00;31:*.tgz=00;31:*.rpm=00;31:*.deb=00;31:*.arj=00;31:*.taz=00;31:*.lzh=00;31:*.lzma=00;31:*.zip=00;31:*.zoo=00;31:*.z=00;31:*.Z=00;31:*.gz=00;31:*.bz2=00;31:*.tb2=00;31:*.tz2=00;31:*.tbz2=00;31:*.avi=01;35:*.bmp=01;35:*.fli=01;35:*.gif=01;35:*.jpg=01;35:*.jpeg=01;35:*.mng=01;35:*.mov=01;35:*.mpg=01;35:*.pcx=01;35:*.pbm=01;35:*.pgm=01;35:*.png=01;35:*.ppm=01;35:*.tga=01;35:*.tif=01;35:*.xbm=01;35:*.xpm=01;35:*.dl=01;35:*.gl=01;35:*.wmv=01;35:*.aiff=00;32:*.au=00;32:*.mid=00;32:*.mp3=00;32:*.ogg=00;32:*.voc=00;32:*.wav=00;32:'
THEME_EOF

        info "Created olecharms theme with host color rgb($rgb)"
    fi

    # Configure .zshrc
    local zshrc="$HOME/.zshrc"
    if [ -f "$zshrc" ]; then
        # Set ZSH_THEME to olecharms (leave the file alone when it already is)
        if grep -q '^ZSH_THEME="olecharms"$' "$zshrc"; then
            :
        elif grep -q '^ZSH_THEME=' "$zshrc"; then
            sed_inplace "$zshrc" 's/^ZSH_THEME=.*/ZSH_THEME="olecharms"/'
            info "Updated ZSH_THEME to olecharms in $zshrc"
        else
            echo 'ZSH_THEME="olecharms"' >> "$zshrc"
            info "Added ZSH_THEME=olecharms to $zshrc"
        fi

        # Add COLORTERM if not present
        if ! grep -q 'export COLORTERM=truecolor' "$zshrc"; then
            echo 'export COLORTERM=truecolor' >> "$zshrc"
            info "Added COLORTERM=truecolor to $zshrc"
        fi
    else
        warn "No .zshrc found — skipping theme configuration"
    fi
}

run_post_commands() {
    if [ -z "${POST_INSTALL_COMMANDS+x}" ] || [ ${#POST_INSTALL_COMMANDS[@]} -eq 0 ]; then
        return
    fi

    info "Running post-install commands..."
    for cmd in "${POST_INSTALL_COMMANDS[@]}"; do
        info "  → $cmd"
        eval "$cmd" || warn "Post-install command failed: $cmd"
    done
}

# ─── Subcommand Handlers ─────────────────────────────────────────────────────

_self_update() {
    # Set by the relaunch below so a bad hash comparison can't loop forever
    if [ -n "${OLECHARMS_RELAUNCHED:-}" ]; then
        # Exported by the relaunch: keep it from reaching the login zsh that
        # install execs, where every later update would skip this step.
        unset OLECHARMS_RELAUNCHED
        return
    fi
    if [ -d "$SCRIPT_DIR/.git" ]; then
        info "Updating olecharms repo..."
        local before_script before_conf
        before_script=$(_file_hash "$SCRIPT_PATH")
        before_conf=$(_file_hash "$CONF_FILE")

        # packages.conf is tracked: local edits collide with the pull below
        if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain -- "$(basename "$CONF_FILE")" 2>/dev/null)" ]; then
            warn "packages.conf has local changes. Move them to $LOCAL_CONF_FILE, which updates never touch."
        fi
        checkout_pull
        [ $? -eq 2 ] && warn "Could not update olecharms repo${CHECKOUT_PULL_ERR:+: $CHECKOUT_PULL_ERR}"

        local after_script after_conf
        after_script=$(_file_hash "$SCRIPT_PATH")
        after_conf=$(_file_hash "$CONF_FILE")

        if [ "$before_script" != "$after_script" ] || [ "$before_conf" != "$after_conf" ]; then
            if ! bash -n "$SCRIPT_PATH" 2>/dev/null; then
                error "Updated $SCRIPT_PATH has syntax errors — not relaunching"
                return 1
            fi
            info "olecharms.sh or packages.conf was updated. Relaunching..."
            # Through bash rather than the file itself: a checkout that lost
            # its exec bit (/mnt/c on WSL, core.fileMode=false, a zip
            # download) would otherwise kill the update half-way.
            OLECHARMS_RELAUNCHED=1 exec bash "$SCRIPT_PATH" "$@"
        fi
    fi
}

# Hashes of everything a running shell has already read, to tell afterwards
# whether it is now stale.
shell_config_snapshot() {
    local f
    for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$SHELL_LOADER" "$ALIAS_FILE" "$GLOBAL_ALIAS_FILE"; do
        printf '%s ' "$(_file_hash "$f")"
    done
}

# True when the shell that started us is a zsh
parent_is_zsh() {
    case "$(ps -o comm= -p "$PPID" 2>/dev/null)" in
        *zsh*) return 0 ;;
    esac
    return 1
}

# The steps shared by install and update, in order
# ─── Zsh extras ─────────────────────────────────────────────────────────────

# Clone or fast-forward one zsh plugin into ZSH_EXTRAS_DIR. Never deletes:
# a folder there that is not a git checkout is left alone.
zsh_extra_fetch() {
    local name="$1" url="$2" dest="$ZSH_EXTRAS_DIR/$1"
    case "$name" in ""|*/*|.*) error "Bad plugin name: $name"; return 1 ;; esac
    if [ -d "$dest/.git" ]; then
        _git_net -C "$dest" pull -q --ff-only 2>/dev/null || warn "Could not update $name (offline?)"
        return 0
    fi
    if [ -e "$dest" ]; then
        warn "$dest exists but is not a git checkout; leaving it as it is"
        return 1
    fi
    info "Installing $name..."
    _git_net clone -q --depth 1 "$url" "$dest" 2>/dev/null || {
        rm -rf -- "${dest:?}" 2>/dev/null
        warn "Could not install $name (offline?); the next update tries again"
        return 1
    }
}

install_zsh_extras() {
    [ "$(config_get zsh_extras on)" = off ] && return 0
    mkdir -p "$ZSH_EXTRAS_DIR" || { error "Could not create $ZSH_EXTRAS_DIR"; return 1; }
    local entry
    for entry in "${ZSH_EXTRA_PLUGINS[@]}"; do
        zsh_extra_fetch "${entry%%|*}" "${entry#*|}"
    done
    check_command fzf || warn "fzf is not installed yet: it comes from the package lists (packages.conf)"
    return 0
}

config_zsh_extras() {
    echo "  Zsh extras, for new shells:"
    echo "    - fzf (bash and zsh): Ctrl-R searches your history, Ctrl-T inserts a file path,"
    echo "      Alt-C jumps into a folder; in aliaslast you can type to filter"
    echo "    - zsh: grey suggestions as you type (→ accepts one) and colours: a command"
    echo "      that does not exist turns red before you press Enter"
    echo ""
    if [ "$(config_get zsh_extras on)" = on ]; then
        confirm_default_no "  They are on. Turn them off?" || { info "No changes made"; return 0; }
        config_set zsh_extras off
        install_shell_commands >/dev/null
        info "Zsh extras off from the next shell"
    else
        confirm_default_yes "  They are off. Turn them on?" || { info "No changes made"; return 0; }
        config_set zsh_extras on
        install_zsh_extras
        install_shell_commands >/dev/null
        info "Zsh extras on from the next shell$(check_command fzf || echo "; fzf arrives with the next 'olecharms update'")"
    fi
}

run_setup_steps() {
    ensure_local_conf_template
    install_packages
    create_vim_dirs
    install_pathogen
    install_plugins
    install_vimrc
    install_fonts
    install_omz
    install_zsh_extras
    run_post_commands
    install_shell_commands
    install_binary
    install_editor_env
    restore_scheduled_features
    sync_windows_side
}

cmd_install() {
    echo -e "${BOLD}olecharms install${NC}"
    echo ""

    load_config || return 1

    # Self-update: pull the olecharms repo
    _self_update install

    run_setup_steps

    echo ""
    if [ $ERROR_COUNT -eq 0 ]; then
        info "Install complete! No errors."
    else
        warn "Install complete with $ERROR_COUNT error(s). Review output above."
    fi
    # A new machine: offer the settings shared from the others
    shared_offer_after_pull

    # Show the result in a zsh — only with a terminal, otherwise this hangs
    # scripted/CI runs and hides the exit status. Never nest one shell inside
    # another: the `olecharms` shell function replaces the calling shell
    # itself, and from a zsh started some other way we only say how.
    if [ $ERROR_COUNT -eq 0 ] && [ -t 0 ] && [ -t 1 ] && check_command zsh; then
        if [ -n "${OLECHARMS_SHELL_WRAPPER:-}" ]; then
            :
        elif parent_is_zsh; then
            info "Run 'exec zsh -l' to load the new configuration in this shell."
        else
            info "Launching zsh..."
            exec zsh -l
        fi
    fi
    return 0
}

cmd_update() {
    echo -e "${BOLD}olecharms update${NC}"
    echo ""

    load_config || return 1

    # Self-update: pull the olecharms repo
    _self_update update

    local before
    before=$(shell_config_snapshot)

    run_setup_steps

    echo ""
    if [ $ERROR_COUNT -eq 0 ]; then
        info "Update complete! No errors."
    else
        warn "Update complete with $ERROR_COUNT error(s). Review output above."
    fi
    if [ "$(shell_config_snapshot)" != "$before" ]; then
        info "Shell configuration changed — run 'exec zsh' (or open a new terminal) to load it."
    fi
    shared_offer_after_pull
}

# ─── Doctor ─────────────────────────────────────────────────────────────────

DOC_OK=0
DOC_WARN=0
DOC_FAIL=0
doc_ok()      { echo -e "  ${GREEN}✓${NC} $*"; DOC_OK=$((DOC_OK + 1)); }
doc_warn()    { echo -e "  ${YELLOW}~${NC} $*"; DOC_WARN=$((DOC_WARN + 1)); }
doc_fail()    { echo -e "  ${RED}✗${NC} $*"; DOC_FAIL=$((DOC_FAIL + 1)); [ -n "$DOC_FIRST_FAIL" ] || DOC_FIRST_FAIL="$*"; }
doc_hint() {
    echo -e "      ${BLUE}→${NC} $*"
    # Network steps that `doctor --fix` can run at the end, after asking
    case "$*" in
        "olecharms update"*) DOC_WANTS_UPDATE=1 ;;
        "olecharms sync"*)   DOC_WANTS_SYNC=1 ;;
    esac
}
doc_section() { echo ""; echo -e "${BLUE}$*:${NC}"; }
# Why a warning matters, in plain words, between the warning and its hint
doc_why()     { echo "      $*"; }

# A repair that changes something outside olecharms' own files, so
# `doctor --fix` asks first: $1 question, $2... the command to run
DOC_OFFER_Q=()
DOC_OFFER_CMD=()
doc_offer() {
    local q="$1" cmd
    shift
    cmd=$(printf '%s\037' "$@")
    DOC_OFFER_Q+=("$q")
    DOC_OFFER_CMD+=("${cmd%$'\037'}")
}

# Ask about each offered repair and run the accepted ones; then offer the
# network steps (update / sync) that some checks asked for
doctor_apply_offers() {
    local i n=${#DOC_OFFER_Q[@]} parts done_any=""
    if [ ! -t 0 ]; then
        [ "$n" -gt 0 ] && echo "Some repairs need your OK; run 'olecharms doctor --fix' in a terminal."
        return 0
    fi
    if [ "$n" -gt 0 ] || [ -n "$DOC_WANTS_UPDATE$DOC_WANTS_SYNC" ]; then
        echo ""
        echo -e "${BOLD}Repairs that need your OK${NC}"
    fi
    for ((i = 0; i < n; i++)); do
        echo ""
        if confirm_default_no "${DOC_OFFER_Q[$i]}"; then
            IFS=$'\037' read -r -a parts <<< "${DOC_OFFER_CMD[$i]}"
            if "${parts[@]}"; then
                info "Done"
                done_any=1
            else
                warn "That repair did not complete"
            fi
        else
            echo "  Left as it is."
        fi
    done
    if [ -n "$DOC_WANTS_UPDATE" ]; then
        echo ""
        if confirm_default_no "Run 'olecharms update' now (installs the missing packages, plugins and fonts; needs the network)?"; then
            bash "$SCRIPT_PATH" update && done_any=1
        fi
    elif [ -n "$DOC_WANTS_SYNC" ]; then
        echo ""
        if confirm_default_no "Run 'olecharms sync' now (fetches the latest olecharms and your global aliases)?"; then
            bash "$SCRIPT_PATH" sync && done_any=1
        fi
    fi
    [ -n "$done_any" ]
}

# True if generated file $1 carries the current generator stamp
generated_current() {
    grep -qxF "$GENERATOR_STAMP $GENERATOR_VERSION" "$1" 2>/dev/null
}

# The user's login shell, from the account database rather than $SHELL
login_shell() {
    local sh=""
    if [ "$(uname -s)" = "Darwin" ]; then
        sh=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{ print $2 }')
    elif check_command getent; then
        sh=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
    fi
    echo "${sh:-${SHELL:-}}"
}

# Directory holding autojump.{bash,zsh}, as the shell loader looks for it
autojump_script_dir() {
    local d
    for d in "$HOME/.autojump/share/autojump" /usr/share/autojump \
             /opt/homebrew/share/autojump /usr/local/share/autojump; do
        if [ -f "$d/autojump.zsh" ] || [ -f "$d/autojump.bash" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

doctor_check_commands() {
    doc_section "System commands"
    local cmd cmds="git vim curl zsh ag autojump"
    [ "$OS" = "linux" ] && cmds="$cmds fc-cache"
    for cmd in $cmds; do
        if check_command "$cmd"; then
            doc_ok "$cmd  ($(command -v "$cmd"))"
        else
            doc_fail "$cmd not found"
            doc_hint "olecharms update installs the system packages"
        fi
    done
}

doctor_check_launcher() {
    doc_section "Launcher"
    local target
    if [ -L "$BIN_DIR/olecharms" ]; then
        target=$(resolve_link "$BIN_DIR/olecharms")
        if [ "$target" = "$SCRIPT_PATH" ]; then
            doc_ok "$BIN_DIR/olecharms → $SCRIPT_PATH"
        elif [ -f "$target" ]; then
            doc_warn "$BIN_DIR/olecharms points at another checkout: $target"
        else
            doc_fail "$BIN_DIR/olecharms is a broken link → $target"
            doc_hint "olecharms doctor --fix"
        fi
    elif [ -e "$BIN_DIR/olecharms" ]; then
        doc_warn "$BIN_DIR/olecharms is a regular file, not managed by olecharms"
    else
        doc_fail "$BIN_DIR/olecharms is not installed"
        doc_hint "olecharms doctor --fix"
    fi
    if [ -x "$SCRIPT_PATH" ]; then
        doc_ok "$SCRIPT_PATH is executable"
    else
        doc_fail "$SCRIPT_PATH is not executable"
        doc_hint "chmod +x \"$SCRIPT_PATH\""
    fi
    if echo "$PATH" | tr ':' '\n' | grep -qxF -- "$BIN_DIR"; then
        doc_ok "$BIN_DIR is on PATH"
    elif grep -qsF "$BIN_MARKER" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; then
        doc_warn "$BIN_DIR is added to PATH by your RC files, but not in this shell yet"
    else
        doc_fail "$BIN_DIR is not on PATH"
        doc_hint "olecharms doctor --fix"
    fi
}

doctor_check_shell() {
    doc_section "Shell integration"
    local rc found sh d
    if [ ! -f "$SHELL_LOADER" ]; then
        doc_fail "Shell loader missing ($SHELL_LOADER)"
        doc_hint "olecharms doctor --fix"
    elif generated_current "$SHELL_LOADER"; then
        doc_ok "Shell loader up to date"
    else
        doc_warn "The file that loads olecharms into your shell is from an older olecharms version"
        doc_why "New commands and fixes in it are missing until it is regenerated."
        doc_hint "olecharms doctor --fix"
    fi
    while IFS= read -r rc; do
        if loader_before_omz "$rc"; then
            doc_warn "$rc loads olecharms before oh-my-zsh — oh-my-zsh aliases override yours"
            doc_hint "olecharms doctor --fix"
        elif grep -qF "source \"$SHELL_LOADER\"" "$rc" 2>/dev/null; then
            doc_ok "$rc loads the olecharms shell commands"
        elif grep -qF "$SHELL_MARKER" "$rc" 2>/dev/null; then
            doc_fail "$rc loads the shell commands from an old location"
            doc_hint "olecharms doctor --fix"
        else
            doc_fail "$rc does not load the olecharms shell commands"
            doc_hint "olecharms doctor --fix"
        fi
    done < <(managed_rc_files)
    found=""
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        grep -qF "$EDITOR_MARKER" "$rc" 2>/dev/null && found=1
    done
    if [ -n "$found" ]; then
        doc_ok "EDITOR=vim exported"
    else
        doc_warn "EDITOR=vim is not set by olecharms"
        doc_hint "olecharms doctor --fix"
    fi
    doc_ok "$(alias_count) aliases on this machine ($ALIAS_FILE), $(alias_count "$GLOBAL_ALIAS_FILE") global"
    if check_command autojump; then
        if d=$(autojump_script_dir); then
            doc_ok "autojump activated by the shell loader ($d)"
        else
            doc_warn "autojump is installed but no autojump.zsh/autojump.bash was found to activate it"
        fi
    fi
    doctor_check_clipboard
    doctor_check_secrets
    sh=$(login_shell)
    case "$sh" in
        *zsh) doc_ok "Login shell is $sh" ;;
        *)
            local zsh_path
            zsh_path=$(command -v zsh 2>/dev/null || echo /bin/zsh)
            doc_warn "Login shell is ${sh:-unknown}, not zsh"
            doc_why "New terminals and SSH logins start ${sh##*/} without the olecharms prompt; you have to type zsh each time."
            doc_hint "chsh -s \"$zsh_path\"  (olecharms doctor --fix runs it; it asks for your password)"
            if [ -x "$zsh_path" ] && grep -qxF "$zsh_path" /etc/shells 2>/dev/null && check_command chsh; then
                doc_offer "Make zsh your login shell (runs: chsh -s $zsh_path, asks for your password)?" chsh -s "$zsh_path"
            fi
            ;;
    esac
}

# Lines of ~/.vimrc that are neither olecharms' two lines nor part of any
# version of olevimrc.vim (old installs pasted a whole copy): the user's own
vimrc_own_lines() {
    local known
    known=$(mktemp) || return 1
    {
        cat "$BUNDLED_DIR/olevimrc.vim"
        if [ -d "$SCRIPT_DIR/.git" ]; then
            local h
            for h in $(git -C "$SCRIPT_DIR" log --format=%H -- vimthings/olevimrc.vim 2>/dev/null); do
                git -C "$SCRIPT_DIR" show "$h:vimthings/olevimrc.vim" 2>/dev/null
            done
        fi
        # The copy older installs (configure.sh) pasted predates this repo
        cat <<'LEGACY_EOF'
set undodir=$HOME/vimfiles/undodir
set directory=$HOME/vimfiles/swapfiles
map <leader>v :sp $VIMRUNTIME/olevimrc.vim<CR><C-W>_
map <silent> <leader>V :source $VIMRUNTIME/olevimrc.vim<CR>:filetype detect<CR>:exe ":echo 'vimrc reloaded'"<CR>
LEGACY_EOF
    } > "$known"
    awk -v marker="$SOURCE_MARKER" '
        function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
        NR == FNR { known[trim($0)] = 1; next }
        { line = trim($0) }
        line == "" || line == marker || line ~ /^source .*\/vimthings\/olevimrc\.vim$/ { next }
        !(line in known) { print }
    ' "$known" "$VIMRC"
    rm -f "$known"
}

# ~/.vimrc down to olecharms' two lines (the doctor showed any other line)
vimrc_remove_old_copy() {
    backup_file "$VIMRC" || return 1
    # Rewrite in place: keeps the file's permissions
    printf '%s\n%s\n' "$SOURCE_MARKER" "$SOURCE_LINE" > "$VIMRC" || return 1
    info "$VIMRC now only loads the olecharms config"
}

# The clipboard behind `copy` / `paste` and terminal Vim's "+ register
doctor_check_clipboard() {
    local clip="$SCRIPT_DIR/bin/olecharms-clip"
    if [ ! -f "$clip" ]; then
        doc_fail "Clipboard helper missing ($clip)"
        doc_hint "olecharms sync"
        return
    fi
    case "$(sh "$clip" backend 2>/dev/null)" in
        mac)     doc_ok "Clipboard: pbcopy / pbpaste (copy, paste, terminal Vim)" ;;
        wsl)
            if check_command win32yank.exe; then
                doc_ok "Clipboard: Windows clipboard via win32yank.exe (copy, paste, terminal Vim)"
            else
                doc_ok "Clipboard: Windows clipboard via clip.exe / PowerShell (paste takes a second or two; win32yank.exe on PATH makes it instant)"
            fi ;;
        wayland) doc_ok "Clipboard: wl-copy / wl-paste (copy, paste, terminal Vim)" ;;
        x11)     doc_ok "Clipboard: X11 via $(check_command xclip && echo xclip || echo xsel) (copy, paste, terminal Vim)" ;;
        ssh)     doc_ok "Clipboard: over SSH, copies go to your local terminal (OSC 52); paste with the terminal" ;;
        *)
            if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                doc_warn "No clipboard tool: copy, paste and Vim's \"+ register cannot reach the desktop clipboard"
                doc_hint "Install one: wl-clipboard (Wayland) or xclip (X11), e.g. via $LOCAL_CONF_FILE"
            else
                doc_ok "Clipboard: none on this machine (no desktop); over SSH, copy reaches your local terminal"
            fi ;;
    esac
}

# fzf and the zsh plugins (printed under the zsh section)
doctor_check_zsh_extras() {
    if [ "$(config_get zsh_extras on)" = off ]; then
        doc_ok "Zsh extras off (olecharms config → Zsh extras)"
        return
    fi
    if check_command fzf; then
        doc_ok "fzf $(fzf --version 2>/dev/null | cut -d' ' -f1): Ctrl-R history, Ctrl-T files, Alt-C folders"
    else
        doc_warn "fzf is not installed: no Ctrl-R / Ctrl-T / Alt-C search, no type-to-filter in aliaslast"
        doc_hint "olecharms update"
    fi
    local entry name missing=""
    for entry in "${ZSH_EXTRA_PLUGINS[@]}"; do
        name=${entry%%|*}
        [ -f "$ZSH_EXTRAS_DIR/$name/$name.zsh" ] || missing="$missing $name"
    done
    if [ -z "$missing" ]; then
        doc_ok "Suggestions as you type and syntax colours (zsh)"
    else
        doc_warn "Not installed:$missing (suggestions / syntax colours in zsh)"
        doc_hint "olecharms update"
    fi
}

doctor_check_vim() {
    doc_section "Vim"
    local d entry name dest missing=0 total=0
    for d in autoload bundle undodir swapfiles; do
        if [ ! -d "$VIM_DIR/$d" ]; then
            doc_fail "$VIM_DIR/$d missing"
            doc_hint "olecharms doctor --fix"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] && doc_ok "Vim directories present under $VIM_DIR"
    if [ -f "$VIM_DIR/autoload/pathogen.vim" ]; then
        doc_ok "pathogen.vim installed"
    else
        doc_fail "pathogen.vim missing"
        doc_hint "olecharms update"
    fi
    missing=0
    for entry in "${VIM_PLUGINS[@]}"; do
        name="${entry%%|*}"
        dest="$VIM_DIR/bundle/$name"
        total=$((total + 1))
        if [ ! -d "$dest" ]; then
            doc_fail "Plugin $name not installed"
            missing=$((missing + 1))
        elif [ ! -d "$dest/.git" ]; then
            doc_warn "Plugin $name is a bundled copy (no git; updates when online)"
        fi
    done
    if [ "$missing" -eq 0 ]; then
        doc_ok "$total/$total plugins installed"
    else
        doc_hint "olecharms update"
    fi
    if [ -f "$VIMRC" ] && grep -qxF "$SOURCE_LINE" "$VIMRC"; then
        doc_ok "$VIMRC sources the olecharms config"
    else
        doc_fail "$VIMRC does not source the olecharms config"
        doc_hint "olecharms doctor --fix"
    fi
    # Old installs appended a whole copy of olevimrc.vim to ~/.vimrc
    if [ -f "$VIMRC" ] && grep -qF '" author: @olemoudi' "$VIMRC"; then
        local own
        own=$(vimrc_own_lines | grep -c .)
        doc_warn "$VIMRC still holds an old pasted copy of the olecharms Vim config, so Vim reads it twice"
        doc_why "The current config is read last and wins, but the copy brings old settings back, e.g. Windows-style"
        doc_why "keys in terminal Vim (Ctrl-V pastes, Ctrl-A selects all, Ctrl-Z undoes). Without the copy, terminal"
        doc_why "Vim keeps Vim's own keys; Ctrl-C still copies to the system clipboard and Ctrl-S saves."
        if [ "$own" -gt 0 ] && [ "$own" -le 10 ]; then
            doc_why "These $own line(s) are not from any olecharms version; removing the copy removes them too:"
            vimrc_own_lines | sed 's/^/          /'
        fi
        if [ "$own" -le 10 ] && [ ! -L "$VIMRC" ]; then
            doc_hint "olecharms doctor --fix (removes the copy, keeping a backup)"
            doc_offer "Remove the old copy from $VIMRC, keeping only the two olecharms lines (a backup is kept)?" vimrc_remove_old_copy
        else
            doc_hint "Edit $VIMRC by hand: keep your own lines ($own not from olecharms) and the two olecharms lines at the end"
        fi
    fi
    # Font files are named with spaces ("DejaVu Sans Mono for Powerline.ttf"),
    # families without ("DejaVuSansMono"): compare with spaces removed.
    local family count font base
    for family in "${FONT_FAMILIES[@]}"; do
        count=0
        for font in "$FONT_DIR"/*; do
            [ -f "$font" ] || continue
            base=$(basename "$font")
            case "${base// /}" in *"$family"*) count=$((count + 1)) ;; esac
        done
        if [ "$count" -gt 0 ]; then
            doc_ok "Font $family ($count files in $FONT_DIR)"
        else
            doc_fail "Font $family not found in $FONT_DIR"
            doc_hint "olecharms update"
        fi
    done
}

doctor_check_zsh() {
    doc_section "Zsh / Oh My Zsh"
    local omz_dir="${ZSH:-$HOME/.oh-my-zsh}" theme
    if [ -d "$omz_dir" ]; then
        doc_ok "Oh My Zsh at $omz_dir"
    else
        doc_fail "Oh My Zsh not installed"
        doc_hint "olecharms update"
        return
    fi
    theme="${ZSH_CUSTOM:-$omz_dir/custom}/themes/olecharms.zsh-theme"
    if [ -f "$theme" ]; then
        doc_ok "olecharms theme present"
    else
        doc_fail "olecharms theme missing ($theme)"
        doc_hint "olecharms update"
    fi
    if grep -q '^ZSH_THEME="olecharms"' "$HOME/.zshrc" 2>/dev/null; then
        doc_ok "~/.zshrc uses the olecharms theme"
    else
        doc_warn "~/.zshrc does not select the olecharms theme"
        doc_hint "olecharms update"
    fi
}

# Hook/cron health for one feature: $1 label, $2 script, $3 method, $4 cron
# check function, $5 hook entry name
doctor_check_schedule() {
    local label="$1" script="$2" method="$3" cron_check="$4" entry="$5"
    if [ "$method" = "cron" ]; then
        if "$cron_check"; then
            doc_ok "$label scheduled by cron"
        else
            doc_fail "$label: cron entry missing"
            doc_hint "olecharms doctor --fix"
        fi
        if cron_daemon_running; then
            doc_ok "cron daemon running"
        else
            doc_fail "No cron daemon running — the job never fires"
            doc_hint "sudo service cron start (on WSL: enable systemd in /etc/wsl.conf), or switch to the shell hook in 'olecharms config'"
        fi
    else
        if grep -qF "$entry" "$HOOK_SCRIPT" 2>/dev/null && grep -qsF "source \"$HOOK_SCRIPT\"" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; then
            doc_ok "$label runs from the shell hook"
        else
            doc_fail "$label: shell hook not installed"
            doc_hint "olecharms doctor --fix"
        fi
    fi
    if [ -f "$script" ] && ! generated_current "$script"; then
        doc_warn "$(basename "$script") is from an older olecharms version (it still runs, without the latest fixes)"
        doc_hint "olecharms doctor --fix"
    fi
}

doctor_check_cleanup() {
    doc_section "Downloads cleanup"
    local enabled dir days action method real backend list count kb last
    enabled=$(config_get downloads_cleanup_enabled false)
    if [ "$enabled" != "true" ]; then
        if is_downloads_cleanup_enabled; then
            doc_warn "Config says disabled but $CLEANUP_SCRIPT exists"
            doc_hint "olecharms config → Downloads auto-cleanup"
        else
            doc_ok "Disabled (enable with: olecharms config)"
        fi
        return
    fi
    dir=$(config_get downloads_cleanup_dir)
    days=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
    action=$(config_get downloads_cleanup_action auto)
    method=$(config_get downloads_cleanup_method hook)
    if ! real=$(cleanup_real_dir "$dir"); then
        doc_fail "Folder ${dir:-<unset>} is missing or a protected location (home, system folder, whole drive, user profile)"
        return
    fi
    doc_ok "Folder $dir$([ "$real" != "$dir" ] && echo " → $real")"
    if [ -f "$CLEANUP_HELD" ]; then
        doc_warn "On hold: $(cat "$CLEANUP_HELD" 2>/dev/null)"
        doc_hint "olecharms cleanup (shows the files, asks you to type their count)"
    fi
    local qn=0 qkb=0 b bkb
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        bkb=$(du -sk "$b" 2>/dev/null | cut -f1)
        qn=$((qn + 1)) qkb=$((qkb + ${bkb:-0}))
    done <<< "$(cleanup_quarantine_batches "$real")"
    [ "$qn" -gt 0 ] && doc_ok "Quarantine: $qn cleanup(s), $(human_kb "$qkb"), each kept $(cleanup_quarantine_days) days (olecharms cleanup --restore)"
    if backend=$(cleanup_effective_backend "$real" "$action"); then
        doc_ok "Files older than $days days: $(cleanup_backend_label "$backend") (action: $action)"
    else
        doc_fail "Action is 'trash' but there is no trash for $real"
        doc_hint "olecharms config → Downloads auto-cleanup → change action"
    fi
    if [ ! -x "$CLEANUP_SCRIPT" ]; then
        doc_fail "Cleanup launcher missing ($CLEANUP_SCRIPT)"
        doc_hint "olecharms doctor --fix"
    fi
    doctor_check_schedule "Cleanup" "$CLEANUP_SCRIPT" "$method" is_downloads_cron_enabled cleanup-downloads.sh
    last=$(grep '^=== ' "$CLEANUP_LOG" 2>/dev/null | tail -n 1 | sed 's/^=== //')
    if [ -n "$last" ]; then
        doc_ok "Last run: $last"
    else
        doc_ok "No run logged yet ($CLEANUP_LOG)"
    fi
    list=$(mktemp) || return
    cleanup_collect "$real" "$days" "$list"
    count=$(cleanup_count "$list")
    kb=$(cleanup_size_kb "$list" "$count")
    rm -f "$list"
    if [ "$count" -gt 0 ]; then
        doc_ok "Due on the next run: $count files, $(human_kb "$kb")  (olecharms cleanup --dry-run)"
    fi
}

doctor_check_paranoid() {
    doc_section "Paranoid mode"
    if [ "$(config_get paranoid_mode_enabled false)" != "true" ]; then
        doc_ok "Disabled"
        return
    fi
    if [ ! -x "$PARANOID_SCRIPT" ]; then
        doc_fail "Enabled in config but $PARANOID_SCRIPT is missing"
        doc_hint "olecharms doctor --fix"
        return
    fi
    doctor_check_schedule "Paranoid cleanup" "$PARANOID_SCRIPT" "$(config_get paranoid_mode_method hook)" \
        is_paranoid_cron_enabled paranoid-cleanup.sh
    if paranoid_covers_windows; then
        if grep -q '^WIN_VIM_HOME=' "$PARANOID_SCRIPT"; then
            doc_ok "Also purges the Windows gVim history ($WIN_VIM_HOME)"
        else
            doc_warn "Paranoid mode does not purge the Windows gVim history yet"
            doc_hint "olecharms doctor --fix"
        fi
    fi
    # Enabling paranoid mode sets this; warn if it was loosened afterwards
    local days
    if ! is_downloads_cleanup_enabled; then
        doc_warn "Downloads auto-cleanup is off (paranoid mode keeps downloads $PARANOID_MAX_AGE_DAYS days at most)"
        doc_hint "olecharms config → Downloads auto-cleanup"
    else
        days=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
        if [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -le "$PARANOID_MAX_AGE_DAYS" ]; then
            doc_ok "Downloads kept at most $days days"
        else
            doc_warn "Downloads auto-cleanup keeps $days days (paranoid mode sets $PARANOID_MAX_AGE_DAYS)"
            doc_hint "olecharms config → Downloads auto-cleanup → Change max age"
        fi
    fi
}

doctor_check_config() {
    doc_section "Configuration"
    local stored
    if [ "$(config_get CONFIG_VERSION 0)" = "$CURRENT_CONFIG_VERSION" ]; then
        doc_ok "$OLECHARMS_CONFIG_FILE (v$CURRENT_CONFIG_VERSION)"
    else
        doc_warn "Config is v$(config_get CONFIG_VERSION 0), current is v$CURRENT_CONFIG_VERSION"
        doc_hint "olecharms update"
    fi
    stored=$(config_get install_dir "")
    if [ -n "$stored" ] && [ "$stored" != "$SCRIPT_DIR" ]; then
        doc_fail "Checkout moved from $stored; paths elsewhere still point there"
        doc_hint "olecharms doctor --fix"
    fi
    if [ -d "$SCRIPT_DIR/.git" ] \
       && [ -n "$(git -C "$SCRIPT_DIR" status --porcelain -- "$(basename "$CONF_FILE")" 2>/dev/null)" ]; then
        doc_warn "packages.conf has local changes, which can collide with updates"
        doc_hint "Move them to $LOCAL_CONF_FILE"
    fi
    if [ -f "$LOCAL_CONF_FILE" ]; then
        doc_ok "Per-machine overrides: $LOCAL_CONF_FILE"
    else
        doc_ok "No per-machine overrides (a template is created on the next update)"
    fi
    if [ ! -f "$SHARED_CONFIG_FILE" ]; then
        doc_ok "Shared settings: none yet (olecharms config → Shared settings shares this machine's)"
    elif [ -z "$(shared_differences)" ]; then
        doc_ok "Follows your shared settings$([ -n "$(config_get shared_keep_local "" | tr -d ' ')" ] && echo " (some kept different here on purpose)")"
    else
        doc_warn "This machine differs from your shared settings: $(shared_differences_summary)"
        doc_why "You chose them on another machine and shared them; this one has not applied them yet."
        doc_hint "olecharms doctor --fix, or olecharms config → Shared settings"
        doc_offer "Go through the shared settings now (one question each, with previews before anything is deleted)?" shared_apply
    fi
}

# Windows Terminal settings.json, read and written with python3 (it is JSON,
# and Windows Terminal rewrites it freely). The font matters for the WSL
# profiles: the defaults, unless a WSL profile sets its own.
WT_FONT_FACE="DejaVu Sans Mono for Powerline"
WT_FONT_PY='
import json, os, sys
path, mode, face = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8-sig") as fh:
        data = json.load(fh)
except Exception:
    print("unknown"); sys.exit(0)
profiles = data.get("profiles")
if not isinstance(profiles, dict):
    print("unknown"); sys.exit(0)
defaults = profiles.get("defaults")
if not isinstance(defaults, dict):
    defaults = {}
def face_of(p, inherited):
    font = p.get("font")
    if isinstance(font, dict) and isinstance(font.get("face"), str):
        return font["face"]
    if isinstance(p.get("fontFace"), str):
        return p["fontFace"]
    return inherited
distro = os.environ.get("WSL_DISTRO_NAME", "")
def is_wsl(p):
    src = str(p.get("source", ""))
    return src in ("Windows.Terminal.Wsl", "Microsoft.WSL") or \
        src.startswith("CanonicalGroupLimited.") or \
        (distro != "" and p.get("name") == distro) or \
        "wsl" in str(p.get("commandline", "")).lower()
base = face_of(defaults, "")
wsl = [p for p in profiles.get("list", []) if isinstance(p, dict) and is_wsl(p)]
faces = [face_of(p, base) for p in wsl] or [base]
if mode == "check":
    print("ok" if all("Powerline" in f for f in faces) else "bad")
    sys.exit(0)
defaults.setdefault("font", {})["face"] = face
defaults.pop("fontFace", None)
profiles["defaults"] = defaults
for p in wsl:
    if "Powerline" not in face_of(p, face):
        if isinstance(p.get("font"), dict):
            p["font"]["face"] = face
        p.pop("fontFace", None)
tmp = path + ".olecharms-tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(data, fh, indent=4, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
print("ok")
'

# ok / bad / unknown (no python3, or a file it cannot read)
wt_font_state() {
    check_command python3 || { echo unknown; return; }
    python3 -c "$WT_FONT_PY" "$1" check "$WT_FONT_FACE" 2>/dev/null || echo unknown
}

wt_set_font() {
    local wt="$1"
    check_command python3 || { error "python3 is needed to edit $wt"; return 1; }
    backup_file "$wt" || return 1
    [ "$(python3 -c "$WT_FONT_PY" "$wt" set "$WT_FONT_FACE")" = ok ] || return 1
    info "Windows Terminal picks the new font up straight away (no restart needed)"
}

doctor_check_windows() {
    [ -n "${IS_WSL:-}" ] || return 0
    doc_section "Windows side (WSL)"
    if [ "$(config_get windows_integration auto)" = "off" ]; then
        doc_ok "Windows integration switched off (olecharms config)"
        return
    fi
    if ! win_env_load; then
        doc_fail "Cannot reach Windows from WSL (interop disabled or powershell.exe missing)"
        doc_hint "Check [interop] in /etc/wsl.conf"
        return
    fi
    doc_ok "Windows user profile: $WIN_USERPROFILE"

    local missing f n gvim vf entry name total=0 have=0 wt
    missing=$(win_missing_fonts)
    if [ -z "$missing" ]; then
        doc_ok "Fonts installed for Windows (${FONT_FAMILIES[*]})"
    else
        n=$(printf '%s\n' "$missing" | grep -c .)
        doc_fail "$n font files of ${FONT_FAMILIES[*]} not installed for Windows"
        doc_hint "olecharms windows"
    fi
    for wt in "$WIN_LOCALAPPDATA"/Packages/Microsoft.WindowsTerminal*/LocalState/settings.json; do
        [ -f "$wt" ] || continue
        case "$(wt_font_state "$wt")" in
            ok)  doc_ok "Windows Terminal uses a Powerline font for WSL" ;;
            bad)
                doc_warn "Windows Terminal does not use a Powerline font for WSL"
                doc_why "Vim's status bar (vim-airline) then shows boxes or question marks instead of its arrow symbols."
                if [ -z "$missing" ]; then
                    doc_hint "olecharms doctor --fix (sets \"$WT_FONT_FACE\" in its settings, keeping a backup)"
                    doc_offer "Set Windows Terminal's font to \"$WT_FONT_FACE\" (default for all profiles; a backup is kept)?" wt_set_font "$wt"
                else
                    doc_hint "olecharms windows (installs the font), then olecharms doctor --fix"
                fi ;;
            *)
                if grep -q '"face"[^,}]*Powerline' "$wt"; then
                    doc_ok "Windows Terminal uses a Powerline font"
                else
                    doc_warn "Windows Terminal does not use a Powerline font (vim-airline symbols may not render)"
                    doc_hint "Windows Terminal → Settings → Profiles → Defaults → Appearance → Font face: $WT_FONT_FACE"
                fi ;;
        esac
        break
    done

    if ! gvim=$(win_find_gvim); then
        doc_warn "gVim is not installed on Windows"
        doc_hint "winget install vim.vim   (then: olecharms windows)"
        return
    fi
    doc_ok "gVim $(win_gvim_version "$gvim") at $gvim"
    vf="$WIN_VIM_HOME/vimfiles"
    if [ -f "$WIN_VIM_HOME/_vimrc" ] && tr -d '\r' < "$WIN_VIM_HOME/_vimrc" | grep -qxF "$WIN_VIMRC_LINE"; then
        doc_ok "$WIN_VIM_HOME/_vimrc sources the olecharms config"
    else
        doc_fail "$WIN_VIM_HOME/_vimrc does not source the olecharms config"
        doc_hint "olecharms windows"
    fi
    if cmp -s "$BUNDLED_DIR/olevimrc.vim" "$vf/olecharms/olevimrc.vim"; then
        doc_ok "olevimrc.vim copy up to date"
    else
        doc_fail "olevimrc.vim copy missing or outdated in $vf/olecharms"
        doc_hint "olecharms windows"
    fi
    if [ -f "$vf/autoload/pathogen.vim" ] && [ -d "$vf/undodir" ] && [ -d "$vf/swapfiles" ]; then
        doc_ok "pathogen, undodir and swapfiles present in $vf"
    else
        doc_fail "pathogen.vim, undodir or swapfiles missing in $vf"
        doc_hint "olecharms windows"
    fi
    for entry in "${VIM_PLUGINS[@]}"; do
        name="${entry%%|*}"
        total=$((total + 1))
        [ -f "$vf/bundle/$name/$WIN_MANAGED_STAMP" ] && have=$((have + 1))
    done
    if [ "$have" -eq "$total" ]; then
        doc_ok "$have/$total plugins copied to Windows"
    else
        doc_fail "$have/$total plugins copied to Windows"
        doc_hint "olecharms windows"
    fi
}

# The checkout as a git repository: what keeps a machine from updating, or
# from publishing global aliases
doctor_check_checkout() {
    doc_section "Checkout ($SCRIPT_DIR)"
    local gitdir branch upstream ahead behind stashes last age helper p name
    if ! gitdir=$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null); then
        doc_warn "Not a git checkout: no updates and no global aliases here"
        return
    fi
    if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] || [ -f "$gitdir/MERGE_HEAD" ]; then
        doc_fail "A merge or rebase is in progress: updates are paused"
        doc_hint "git -C \"$SCRIPT_DIR\" status"
    fi
    p=$(git -C "$SCRIPT_DIR" diff --name-only --diff-filter=U 2>/dev/null)
    if [ -n "$p" ]; then
        doc_fail "Conflict markers in: $(echo $p)"
        doc_hint "git -C \"$SCRIPT_DIR\" status"
    fi
    branch=$(git -C "$SCRIPT_DIR" symbolic-ref --short -q HEAD 2>/dev/null)
    if upstream=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
        doc_ok "On $branch, tracking $upstream"
        ahead=$(git -C "$SCRIPT_DIR" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
        behind=$(git -C "$SCRIPT_DIR" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
        if [ "$ahead" -gt 0 ]; then
            doc_warn "$ahead local commit(s) not on $upstream yet"
            doc_hint "git -C \"$SCRIPT_DIR\" push"
        fi
        if [ "$behind" -gt 0 ]; then
            doc_warn "$behind commit(s) behind $upstream (as of the last fetch)"
            doc_hint "olecharms sync"
        fi
    else
        doc_warn "${branch:-A detached HEAD} tracks no remote branch: updates and global aliases need one"
        doc_hint "git -C \"$SCRIPT_DIR\" checkout master"
    fi
    stashes=$(git -C "$SCRIPT_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
    if [ "$stashes" -gt 0 ]; then
        doc_warn "git stash holds $stashes entr$([ "$stashes" -gt 1 ] && echo ies || echo y) in the olecharms checkout"
        doc_why "Usually edits to olecharms' own files that an update set aside to be able to pull. They are not lost."
        doc_hint "See them: git -C \"$SCRIPT_DIR\" stash show -p   Throw them away: git -C \"$SCRIPT_DIR\" stash drop"
    fi
    if [ -f "$LAST_PULL_FILE" ] && last=$(cut -d' ' -f1 "$LAST_PULL_FILE") && [[ "$last" =~ ^[0-9]+$ ]]; then
        age=$(( ($(date +%s) - last) / 86400 ))
        if [ "$age" -gt 30 ]; then
            doc_warn "Last successful update $age days ago"
            doc_why "olecharms updates itself when you open a shell; here it has not managed to for a while (offline? the checks above say why)."
            doc_hint "olecharms sync"
        else
            doc_ok "Last successful update $age day(s) ago"
        fi
    else
        doc_warn "No successful update recorded yet"
        doc_why "olecharms updates itself from GitHub when you open a shell; none has completed on this machine so far."
        doc_hint "olecharms sync"
    fi
    doctor_check_git_helpers "$branch"
}

# Executable a git credential helper value runs ("" when it is a shell
# snippet or otherwise cannot be told)
git_helper_path() {
    local helper="$1" p name
    case "$helper" in
        /*) p=${helper//\\ /$'\001'}; p=${p%% *}; p=${p//$'\001'/ } ;;
        !/*) p=${helper#!}; p=${p%% *} ;;
        !\"/*) p=${helper#!\"}; p=${p%%\"*} ;;
        !*)
            name=${helper#!}; name=${name%% *}
            case "$name" in
                *[!A-Za-z0-9._-]*) p="" ;;   # f() { ...; }; f and the like
                *) p=$(command -v "$name" 2>/dev/null) || p="(command not found) $name" ;;
            esac ;;
        *)  name=${helper%% *}
            p=$(command -v "git-credential-$name" 2>/dev/null) ||
                p="$(git --exec-path 2>/dev/null)/git-credential-$name" ;;
    esac
    printf '%s\n' "$p"
}

# The credential helpers git runs for URL $1 from the checkout, as git picks
# them: every credential.helper and matching credential.<url>.helper in
# config order, an empty value dropping the ones collected so far
git_effective_helpers() {
    local url="$1" line key value pat out=""
    url=$(printf '%s' "$url" | sed -E 's#^([a-z]+://)[^@/]*@#\1#')
    while IFS= read -r line; do
        key=${line%% *}
        value=""
        [ "$key" != "$line" ] && value=${line#* }
        case "$key" in
            credential.helper) ;;
            credential.*.helper)
                pat=${key#credential.}
                pat=${pat%.helper}
                pat=${pat%/}
                case "$url" in "$pat"|"$pat"/*) ;; *) continue ;; esac ;;
            *) continue ;;
        esac
        if [ -z "$value" ]; then out=""; else out="$out$value"$'\n'; fi
    done < <(git -C "$SCRIPT_DIR" config --get-regexp '^credential\..*helper$' 2>/dev/null)
    printf '%s' "$out"
}

# Remove one credential helper entry: $1 config file, $2 key, $3 value
git_helper_remove() {
    local file="$1" key="$2" value="$3" re
    if [ ! -w "$file" ]; then
        error "$file is not writable (try: sudo git config --file \"$file\" --unset-all $key)"
        return 1
    fi
    backup_file "$file" || return 1
    re=$(printf '%s' "$value" | sed 's/[][\\.*^$+?(){}|]/\\&/g')
    git config --file "$file" --unset-all "$key" "^$re\$"
}

# A password helper that is no longer installed (Git for Windows' manager
# after an uninstall, typically) makes git's HTTPS logins fail. What matters
# most is the remote olecharms pushes global aliases to.
doctor_check_git_helpers() {
    local branch="$1" remote url effective line origin file rest key value p
    remote=$(git -C "$SCRIPT_DIR" config "branch.$branch.remote" 2>/dev/null) || remote=origin
    url=$(git -C "$SCRIPT_DIR" remote get-url --push "$remote" 2>/dev/null)
    case "$url" in
        http://*|https://*) effective=$(git_effective_helpers "$url") ;;
        *) effective="" ;;
    esac
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        origin=${line%%$'\t'*}
        rest=${line#*$'\t'}
        key=${rest%% *}
        value=""
        [ "$key" != "$rest" ] && value=${rest#* }
        [ -n "$value" ] || continue
        p=$(git_helper_path "$value")
        [ -n "$p" ] && [ ! -e "$p" ] || continue
        file=${origin#file:}
        if printf '%s\n' "$effective" | grep -qxF -- "$value"; then
            doc_warn "Git cannot log in to push olecharms changes: its password helper is not installed anymore"
            doc_why "Missing program: $p (set in $file). Publishing global aliases fails until this is fixed."
            if [[ "$url" == https://github.com/* ]] && gh_logged_in; then
                doc_hint "olecharms doctor --fix (lets git use your GitHub CLI login)"
                doc_offer "Let git log in to GitHub with your GitHub CLI account (runs: gh auth setup-git)?" gh auth setup-git
            else
                doc_hint "Remove it (olecharms doctor --fix), then set up a working helper or switch the remote to SSH"
            fi
        else
            doc_warn "Git's password helper points to a program that no longer exists: $p"
            if [ -n "$effective" ]; then
                doc_why "Pushing olecharms works (another helper covers $url), but HTTPS logins to other git servers on this machine would fail."
            else
                doc_why "HTTPS logins to git servers on this machine fail. olecharms itself does not use it (remote: ${url:-none})."
            fi
            doc_hint "olecharms doctor --fix (removes that entry from $file, keeping a backup)"
        fi
        [ -n "$file" ] && [ -f "$file" ] &&
            doc_offer "Remove the broken password helper from $file (a backup is kept)?" git_helper_remove "$file" "$key" "$value"
    done < <(git -C "$SCRIPT_DIR" config --show-origin --get-regexp '^credential\..*helper$' 2>/dev/null)
}

doctor_run_checks() {
    DOC_OK=0
    DOC_WARN=0
    DOC_FAIL=0
    DOC_FIRST_FAIL=""
    DOC_OFFER_Q=()
    DOC_OFFER_CMD=()
    DOC_WANTS_UPDATE=""
    DOC_WANTS_SYNC=""
    doctor_check_commands
    doctor_check_checkout
    doctor_check_launcher
    doctor_check_shell
    doctor_check_vim
    doctor_check_zsh
    doctor_check_zsh_extras
    doctor_check_cleanup
    doctor_check_paranoid
    doctor_check_config
    doctor_check_windows
    echo ""
    local summary="$DOC_OK ok, $DOC_WARN warnings, $DOC_FAIL problems"
    if [ "$DOC_FAIL" -gt 0 ]; then
        echo -e "${RED}${BOLD}$summary${NC}"
    elif [ "$DOC_WARN" -gt 0 ]; then
        echo -e "${YELLOW}${BOLD}$summary${NC}"
    else
        echo -e "${GREEN}${BOLD}$summary${NC}"
    fi
}

# olecharms doctor [--fix] — checks everything olecharms sets up and exits 1
# when something is broken. --fix first re-runs the local, offline steps
# (paths, RC blocks, generated scripts, launcher, Windows sync); packages and
# plugins need the network and stay with `olecharms update`.
# The offline, local half of an update: vim dirs and vimrc line, shell loader
# and RC lines, launcher, EDITOR, scheduled features, the Windows side.
# Shared by `doctor --fix` and `sync`.
run_local_steps() {
    create_vim_dirs
    install_vimrc
    install_shell_commands
    install_binary
    install_editor_env
    restore_scheduled_features
    sync_windows_side
    config_set install_dir "$SCRIPT_DIR"
}

# Keep DOCTOR_PROBLEMS in line with the last check: new shells mention it
doctor_record() {
    mkdir -p "$OLECHARMS_STATE_DIR" 2>/dev/null
    if [ "$DOC_FAIL" -gt 0 ]; then
        printf '%s problem%s, e.g. %s\n' "$DOC_FAIL" "$([ "$DOC_FAIL" -gt 1 ] && echo s)" \
            "$(printf '%s' "$DOC_FIRST_FAIL" | sed 's/\x1b\[[0-9;]*m//g')" > "$DOCTOR_PROBLEMS" 2>/dev/null
    else
        rm -f "$DOCTOR_PROBLEMS"
    fi
}

cmd_doctor() {
    local fix="" quiet="" arg out
    for arg in "$@"; do
        case "$arg" in
            --fix) fix=1 ;;
            --quiet) quiet=1 ;;
            -h|--help) echo "Usage: olecharms doctor [--fix]"; return 0 ;;
            *) error "Unknown doctor option: $arg"; return 1 ;;
        esac
    done
    load_config || return 1

    # The daily background run: nothing on screen, only the problems file
    if [ -n "$quiet" ]; then
        out=$(mktemp) || return 1
        doctor_run_checks > "$out" 2>&1
        rm -f "$out"
        doctor_record
        [ "$DOC_FAIL" -eq 0 ]
        return $?
    fi

    if [ -n "$fix" ]; then
        echo -e "${BOLD}olecharms doctor --fix${NC}"
        echo ""
        run_local_steps
        echo ""
    fi

    echo -e "${BOLD}olecharms doctor${NC}"
    doctor_run_checks
    doctor_record
    if [ -n "$fix" ]; then
        if doctor_apply_offers; then
            # Check again, showing only the outcome
            out=$(mktemp) || return 1
            doctor_run_checks > "$out" 2>&1
            rm -f "$out"
            doctor_record
            echo ""
            echo -e "${BOLD}After the repairs:${NC} $DOC_OK ok, $DOC_WARN warnings, $DOC_FAIL problems  (olecharms doctor shows the details)"
        fi
    elif [ "$DOC_FAIL" -gt 0 ] || [ "$DOC_WARN" -gt 0 ]; then
        echo ""
        if [ "${#DOC_OFFER_Q[@]}" -gt 0 ] || [ -n "$DOC_WANTS_UPDATE$DOC_WANTS_SYNC" ]; then
            echo "Run 'olecharms doctor --fix' to repair what it can; it asks before anything outside olecharms' own files."
        elif [ "$DOC_FAIL" -gt 0 ]; then
            echo "Run 'olecharms doctor --fix' for local repairs, or 'olecharms update' for packages and plugins."
        fi
    fi
    [ "$DOC_FAIL" -eq 0 ]
}

cmd_status() {
    echo -e "${BOLD}olecharms status${NC}"
    echo ""

    load_config || return 1
    detect_os

    echo -e "${BLUE}OS:${NC} $OS ($PKG_MANAGER)"
    echo -e "${BLUE}User:${NC} $(id -un 2>/dev/null) (uid $(id -u 2>/dev/null)), HOME=$HOME"
    echo -e "${BLUE}Repo:${NC} $SCRIPT_DIR"
    echo -e "${BLUE}Vim dir:${NC} $VIM_DIR"
    echo -e "${BLUE}Font dir:${NC} $FONT_DIR"
    echo -e "${BLUE}Scripts dir:${NC} $SCRIPTS_DIR"

    # The launcher symlink is the path most likely to go stale after a move
    if [ -L "$BIN_DIR/olecharms" ]; then
        local link_target
        link_target=$(resolve_link "$BIN_DIR/olecharms")
        if [ -f "$link_target" ]; then
            echo -e "${BLUE}Launcher:${NC} $BIN_DIR/olecharms → $link_target"
        else
            echo -e "${BLUE}Launcher:${NC} ${RED}broken symlink${NC} $BIN_DIR/olecharms → $link_target"
        fi
    elif [ -e "$BIN_DIR/olecharms" ]; then
        echo -e "${BLUE}Launcher:${NC} $BIN_DIR/olecharms (regular file, not managed)"
    else
        echo -e "${BLUE}Launcher:${NC} ${YELLOW}not installed${NC}"
    fi

    # Config file
    if [ -f "$OLECHARMS_CONFIG_FILE" ]; then
        config_read
        echo -e "${BLUE}Config:${NC} $OLECHARMS_CONFIG_FILE (v$(config_get CONFIG_VERSION 0))"
    else
        echo -e "${BLUE}Config:${NC} not created yet"
    fi

    # Repo version
    if [ -d "$SCRIPT_DIR/.git" ]; then
        local rev
        rev=$(git -C "$SCRIPT_DIR" log --oneline -1 2>/dev/null)
        echo -e "${BLUE}Repo commit:${NC} $rev"
    fi

    # Plugins with versions
    echo ""
    echo -e "${BLUE}Installed plugins:${NC}"
    for entry in "${VIM_PLUGINS[@]}"; do
        local name="${entry%%|*}"
        local dest="$VIM_DIR/bundle/$name"
        if [ -d "$dest/.git" ]; then
            local rev date
            rev=$(git -C "$dest" log --oneline -1 2>/dev/null)
            date=$(git -C "$dest" log -1 --format='%ci' 2>/dev/null | cut -d' ' -f1)
            echo -e "  ${GREEN}✓${NC} $name  ${rev}  ($date)"
        elif [ -d "$dest" ]; then
            echo -e "  ${YELLOW}~${NC} $name  (bundled copy, no version info)"
        else
            echo -e "  ${RED}✗${NC} $name  (not installed)"
        fi
    done

    # Pathogen
    echo ""
    echo -e "${BLUE}Pathogen:${NC}"
    if [ -d "$PATHOGEN_STAGING/.git" ]; then
        local rev
        rev=$(git -C "$PATHOGEN_STAGING" log --oneline -1 2>/dev/null)
        echo -e "  ${GREEN}✓${NC} $rev"
    elif [ -f "$VIM_DIR/autoload/pathogen.vim" ]; then
        echo -e "  ${YELLOW}~${NC} installed (bundled copy)"
    else
        echo -e "  ${RED}✗${NC} not installed"
    fi

    # Shell commands
    echo ""
    echo -e "${BLUE}Shell commands:${NC}"
    if [ -d "$SHELL_DIR" ] && ls "$SHELL_DIR"/*.sh >/dev/null 2>&1; then
        for f in "$SHELL_DIR"/*.sh; do
            echo -e "  ${GREEN}✓${NC} $(basename "$f" .sh)"
        done
    else
        echo "  (none)"
    fi

    # Downloads cleanup
    echo ""
    echo -e "${BLUE}Downloads cleanup:${NC}"
    if [ "$(config_get downloads_cleanup_enabled false)" = "true" ]; then
        local real backend last
        echo "  $(config_get downloads_cleanup_dir), older than $(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS") days, via $(config_get downloads_cleanup_method hook)"
        if real=$(cleanup_real_dir "$(config_get downloads_cleanup_dir)") \
           && backend=$(cleanup_effective_backend "$real" "$(config_get downloads_cleanup_action auto)"); then
            echo "  Old files: $(cleanup_backend_label "$backend")"
        fi
        last=$(grep '^=== ' "$CLEANUP_LOG" 2>/dev/null | tail -n 1 | sed 's/^=== //')
        echo "  Last run: ${last:-none logged yet}"
    else
        echo "  disabled"
    fi

    # Windows side
    if [ -n "${IS_WSL:-}" ]; then
        echo ""
        echo -e "${BLUE}Windows (WSL):${NC}"
        local gvim
        if [ "$(config_get windows_integration auto)" = "off" ]; then
            echo "  integration off"
        elif ! win_env_load; then
            echo "  not reachable from WSL"
        elif gvim=$(win_find_gvim); then
            echo "  gVim $(win_gvim_version "$gvim"): $gvim"
            echo "  Config: $WIN_VIM_HOME/_vimrc, $WIN_VIM_HOME/vimfiles"
        else
            echo "  gVim not installed (winget install vim.vim)"
        fi
    fi

    # Aliases
    echo ""
    echo -e "${BLUE}Aliases:${NC}"
    alias_show_list
}

# Let the user pick one of the folders find_downloads_dirs offers. Prints the
# choice. Runs inside $(...), so all messages go to stderr; returns 1 on
# cancel and 2 on error.
choose_downloads_dir() {
    local dirs d i choice dir_array=()
    if ! dirs=$(find_downloads_dirs) || [ -z "$dirs" ]; then
        error "No downloads folder found in $HOME" >&2
        echo "  Create one with: mkdir ~/Downloads" >&2
        return 2
    fi
    while IFS= read -r d; do
        dir_array+=("$d")
    done <<< "$dirs"
    {
        echo "  Found download folders:"
        echo ""
        for i in "${!dir_array[@]}"; do
            echo "    $((i + 1))) ${dir_array[$i]}"
        done
        echo ""
        echo "    0) Cancel"
        echo ""
    } >&2
    read -rp "  Select folder: " choice
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return 1
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#dir_array[@]} ]; then
        error "Invalid selection" >&2
        return 2
    fi
    echo "${dir_array[$((choice - 1))]}"
}

# Ask between the trash and permanent deletion for real dir $1; prints the
# action to store (trash | delete).
choose_cleanup_action() {
    local real="$1" backend choice
    if ! backend=$(cleanup_trash_backend "$real"); then
        {
            echo "  There is no trash for this folder. What should happen to old files?"
            echo ""
            echo "    1) Quarantine — kept $(cleanup_quarantine_days) days, restorable with 'olecharms cleanup --restore' (recommended)"
            echo "    2) Delete permanently"
            echo ""
        } >&2
        read -rp "  Select [1]: " choice
        case "$choice" in
            2) echo delete ;;
            *) echo auto ;;
        esac
        return 0
    fi
    {
        echo "  What should happen to old files?"
        echo ""
        echo "    1) $(cleanup_backend_label "$backend") — recoverable (recommended)"
        echo "    2) Delete permanently"
        echo ""
    } >&2
    read -rp "  Select [1]: " choice
    case "$choice" in
        2) echo delete ;;
        *) echo trash ;;
    esac
}

config_cleanup_action() {
    local real backend choice cur trash_label="no trash available here"
    cur=$(config_get downloads_cleanup_action auto)
    real=$(cleanup_real_dir "$(config_get downloads_cleanup_dir)")
    backend=$(cleanup_trash_backend "$real") && trash_label=$(cleanup_backend_label "$backend")
    echo ""
    echo "  Current action: $cur"
    echo ""
    echo "    1) auto    — Windows Recycle Bin / macOS Trash when there is one, else quarantine"
    echo "    2) trash   — always $trash_label"
    echo "    3) delete  — delete permanently"
    echo ""
    read -rp "  Select: " choice
    case "$choice" in
        1) config_set downloads_cleanup_action auto ;;
        2)
            if [ -z "$backend" ]; then
                error "No trash is available for $real"
                return 1
            fi
            config_set downloads_cleanup_action trash
            ;;
        3) config_set downloads_cleanup_action delete ;;
        *) info "No changes made"; return 0 ;;
    esac
    info "Action set to $(config_get downloads_cleanup_action auto)"
}

# Change the max age, asking for it unless given as $1
config_cleanup_age() {
    local days="${1:-}" cur dir real backend list
    cur=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
    [ -n "$days" ] || read -rp "  Delete files older than how many days? [$cur] " days
    [ -z "$days" ] && { info "No changes made"; return 0; }
    if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ] || [ "$days" -gt 3650 ]; then
        error "Enter a number of days between 1 and 3650"
        return 1
    fi
    # A shorter age takes effect on the next shell: show what that removes
    if ! [[ "$cur" =~ ^[0-9]+$ ]] || [ "$days" -lt "$cur" ]; then
        dir=$(config_get downloads_cleanup_dir)
        if real=$(cleanup_real_dir "$dir") && list=$(mktemp); then
            backend=$(cleanup_effective_backend "$real" "$(config_get downloads_cleanup_action auto)") || backend=delete
            echo ""
            cleanup_collect "$real" "$days" "$list"
            cleanup_print_preview "$dir" "$real" "$days" "$backend" "$list" 10
            rm -f "$list"
            echo ""
            if ! confirm_default_yes "  Set the max age to $days days?"; then
                info "No changes made"
                return 0
            fi
        fi
    fi
    config_set downloads_cleanup_max_age_days "$days"
    info "Max age set to $days days"
}

config_downloads_cleanup() {
    local dir days action real backend list choice

    if is_downloads_cleanup_enabled; then
        local method_info="shell hook, at most once a day when a shell opens"
        if is_downloads_cron_enabled; then
            method_info="cron, daily at ${DOWNLOADS_CRON_HOUR}:$(printf '%02d' $DOWNLOADS_CRON_MIN)"
        fi
        dir=$(config_get downloads_cleanup_dir)
        days=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
        action=$(config_get downloads_cleanup_action auto)
        echo -e "  Status: ${GREEN}enabled${NC} ($method_info)"
        if real=$(cleanup_real_dir "$dir") && backend=$(cleanup_effective_backend "$real" "$action"); then
            echo "  Files older than $days days in $dir: $(cleanup_backend_label "$backend")"
        else
            warn "  $dir is not reachable right now"
        fi
        echo ""
        echo "    1) Preview what the next run would remove"
        echo "    2) Change action (now: $action)"
        echo "    3) Change max age (now: $days days)"
        echo "    4) Show cleanup history"
        echo "    5) Disable auto-cleanup"
        echo ""
        echo "    0) Back"
        echo ""
        read -rp "  Select: " choice
        case "$choice" in
            1)
                echo ""
                if [ -n "$real" ] && list=$(mktemp); then
                    cleanup_collect "$real" "$days" "$list"
                    cleanup_print_preview "$dir" "$real" "$days" "$backend" "$list" 20
                    rm -f "$list"
                fi
                ;;
            2) config_cleanup_action ;;
            3) config_cleanup_age ;;
            4) echo ""; cleanup_show_log ;;
            5) disable_downloads_cleanup ;;
            *) info "No changes made" ;;
        esac
        return 0
    fi

    echo -e "  Status: ${RED}disabled${NC}"
    echo ""
    local selected mode method_choice rc
    selected=$(choose_downloads_dir)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        [ "$rc" -eq 1 ] && info "Cancelled"
        return $((rc - 1))
    fi
    if ! real=$(cleanup_real_dir "$selected"); then
        error "Refusing $selected: a protected location (home, system folder, whole drive, user profile)"
        return 1
    fi
    days=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")

    echo ""
    echo "  Select scheduling method:"
    echo ""
    echo "    1) Shell hook — checked on shell open (recommended)"
    echo "    2) Cron job — daily at ${DOWNLOADS_CRON_HOUR}:$(printf '%02d' $DOWNLOADS_CRON_MIN)"
    echo ""
    echo "    0) Cancel"
    echo ""
    read -rp "  Select: " method_choice
    case "$method_choice" in
        1) mode="hook" ;;
        2)
            if ! check_command crontab; then
                error "crontab is not available. Install a cron daemon or use the shell hook."
                return 1
            fi
            mode="cron"
            warn_if_no_cron_daemon
            if [ "$(uname -s)" = "Darwin" ]; then
                warn "macOS only lets cron into ~/Downloads with Full Disk Access for /usr/sbin/cron"
                warn "(System Settings → Privacy & Security). The shell hook needs no extra permission."
            fi
            ;;
        0|"") info "Cancelled"; return 0 ;;
        *) error "Invalid selection"; return 1 ;;
    esac

    echo ""
    action=$(choose_cleanup_action "$real")
    backend=$(cleanup_effective_backend "$real" "$action") || backend=delete

    # Show the consequence before committing: the first run happens as soon as
    # a new shell opens.
    echo ""
    list=$(mktemp) || return 1
    cleanup_collect "$real" "$days" "$list"
    cleanup_print_preview "$selected" "$real" "$days" "$backend" "$list" 10
    rm -f "$list"
    echo ""
    if ! confirm_default_yes "  Enable auto-cleanup with these settings?"; then
        info "Cancelled"
        return 0
    fi

    config_set downloads_cleanup_action "$action"
    enable_downloads_cleanup "$selected" "$mode" || return 1
    info "Downloads auto-cleanup enabled for $selected"
    if [ "$mode" = "cron" ]; then
        info "Cron job installed (daily at ${DOWNLOADS_CRON_HOUR}:$(printf '%02d' $DOWNLOADS_CRON_MIN))."
    else
        info "First run when the next shell opens. Preview any time: olecharms cleanup --dry-run"
    fi
}

config_paranoid_mode() {
    if is_paranoid_mode_enabled; then
        local method_info="shell hook"
        if is_paranoid_cron_enabled; then
            method_info="cron, every 12 hours"
        fi
        echo -e "  Status: ${GREEN}enabled${NC} ($method_info)"
        echo ""
        echo "  Paranoid mode deletes every 12 hours:"
        paranoid_print_targets
        echo ""
        read -rp "  Disable paranoid mode? [y/N] " answer
        case "$answer" in
            [yY])
                disable_paranoid_mode
                ;;
            *)
                info "No changes made"
                ;;
        esac
        return 0
    fi

    echo -e "  Status: ${RED}disabled${NC}"
    echo ""
    echo "  Every 12 hours, paranoid mode will permanently delete:"
    paranoid_print_targets
    echo ""

    # Downloads are kept at most PARANOID_MAX_AGE_DAYS old: the cleanup is
    # enabled, or lowered when it keeps them longer.
    local days="$PARANOID_MAX_AGE_DAYS" cur_days dl_change=""
    if is_downloads_cleanup_enabled; then
        cur_days=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
        if [[ "$cur_days" =~ ^[0-9]+$ ]] && [ "$cur_days" -le "$days" ]; then
            echo "  Downloads auto-cleanup already removes files older than $cur_days days — unchanged."
        else
            dl_change=lower
            echo -e "  ${YELLOW}Also:${NC} downloads auto-cleanup goes from $cur_days to $days days."
        fi
    else
        dl_change=enable
        echo -e "  ${YELLOW}Also:${NC} enables downloads auto-cleanup for files older than $days days."
    fi
    echo ""

    echo "  Select scheduling method:"
    echo ""
    echo "    1) Shell hook — checked on shell open (recommended)"
    echo "    2) Cron job — every 12 hours"
    echo ""
    echo "    0) Cancel"
    echo ""

    local method_choice mode
    read -rp "  Select: " method_choice
    case "$method_choice" in
        1)
            mode="hook"
            ;;
        2)
            if ! check_command crontab; then
                error "crontab is not available. Install a cron daemon or use the shell hook."
                return 1
            fi
            mode="cron"
            ;;
        0|"")
            info "Cancelled"
            return 0
            ;;
        *)
            error "Invalid selection"
            return 1
            ;;
    esac

    # Show what the new downloads rule removes before committing to it: it
    # runs as soon as a new shell opens, and can be thousands of files.
    local dir real backend list rc
    case "$dl_change" in
        enable)
            echo ""
            dir=$(choose_downloads_dir)
            rc=$?
            if [ "$rc" -ne 0 ]; then
                [ "$rc" -eq 1 ] && info "Cancelled"
                return $((rc - 1))
            fi
            if ! real=$(cleanup_real_dir "$dir"); then
                error "Refusing $dir: a protected location (home, system folder, whole drive, user profile)"
                return 1
            fi
            ;;
        lower)
            dir=$(config_get downloads_cleanup_dir)
            real=$(cleanup_real_dir "$dir") || real=""
            ;;
    esac
    if [ -n "$dl_change" ]; then
        echo ""
        if [ -n "$real" ] && list=$(mktemp); then
            backend=$(cleanup_effective_backend "$real" "$(config_get downloads_cleanup_action auto)") || backend=delete
            cleanup_collect "$real" "$days" "$list"
            cleanup_print_preview "$dir" "$real" "$days" "$backend" "$list" 10
            rm -f "$list"
        else
            warn "  $dir is not reachable right now; cannot preview what would be removed"
        fi
        echo ""
        if ! confirm_default_yes "  Enable paranoid mode with this downloads cleanup?"; then
            info "Cancelled"
            return 0
        fi
        if [ "$dl_change" = enable ]; then
            enable_downloads_cleanup "$dir" "$mode" "$days" || return 1
            info "Downloads auto-cleanup enabled for $dir ($days-day max age)"
        else
            config_set downloads_cleanup_max_age_days "$days"
            info "Downloads auto-cleanup lowered from $cur_days to $days days"
        fi
    fi

    enable_paranoid_mode "$mode" || return 1
    info "Paranoid mode enabled"
    if [ "$mode" = "cron" ]; then
        info "Cron job installed (every 12 hours)."
    else
        info "Changes take effect in your next shell session."
    fi
}

cmd_config() {
    echo -e "${BOLD}olecharms config${NC}"
    echo ""

    while true; do
        local dl_status
        if is_downloads_cleanup_enabled 2>/dev/null; then
            dl_status="${GREEN}enabled${NC}"
        else
            dl_status="${RED}disabled${NC}"
        fi

        local paranoid_status
        if is_paranoid_mode_enabled 2>/dev/null; then
            paranoid_status="${GREEN}enabled${NC}"
        else
            paranoid_status="${RED}disabled${NC}"
        fi

        echo "  Configuration options:"
        echo ""
        echo -e "    1) Downloads auto-cleanup  [$dl_status]"
        echo -e "    2) Paranoid mode           [$paranoid_status]"
        if [ -n "${IS_WSL:-}" ]; then
            local win_status="${GREEN}auto${NC}"
            [ "$(config_get windows_integration auto)" = "off" ] && win_status="${RED}off${NC}"
            echo -e "    3) Windows gVim & fonts    [$win_status]"
        fi
        local doc_status="${GREEN}on${NC}"
        daily_doctor_enabled || doc_status="${RED}off${NC}"
        echo -e "    4) Daily health check      [$doc_status]"
        local shared_status="${BLUE}not shared${NC}"
        if [ -f "$SHARED_CONFIG_FILE" ]; then
            if [ -n "$(shared_differences)" ]; then
                shared_status="${YELLOW}differs here${NC}"
            else
                shared_status="${GREEN}followed${NC}"
            fi
        fi
        echo -e "    5) Shared settings         [$shared_status]"
        local zx_status="${GREEN}on${NC}"
        [ "$(config_get zsh_extras on)" = off ] && zx_status="${RED}off${NC}"
        echo -e "    6) Zsh extras              [$zx_status]  fzf keys, suggestions, syntax colours"
        echo ""
        echo "    0) Exit"
        echo ""

        local choice
        read -rp "  Select option: " choice

        case "$choice" in
            1)
                echo ""
                config_downloads_cleanup
                echo ""
                ;;
            2)
                echo ""
                config_paranoid_mode
                echo ""
                ;;
            3)
                echo ""
                if [ -z "${IS_WSL:-}" ]; then
                    warn "Only available on WSL"
                elif [ "$(config_get windows_integration auto)" = "off" ]; then
                    config_set windows_integration auto
                    info "Windows integration on — 'olecharms update' (or 'olecharms windows') now also manages gVim and fonts"
                else
                    config_set windows_integration off
                    info "Windows integration off — the Windows side is left as it is"
                fi
                # Paranoid mode purges the Windows gVim only with the integration on
                if is_paranoid_mode_enabled; then
                    enable_paranoid_mode "$(config_get paranoid_mode_method hook)"
                fi
                echo ""
                ;;
            4)
                echo ""
                echo "  Once a day, the first shell to open runs 'olecharms doctor' in the"
                echo "  background; while it finds problems, new shells show one line about them."
                echo ""
                if daily_doctor_enabled; then
                    config_set daily_doctor off
                    info "Daily health check off"
                else
                    config_set daily_doctor on
                    info "Daily health check on"
                fi
                generate_doctor_launcher
                sync_shell_hook
                echo ""
                ;;
            5)
                echo ""
                config_shared_settings
                echo ""
                ;;
            6)
                echo ""
                config_zsh_extras
                echo ""
                ;;
            0|"")
                return
                ;;
            *)
                warn "Invalid selection"
                echo ""
                ;;
        esac
    done
}

cleanup_usage() {
    echo "Usage: olecharms cleanup [--dry-run | --log] [--yes [--force]]"
    echo ""
    echo "  (no option)    show what would go, ask, then clean the downloads folder now"
    echo "  -n, --dry-run  list the files the next run would remove; change nothing"
    echo "      --log      show the history of past cleanups"
    echo "      --restore  put back the files of a cleanup that went to the quarantine"
    echo "  -y, --yes      do not ask for confirmation"
    echo "      --force    with --yes: allow a mass removal (over $CLEANUP_BATCH_FILES files,"
    echo "                 $(human_kb "$CLEANUP_BATCH_KB") or half the folder). Interactively you type the count instead."
    echo ""
    echo "  Scheduled runs never remove that much on their own: they hold it and new"
    echo "  shells say so until you confirm it here."
}

# olecharms cleanup — the same engine the scheduled runs use, on demand.
cmd_cleanup() {
    local mode=run assume_yes="" force="" arg
    for arg in "$@"; do
        case "$arg" in
            -n|--dry-run) mode=dry ;;
            -y|--yes)     assume_yes=1 ;;
            --force)      force=1 ;;
            --log)        mode=log ;;
            --restore)    mode=restore ;;
            --scheduled)  mode=scheduled ;;
            -h|--help)    cleanup_usage; return 0 ;;
            *)            error "Unknown cleanup option: $arg"; cleanup_usage; return 1 ;;
        esac
    done
    if [ "$mode" = "log" ]; then
        cleanup_show_log
        return 0
    fi
    if [ "$mode" = "restore" ]; then
        cleanup_quarantine_restore
        return $?
    fi

    local dir days action real backend list count answer
    dir=$(config_get downloads_cleanup_dir)
    days=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
    action=$(config_get downloads_cleanup_action auto)
    if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ]; then
        days=$DOWNLOADS_MAX_AGE_DAYS
    fi

    if [ "$mode" = "scheduled" ]; then
        # Only for an enabled feature; silent, locked, logged
        [ "$(config_get downloads_cleanup_enabled false)" = "true" ] || return 0
        cleanup_run "$dir" "$days" "$action" scheduled
        return $?
    fi

    if [ -z "$dir" ]; then
        error "Downloads cleanup is not set up yet — choose a folder with: olecharms config"
        return 1
    fi
    if ! real=$(cleanup_real_dir "$dir"); then
        error "Cannot clean $dir: missing, or a protected location (home, system folder, whole drive, user profile)"
        return 1
    fi
    if ! backend=$(cleanup_effective_backend "$real" "$action"); then
        error "Action is 'trash' but $real has no trash; change it in 'olecharms config'"
        return 1
    fi

    [ "$mode" = run ] && cleanup_quarantine_purge "$real"
    list=$(mktemp) || return 1
    cleanup_collect "$real" "$days" "$list"
    count=$(cleanup_count "$list")
    echo -e "${BOLD}olecharms cleanup${NC}"
    echo ""
    cleanup_print_preview "$dir" "$real" "$days" "$backend" "$list"
    if [ "$mode" = "dry" ]; then
        if [ "$count" -gt 0 ]; then
            echo ""
            tr '\0' '\n' < "$list" | sort
        fi
        rm -f "$list"
        return 0
    fi
    if [ "$count" -eq 0 ]; then
        rm -f "$list"
        return 0
    fi
    echo ""
    local kb
    kb=$(cleanup_size_kb "$list" "$count")
    if cleanup_is_large "$count" "$kb" "$real"; then
        # Mass removal: a second, deliberate confirmation
        warn "This is a mass removal: $CLEANUP_LARGE_WHY."
        if [ -n "$assume_yes" ]; then
            if [ -z "$force" ]; then
                rm -f "$list"
                error "Refusing a mass removal with --yes alone; add --force if you really mean it"
                return 1
            fi
        else
            if [ ! -t 0 ]; then
                rm -f "$list"
                error "Not asking without a terminal; pass --yes --force to clean anyway"
                return 1
            fi
            read -rp "  Type the number of files ($count) to confirm: " answer
            if [ "$answer" != "$count" ]; then
                rm -f "$list"
                info "Cancelled"
                return 0
            fi
        fi
    elif [ -z "$assume_yes" ]; then
        if [ ! -t 0 ]; then
            rm -f "$list"
            error "Not asking without a terminal; pass --yes to clean anyway"
            return 1
        fi
        read -rp "  Proceed? [y/N] " answer
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *) rm -f "$list"; info "Cancelled"; return 0 ;;
        esac
    fi
    # Act on exactly the files that were shown
    cleanup_run "$dir" "$days" "$action" manual "$list"
    local rc=$?
    rm -f "$list"
    return $rc
}

# olecharms windows [sync|status] — WSL only: manage the Windows side now
cmd_windows() {
    if [ -z "${IS_WSL:-}" ]; then
        error "'olecharms windows' only works from WSL"
        return 1
    fi
    load_config || return 1
    case "${1:-sync}" in
        sync)
            echo -e "${BOLD}olecharms windows${NC}"
            echo ""
            if ! win_env_load; then
                error "Cannot reach Windows from WSL (interop disabled or powershell.exe missing)"
                return 1
            fi
            install_windows_fonts
            install_windows_vim
            ;;
        status)
            echo -e "${BOLD}olecharms windows status${NC}"
            DOC_OK=0 DOC_WARN=0 DOC_FAIL=0
            doctor_check_windows
            [ "$DOC_FAIL" -eq 0 ]
            ;;
        *)
            error "Usage: olecharms windows [sync|status]"
            return 1
            ;;
    esac
}

# How the new alias becomes usable right away, if at all
alias_activation_note() {
    if [ -n "${OLECHARMS_SHELL_WRAPPER:-}" ]; then
        info "Ready to use in this session."
    else
        info "Active in new shells. For this one: source \"$ALIAS_FILE\""
    fi
}

alias_add() {
    local global="" file=""
    case "${1:-}" in
        --global|-g) global=1 file="$GLOBAL_ALIAS_FILE"; shift ;;
    esac
    local name="${1:-}"
    [ $# -gt 0 ] && shift
    local cmd="$*"
    # Several words: the shell already removed the user's quotes, so
    # `alias add gc git commit -m "fix bug"` would store `-m fix bug`. Re-quote
    # the words holding whitespace; leave the rest alone so $VARS and globs
    # still expand when the alias runs.
    if [ $# -gt 1 ]; then
        local word q="'"
        cmd=""
        for word in "$@"; do
            case "$word" in
                ""|*[[:space:]]*) word="$q${word//$q/$q\\$q$q}$q" ;;
            esac
            cmd="${cmd:+$cmd }$word"
        done
    fi

    if [ -z "$name" ] || [ -z "$cmd" ]; then
        error "Usage: olecharms alias add [--global] <name> <command...>"
        return 1
    fi
    if ! alias_name_valid "$name"; then
        error "Invalid alias name: $name (letters, digits, _ . - ; must not start with a digit)"
        return 1
    fi
    # The alias file holds one alias per line, and a tab separates name from
    # command internally — either character would corrupt it.
    case "$cmd" in
        *$'\n'*|*$'\t'*)
            error "Alias commands must be a single line without tabs"
            return 1
            ;;
    esac
    if [ -n "$global" ] && ! global_alias_upstream >/dev/null; then
        error "Global aliases need $SCRIPT_DIR on a branch that tracks a remote one"
        return 1
    fi

    local existing scope=""
    existing=$(alias_get "$name" "$file")
    [ -n "$global" ] && scope="global "

    echo ""
    if [ -n "$existing" ]; then
        echo -e "  ${BOLD}Replace${NC} ${scope}alias ${BOLD}${name}${NC}"
        echo "    old: $existing"
        echo "    new: $cmd"
    else
        echo -e "  ${BOLD}Add${NC} ${scope}alias ${BOLD}${name}${NC}"
        echo "    $cmd"
        # Set by the shell wrapper: sees oh-my-zsh aliases and functions
        if [ -n "${OLECHARMS_NAME_TYPE:-}" ]; then
            warn "  Note: ${OLECHARMS_NAME_TYPE} — your alias will take precedence."
        elif check_command "$name"; then
            warn "  Note: '$name' is also a command at $(command -v "$name") — the alias will shadow it."
        fi
    fi
    [ -n "$global" ] && echo "    (committed and pushed: every machine with olecharms gets it)"
    echo ""

    local verb=Add
    [ -n "$existing" ] && verb=Replace
    if ! confirm_default_yes "  $verb this alias?"; then
        info "Cancelled"
        return 0
    fi

    if [ -n "$global" ]; then
        alias_save_global "$name" "$cmd"
        [ $? -eq 0 ] || return 1
        return 0
    fi
    alias_set "$name" "$cmd" || return 1
    info "Alias '$name' saved to $ALIAS_FILE"
    alias_activation_note
}

alias_delete() {
    local name="${1:-}"

    if [ -z "$name" ]; then
        error "Usage: olecharms alias delete <name>"
        return 1
    fi

    local existing global_cmd
    existing=$(alias_get "$name")
    global_cmd=$(alias_get "$name" "$GLOBAL_ALIAS_FILE")
    if [ -z "$existing" ] && [ -z "$global_cmd" ]; then
        error "No such alias: $name"
        return 1
    fi

    # The per-machine alias goes first; a global one of the same name is
    # then what applies here, and needs a second delete.
    if [ -n "$existing" ]; then
        echo ""
        echo -e "  ${BOLD}Delete${NC} alias ${BOLD}${name}${NC}"
        echo "    $existing"
        echo ""
        if ! confirm_default_yes "  Delete this alias?"; then
            info "Cancelled"
            return 0
        fi
        alias_unset "$name" || return 1
        info "Alias '$name' deleted"
        [ -n "$global_cmd" ] && info "The global alias '$name' applies here now: $global_cmd"
        alias_activation_note
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Delete${NC} global alias ${BOLD}${name}${NC} — from every machine with olecharms"
    echo "    $global_cmd"
    echo ""
    if ! confirm_default_no "  Delete it everywhere (commit + push)?"; then
        info "Cancelled"
        return 0
    fi
    global_alias_publish "Remove global alias $name" alias_unset "$name" "$GLOBAL_ALIAS_FILE"
    case $? in
        0) info "Global alias '$name' deleted: other machines drop it with their next 'olecharms update'" ;;
        1) return 1 ;;
    esac
    alias_activation_note
}

alias_show_list() {
    local lc gc width=0 name cmd
    lc=$(alias_count)
    gc=$(alias_count "$GLOBAL_ALIAS_FILE")
    if [ "$lc" -eq 0 ] && [ "$gc" -eq 0 ]; then
        echo "  (no aliases defined — add one with: olecharms alias add <name> <command...>,"
        echo "   or pick a recent command with: olecharms aliaslast)"
        return 0
    fi

    # Pad the name column to the widest name
    while IFS=$'\t' read -r name cmd; do
        [ ${#name} -gt "$width" ] && width=${#name}
    done < <(alias_list_raw; alias_list_raw "$GLOBAL_ALIAS_FILE")

    if [ "$gc" -gt 0 ]; then
        [ "$lc" -gt 0 ] && echo -e "  ${BOLD}Global${NC} (every machine)"
        while IFS=$'\t' read -r name cmd; do
            if [ -n "$(alias_get "$name")" ]; then
                printf "  ${GREEN}%-${width}s${NC}  %s  ${YELLOW}(overridden here)${NC}\n" "$name" "$cmd"
            else
                printf "  ${GREEN}%-${width}s${NC}  %s\n" "$name" "$cmd"
            fi
        done < <(alias_list_raw "$GLOBAL_ALIAS_FILE")
        [ "$lc" -gt 0 ] && echo "" && echo -e "  ${BOLD}This machine${NC}"
    fi
    while IFS=$'\t' read -r name cmd; do
        printf "  ${GREEN}%-${width}s${NC}  %s\n" "$name" "$cmd"
    done < <(alias_list_raw)
}

alias_usage() {
    echo "  olecharms alias add [--global] <name> <command...>   Create or replace an alias"
    echo "  olecharms alias list                                 Show all aliases"
    echo "  olecharms alias delete <name>                        Remove an alias"
    echo "  olecharms aliaslast                                  Pick a recent command and save it as an alias"
}

cmd_alias() {
    local sub="${1:-list}"
    [ $# -gt 0 ] && shift

    case "$sub" in
        add|set)
            alias_add "$@"
            ;;
        delete|remove|rm|del)
            alias_delete "$@"
            ;;
        list|ls|"")
            echo -e "${BOLD}olecharms aliases${NC}"
            echo ""
            alias_show_list
            echo ""
            echo "  This machine: $ALIAS_FILE"
            echo "  Global:       $GLOBAL_ALIAS_FILE (in git)"
            ;;
        *)
            error "Unknown alias subcommand: $sub"
            echo ""
            alias_usage
            return 1
            ;;
    esac
}

# `olecharms sync`: the light update — pull the checkout (new global aliases,
# config and code), then the offline, local steps with the code just pulled.
# Packages and plugins are left to `update`.
cmd_sync() {
    local local_only="" arg before after snap
    for arg in "$@"; do
        case "$arg" in
            --local) local_only=1 ;;
            -h|--help) echo "Usage: olecharms sync   (pull the checkout, refresh shell, vim and schedules; no packages or plugins)"; return 0 ;;
            *) error "Unknown sync option: $arg"; return 1 ;;
        esac
    done
    load_config || return 1

    if [ -z "$local_only" ]; then
        if [ ! -d "$SCRIPT_DIR/.git" ]; then
            error "$SCRIPT_DIR is not a git checkout; there is nothing to pull"
            return 1
        fi
        before=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
        info "Pulling $SCRIPT_DIR..."
        checkout_pull
        case $? in
            1) return 1 ;;
            2) error "Could not pull${CHECKOUT_PULL_ERR:+: $CHECKOUT_PULL_ERR}"; return 1 ;;
        esac
        after=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
        if [ "$before" = "$after" ]; then
            info "Already up to date"
        else
            info "New since last time:"
            git -C "$SCRIPT_DIR" log --oneline --no-decorate "$before..$after" 2>/dev/null | head -n 15 | sed 's/^/    /'
        fi
        if ! bash -n "$SCRIPT_PATH" 2>/dev/null; then
            error "The pulled $SCRIPT_PATH has syntax errors; stopping here"
            return 1
        fi
        # Finish with the code just pulled
        exec bash "$SCRIPT_PATH" sync --local
    fi

    snap=$(shell_config_snapshot)
    run_local_steps
    if [ "$snap" != "$(shell_config_snapshot)" ]; then
        info "Shell configuration changed — open a new shell (or run 'exec zsh') to pick it all up"
    fi
    info "Synced. Packages and vim plugins are updated by 'olecharms update'."
    shared_offer_after_pull
}

# Pick one of the latest commands from the shell history, name it, save it as
# an alias — on this machine, or for every machine through git.
cmd_aliaslast() {
    local line cmd name rc
    # The snapshot holds recent history: remove it however this ends. The
    # wrapper's own cleanup does not run when Ctrl-C aborts it in zsh.
    if [ -n "${OLECHARMS_SHELL_SNAPSHOT:-}" ] && [ -d "$OLECHARMS_SHELL_SNAPSHOT" ]; then
        case "${OLECHARMS_SHELL_SNAPSHOT##*/}" in
            olecharms.*)
                trap 'snapshot_remove "$OLECHARMS_SHELL_SNAPSHOT"' EXIT
                trap 'exit 130' INT TERM
                ;;
        esac
    fi
    PICK_ITEMS=()
    while IFS= read -r line; do
        PICK_ITEMS+=("$line")
    done < <(aliaslast_history)
    if [ ${#PICK_ITEMS[@]} -eq 0 ]; then
        error "No shell history to pick a command from"
        if [ -z "${OLECHARMS_SHELL_SNAPSHOT:-}" ]; then
            echo "  Run it from your shell as 'olecharms aliaslast': the olecharms shell"
            echo "  function hands over the history, even when no history file is kept."
        fi
        return 1
    fi

    echo -e "${BOLD}Save a recent command as an alias${NC}"
    echo ""
    if ! pick_item; then
        info "Cancelled"
        return 0
    fi
    cmd=${PICK_ITEMS[$PICK_INDEX]}
    echo -e "  Command: ${BOLD}${cmd}${NC}"
    echo ""

    while :; do
        if [ -t 0 ]; then
            read -rp "  Alias name: " name || { echo ""; info "Cancelled"; return 0; }
        else
            read -r name || { info "Cancelled"; return 0; }
        fi
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        if [ -z "$name" ]; then
            info "Cancelled"
            return 0
        fi
        if ! alias_name_valid "$name"; then
            error "Invalid alias name: $name (letters, digits, _ . - ; must not start with a digit)"
            continue
        fi
        if alias_conflicts "$name"; then
            confirm_default_no "  Use '$name' anyway?" || continue
        fi
        break
    done

    echo ""
    if global_alias_upstream >/dev/null; then
        if confirm_default_no "  Make '$name' global, for every machine with olecharms (commit + push)?"; then
            alias_save_global "$name" "$cmd"
            rc=$?
            [ "$rc" -eq 0 ] && return 0
            [ "$rc" -eq 2 ] && return 1
            warn "Saving '$name' on this machine only"
        fi
    fi
    alias_set "$name" "$cmd" || return 1
    info "Alias '$name' saved: $name → $cmd"
    [ -n "$(alias_get "$name" "$GLOBAL_ALIAS_FILE")" ] && info "On this machine it overrides the global alias '$name'"
    alias_activation_note
}

cmd_help() {
    echo -e "${BOLD}olecharms${NC} — Environment management for olecharms"
    echo ""
    echo -e "Usage: ${BOLD}olecharms${NC} <command>"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  install   Full idempotent setup: self-update, packages, vim, plugins, fonts, omz"
    echo "  update    Same as install (alias for convenience)"
    echo "  sync      Light update: pull the checkout (global aliases, config, code) and"
    echo "            refresh shell, vim and schedules — no packages or plugins"
    echo "  doctor    Check the whole setup, exit 1 on problems; --fix repairs what it can"
    echo "            (also runs once a day in the background; new shells mention problems)"
    echo "            offline (alias: check)"
    echo "  status    Show what's installed with version info"
    echo "  config    Interactive menu: downloads cleanup, paranoid mode, Windows sync (WSL),"
    echo "            settings shared by all your machines, zsh extras (fzf...)"
    echo "  cleanup   Clean the downloads folder now; --dry-run lists what would go,"
    echo "            --log shows past runs"
    echo "  alias     Manage shell aliases (add / list / delete); --global shares one"
    echo "            with every machine through git"
    echo "  aliaslast Pick one of your latest commands and save it as an alias"
    echo "  secret    Keep API keys and tokens out of your RC files (set / list / rm / import)"
    [ -n "${IS_WSL:-}" ] && echo "  windows   Sync Windows' gVim (config, plugins) and fonts now; 'status' to check"
    echo "  help      Show this help message"
    echo ""
    echo -e "${BLUE}Aliases:${NC}"
    alias_usage

    # Dynamically list shell commands from shell/*.sh
    local shell_files=("$SHELL_DIR"/*.sh)
    if [ -e "${shell_files[0]}" ]; then
        echo ""
        echo -e "${BLUE}Shell commands:${NC}"
        for f in "${shell_files[@]}"; do
            local line
            line=$(head -1 "$f")
            # Expect format: # name — description
            local name detail
            name=$(echo "$line" | sed -n 's/^# *\([^ ]*\).*/\1/p')
            detail=$(echo "$line" | sed -n 's/^# *[^ ]* *— *//p')
            if [ -n "$name" ]; then
                printf "  %-10s %s\n" "$name" "$detail"
            fi
        done
    fi

    echo ""
    echo -e "${BLUE}Configuration:${NC}"
    echo "  packages.conf lists system packages, vim plugins, font families and post-install"
    echo "  commands. Per-machine additions go in $LOCAL_CONF_FILE,"
    echo "  which updates never touch."
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  olecharms install    # First-time setup"
    echo "  olecharms update     # Update everything"
    echo "  olecharms doctor     # Find (and --fix) anything broken"
    echo "  olecharms cleanup -n # Preview the downloads cleanup"
    echo "  olecharms config     # Toggle system features"
    echo "  olecharms alias add gs git status"
    echo "  olecharms alias add claude \"claude --update && claude\""
}

# ─── Secrets: API keys and tokens out of the RC files ───────────────────────
# One file, readable only by you, loaded by the shell loader:
#   export NAME='value'
# RC files get copied around (backups, dotfiles repos, screen shares); the
# secrets file is never in git and never backed up by olecharms.

# Path $1 with the home directory shown as ~
home_tilde() {
    case "$1" in
        "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
        *)         printf '%s\n' "$1" ;;
    esac
}

# True unless $2 (an edited copy of RC file $1) fails to parse where $1 did
rc_parses_like() {
    local sh=bash
    case "$1" in */.z*) sh=zsh ;; esac
    check_command "$sh" || return 0
    "$sh" -n "$1" >/dev/null 2>&1 || return 0
    "$sh" -n "$2" >/dev/null 2>&1
}

# Line numbers of file $1 that are outside any if/case/loop/function/{ }
# block. Rough (quotes and comments are stripped first; here-documents are
# not understood), but enough not to lift a line out of a block — zsh -n
# accepts an emptied block, so the parse check alone would not catch it.
rc_toplevel_lines() {
    awk '
        {
            line = $0
            gsub(/\047[^\047]*\047/, "", line)
            gsub(/"[^"]*"/, "", line)
            sub(/(^|[ \t])#.*/, "", line)
            if (depth == 0) print NR
            n = split(line, w, /[ \t;&|()]+/)
            for (i = 1; i <= n; i++) {
                if (w[i] == "if" || w[i] == "case" || w[i] == "do" || w[i] == "{") depth++
                else if (w[i] == "fi" || w[i] == "esac" || w[i] == "done" || w[i] == "}") depth--
            }
            if (depth < 0) depth = 0
        }
    ' "$1"
}

# A variable name that looks like it holds a secret
secret_name_like() {
    local up
    up=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    [[ "$up" =~ (^|_)(API_?KEY|APIKEY|KEYS?|TOKENS?|SECRETS?|PASS|PASSWORD|PASSWD|PAT|CREDENTIALS?)($|_) ]]
}

# NAME=value assignments in the shell startup files that look like secrets
# with a literal value: "file<TAB>line<TAB>NAME" per match. Values built
# from other variables or commands ($VAR, $(pass show x)) are not secrets in
# the file and are skipped, as are lines olecharms cannot move safely.
SECRET_RC_FILES=".zshrc .bashrc .bash_profile .profile .zprofile .zshenv .zlogin"
SECRETS_MARKER="# olecharms secrets"
secret_scan() {
    local rel f n line name rest re_assign re_value
    # Unindented lines only: an indented one is likely inside an if/fi or a
    # function, and taking it out could leave that block empty and broken
    re_assign='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
    re_value="^('[^']+'|\"[^\"\$\`\\\\]+\"|[^[:space:]'\"\$\`;|&()<>\\\\]+)[[:space:]]*(#.*)?$"
    local top
    for rel in $SECRET_RC_FILES; do
        f="$HOME/$rel"
        [ -f "$f" ] || continue
        top=" $(rc_toplevel_lines "$f" | tr '\n' ' ') "
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            case "$top" in *" $n "*) ;; *) continue ;; esac
            [[ "$line" =~ $re_assign ]] || continue
            name=${BASH_REMATCH[2]}
            rest=${BASH_REMATCH[3]}
            secret_name_like "$name" || continue
            [[ "$rest" =~ $re_value ]] || continue
            printf '%s\t%s\t%s\n' "$f" "$n" "$name"
        done < "$f"
    done
}

# Stored names, one per line
secret_names() {
    [ -f "$SECRETS_FILE" ] || return 0
    sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$SECRETS_FILE"
}

# Rewrite the secrets file through filter command "$@" (stdin → stdout),
# private from the first byte
secret_rewrite() {
    local tmp
    mkdir -p "$OLECHARMS_CONFIG_DIR" || return 1
    tmp=$( umask 077; mktemp "$OLECHARMS_CONFIG_DIR/.secrets.XXXXXX" ) || return 1
    if { [ -f "$SECRETS_FILE" ] && cat "$SECRETS_FILE"; } | "$@" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SECRETS_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    error "Could not write $SECRETS_FILE"
    return 1
}

# Filters for secret_rewrite
_secret_drop() { grep -v -E "^[[:space:]]*(export[[:space:]]+)?$1=" || true; }
_secret_put()  { _secret_drop "$1"; printf '%s\n' "$2"; }

secret_valid_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { error "Not a valid variable name: $1"; return 1; }
    case "$1" in
        PATH|HOME|SHELL|USER|LOGNAME|TERM|PWD|OLDPWD|IFS|PS1|PS2|ZDOTDIR|LANG|LC_*)
            error "$1 is a shell variable, not a secret"; return 1 ;;
    esac
}

secret_set() {
    local name="$1" value value2 q
    secret_valid_name "$name" || return 1
    if [ -t 0 ]; then
        read -rsp "  Value for $name (not shown): " value; echo ""
        read -rsp "  Once more: " value2; echo ""
        [ "$value" = "$value2" ] || { error "The two values differ; nothing stored"; return 1; }
    else
        IFS= read -r value || [ -n "$value" ] || true
    fi
    [ -n "$value" ] || { info "Empty value; nothing stored"; return 1; }
    q=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
    secret_rewrite _secret_put "$name" "export $name='$q'" || return 1
    info "$name stored in $SECRETS_FILE (only you can read it); new shells and this one have it"
}

secret_rm() {
    local name="$1"
    secret_valid_name "$name" || return 1
    if ! secret_names | grep -qxF -- "$name"; then
        error "No secret named $name"
        return 1
    fi
    secret_rewrite _secret_drop "$name" || return 1
    info "$name removed"
}

secret_list() {
    local names
    names=$(secret_names)
    if [ -z "$names" ]; then
        echo "  No secrets stored. Add one with: olecharms secret set NAME"
        return 0
    fi
    echo "  Stored in $SECRETS_FILE (values are never shown):"
    printf '%s\n' "$names" | sed 's/^/    /'
}

# Move the lines secret_scan finds into the secrets file. The lines leave the
# RC file without a backup copy of it: a backup would keep the secret in
# plain text, and the lines themselves are what goes to the secrets file.
# $1: "yes" to skip the question (the doctor already asked).
secret_import() {
    local found f n name line file lines moved=0 tmp
    found=$(secret_scan)
    if [ -z "$found" ]; then
        info "No secrets in plain text in your shell startup files"
        return 0
    fi
    echo "  Found in plain text (values not shown):"
    printf '%s\n' "$found" | while IFS=$'\t' read -r f n name; do
        echo "    $name   ($(home_tilde "$f"), line $n)"
    done
    if [ "${1:-}" != yes ]; then
        echo ""
        confirm_default_yes "  Move them to $SECRETS_FILE, readable only by you?" || { info "Nothing moved"; return 0; }
    fi
    for file in $(printf '%s\n' "$found" | cut -f1 | sort -u); do
        lines=$(printf '%s\n' "$found" | awk -F'\t' -v f="$file" '$1 == f { print $2 }')
        for n in $lines; do
            line=$(sed -n "${n}p" "$file")
            line=${line#"${line%%[![:space:]]*}"}
            name=$(printf '%s\n' "$found" | awk -F'\t' -v f="$file" -v n="$n" '$1 == f && $2 == n { print $3 }')
            secret_rewrite _secret_put "$name" "$line" || return 1
            moved=$((moved + 1))
        done
        # The first of those lines becomes one that loads the secrets file,
        # so later lines of this file that use them (and shells that read
        # only this file: .zshenv, .profile...) still see them; the others
        # go. Not if the result no longer parses, and written in place
        # (keeping the file's mode) with a private copy until it succeeded.
        local first repl keep expect
        first=$(echo $lines | cut -d' ' -f1)
        repl="[ -f \"\$HOME/${SECRETS_FILE#"$HOME"/}\" ] && . \"\$HOME/${SECRETS_FILE#"$HOME"/}\"  $SECRETS_MARKER"
        case "$SECRETS_FILE" in "$HOME"/*) ;; *) repl="[ -f \"$SECRETS_FILE\" ] && . \"$SECRETS_FILE\"  $SECRETS_MARKER" ;; esac
        grep -qF -- "$SECRETS_MARKER" "$file" && repl=""
        tmp=$(mktemp) || return 1
        awk -v del=" $(echo $lines) " -v first="$first" -v repl="$repl" '
            FNR == first && repl != "" { print repl; next }
            index(del, " " FNR " ") == 0' "$file" > "$tmp"
        expect=$(( $(wc -l < "$file") - $(echo $lines | wc -w) + $([ -n "$repl" ] && echo 1 || echo 0) ))
        if [ "$(wc -l < "$tmp")" -ne "$expect" ]; then
            error "Unexpected result editing $file; left as it was"
        elif ! rc_parses_like "$file" "$tmp"; then
            error "$file would not parse without those lines; left as it was (remove them by hand)"
        elif ! keep=$( umask 077; mktemp "$OLECHARMS_CONFIG_DIR/.rc-original.XXXXXX" ) || ! cp "$file" "$keep"; then
            rm -f "$keep"
            error "Could not keep a private copy of $file; left as it was"
        elif cat "$tmp" > "$file"; then
            rm -f "$keep"
        elif cat "$keep" > "$file" 2>/dev/null; then
            rm -f "$keep"
            error "Could not write $file (disk full?); it is back as it was"
        else
            error "Could not write $file; its original is in $keep (readable only by you)"
        fi
        rm -f "$tmp"
    done
    info "Moved $moved secret(s) to $SECRETS_FILE; the shell loader loads them in every new shell"
    secret_backup_note
}

# Old backups of the RC files (olecharms' *.backup.<date>) holding the same
# names in plain text: print them, one per line
secret_backups() {
    local names f
    names=$( { secret_names; secret_scan | cut -f3; } | sort -u )
    [ -n "$names" ] || return 0
    for f in "$HOME"/.zshrc.backup.* "$HOME"/.bashrc.backup.* "$HOME"/.bash_profile.backup.*; do
        [ -f "$f" ] || continue
        if grep -qE "^[[:space:]]*(export[[:space:]]+)?($(printf '%s\n' "$names" | paste -sd'|' -))=[^\$]" "$f"; then
            printf '%s\n' "$f"
        fi
    done
}

secret_backup_note() {
    local b
    b=$(secret_backups)
    [ -n "$b" ] || return 0
    warn "$(printf '%s\n' "$b" | grep -c .) older backup(s) of your RC files still hold them in plain text:"
    printf '%s\n' "$b" | sed 's/^/      /'
    echo "      Delete them once you no longer need them (olecharms doctor --fix can make them private)."
}

# Backups listed by secret_backups, readable only by you
secret_backups_private() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && chmod 600 "$f"
    done <<< "$(secret_backups)"
}

doctor_check_secrets() {
    local found names b mode
    if [ -f "$SECRETS_FILE" ]; then
        mode=$(ls -ln "$SECRETS_FILE" 2>/dev/null | cut -c1-10)
        if [ "$mode" = "-rw-------" ]; then
            doc_ok "Secrets: $(secret_names | grep -c .) stored, readable only by you"
        else
            doc_warn "The secrets file can be read by others ($mode)"
            doc_offer "Make $SECRETS_FILE readable only by you (chmod 600)?" chmod 600 "$SECRETS_FILE"
            doc_hint "olecharms doctor --fix, or: chmod 600 \"$SECRETS_FILE\""
        fi
    fi
    found=$(secret_scan)
    if [ -n "$found" ]; then
        names=$(printf '%s\n' "$found" | while IFS=$'\t' read -r f n name; do printf '%s (%s), ' "$name" "$(home_tilde "$f")"; done)
        names=${names%, }
        doc_warn "Secrets in plain text in your shell startup files: $names"
        doc_why "Anything that reads or copies those files (backups, dotfiles repos, screen shares) takes them along."
        doc_hint "olecharms secret import  (moves them to a file only you can read; doctor --fix offers it)"
        doc_offer "Move them to $SECRETS_FILE, readable only by you (values are never printed)?" secret_import yes
    fi
    b=$(secret_backups)
    if [ -n "$b" ]; then
        if [ -z "$(printf '%s\n' "$b" | while IFS= read -r f; do [ "$(ls -ln "$f" | cut -c5-10)" != "------" ] && echo x; done)" ]; then
            doc_ok "$(printf '%s\n' "$b" | grep -c .) old RC backup(s) with secrets are private to you (delete them when no longer needed)"
        else
            doc_warn "$(printf '%s\n' "$b" | grep -c .) old backup(s) of your RC files hold secrets in plain text, readable by others"
            doc_why "$(printf '%s\n' "$b" | while IFS= read -r f; do home_tilde "$f"; done | paste -sd' ' -)"
            doc_hint "Delete them if you do not need them; olecharms doctor --fix makes them private"
            doc_offer "Make those backups readable only by you (chmod 600)?" secret_backups_private
        fi
    fi
}

secret_usage() {
    echo "Usage: olecharms secret <command>"
    echo ""
    echo "  set NAME     store a secret (asks for it without showing it); every shell gets \$NAME"
    echo "  list         the names stored (values are never shown)"
    echo "  rm NAME      forget one"
    echo "  import       move NAME=value lines that look like secrets out of your RC files"
    echo ""
    echo "  Kept in $SECRETS_FILE: on this machine only, readable only by you, never in git."
}

cmd_secret() {
    case "${1:-}" in
        set|add)            [ -n "${2:-}" ] || { secret_usage; return 1; }; secret_set "$2" ;;
        rm|remove|delete)   [ -n "${2:-}" ] || { secret_usage; return 1; }; secret_rm "$2" ;;
        list|ls|"")         secret_list ;;
        import)             secret_import ;;
        -h|--help|help)     secret_usage ;;
        *)                  error "Unknown secret command: $1"; secret_usage; return 1 ;;
    esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    # Everything olecharms installs lands in $HOME. Running as root silently
    # sets up root's environment instead of the user's.
    if [ "$(id -u 2>/dev/null)" = "0" ] && [ -z "${OLECHARMS_ALLOW_ROOT:-}" ]; then
        case "${1:-}" in
            install|update|config)
                warn "Running as root — everything will be installed under $HOME, not your user's home."
                warn "Run as your normal user, or set OLECHARMS_ALLOW_ROOT=1 to silence this."
                ;;
        esac
    fi

    detect_os

    # For operational commands, ensure config is loaded and check for moved install
    case "${1:-}" in
        install|update|config|sync)
            config_ensure
            fix_moved_install fix
            ;;
        alias|aliaslast|cleanup|windows|secret)
            config_ensure
            ;;
        doctor|check)
            config_ensure
            # doctor --fix repairs a moved checkout itself
            case " $* " in
                *" --fix "*) fix_moved_install fix ;;
                *)           fix_moved_install warn ;;
            esac
            ;;
        status)
            config_ensure
            fix_moved_install warn
            ;;
    esac

    local cmd_rc=0
    case "${1:-}" in
        install) cmd_install || cmd_rc=$? ;;
        update)  cmd_update || cmd_rc=$? ;;
        sync)    shift; cmd_sync "$@" || cmd_rc=$? ;;
        doctor|check) shift; cmd_doctor "$@" || cmd_rc=$? ;;
        status)  cmd_status || cmd_rc=$? ;;
        config)  cmd_config || cmd_rc=$? ;;
        cleanup) shift; cmd_cleanup "$@" || cmd_rc=$? ;;
        windows) shift; cmd_windows "$@" || cmd_rc=$? ;;
        alias)   shift; cmd_alias "$@" || cmd_rc=$? ;;
        aliaslast) shift; cmd_aliaslast "$@" || cmd_rc=$? ;;
        secret)  shift; cmd_secret "$@" || cmd_rc=$? ;;
        help|--help|-h) cmd_help ;;
        "")
            cmd_help
            ;;
        *)
            error "Unknown command: $1"
            echo ""
            cmd_help
            exit 1
            ;;
    esac

    # Surface failures to callers (CI, cron, `&&` chains) instead of always 0.
    # The command's own status counts too: an error() raised inside a pipeline
    # runs in a subshell and never reaches ERROR_COUNT.
    [ "$ERROR_COUNT" -gt 0 ] && [ "$cmd_rc" -eq 0 ] && cmd_rc=1
    return "$cmd_rc"
}

main "$@"
exit $?
