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
# Per-machine package/plugin additions, sourced after the tracked packages.conf
# so local changes never collide with a self-update's git pull.
LOCAL_CONF_FILE="$OLECHARMS_CONFIG_DIR/packages.local.conf"
OLECHARMS_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/olecharms"
CLEANUP_LOG="$OLECHARMS_STATE_DIR/cleanup.log"
CLEANUP_LOG_MAX_LINES=10000
# Stamped into every generated script; `doctor` flags older ones.
GENERATOR_VERSION=3
GENERATOR_STAMP="# olecharms-generator:"
# Marks the plugin copies olecharms owns inside Windows' vimfiles\bundle
WIN_MANAGED_STAMP=".olecharms-managed"
WIN_VIMRC_LINE="source ~/vimfiles/olecharms/olevimrc.vim"
CURRENT_CONFIG_VERSION=3

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
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; ERROR_COUNT=$((ERROR_COUNT + 1)); }

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

clone_or_pull() {
    local url="$1"
    local dest="$2"
    local name="$3"
    local fallback="$4"  # optional bundled fallback path

    if [ -d "$dest/.git" ]; then
        info "Updating $name..."
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
        ( "$script" >/dev/null 2>&1 & )
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
        if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
            echo "_olecharms_check_and_run \"\$_olecharms_hook_dir/paranoid-cleanup.sh\" \"paranoid-cleanup\" $PARANOID_INTERVAL"
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
        { is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; }
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
        echo "_olecharms_bin=$(printf '%q' "$SCRIPT_PATH")"
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

# Drop the aliases loaded last time, then load the current set. Run at shell
# start, and again by the wrapper below after an `olecharms alias` command.
_olecharms_reload_aliases() {
    if command -v _olecharms_unload_aliases >/dev/null 2>&1; then
        _olecharms_unload_aliases
        unset -f _olecharms_unload_aliases 2>/dev/null
    fi
    [ -f "$_olecharms_alias_file" ] && . "$_olecharms_alias_file"
    return 0
}
_olecharms_reload_aliases

# A child process cannot change its parent shell, so wrap the command and act
# here: reload aliases after `olecharms alias`, and after a clean `install`
# replace this shell with a fresh login zsh — instead of the child nesting a
# new shell inside this one, where `exit` would drop back to the stale shell.
olecharms() {
    # The child bash cannot see this shell's aliases and functions (oh-my-zsh
    # defines hundreds), so tell `alias add` what the name means here.
    local _olecharms_what="" _olecharms_rc
    if [ "${1:-}" = alias ] && [ "${2:-}" = add ] && [ -n "${3:-}" ]; then
        _olecharms_what=$(type -- "$3" 2>/dev/null) || _olecharms_what=""
        _olecharms_what=${_olecharms_what%%$'\n'*}
    fi
    OLECHARMS_SHELL_WRAPPER=1 OLECHARMS_NAME_TYPE="$_olecharms_what" "$_olecharms_bin" "$@"
    _olecharms_rc=$?
    case "${1:-}" in
        alias) [ $_olecharms_rc -eq 0 ] && _olecharms_reload_aliases ;;
        install)
            if [ $_olecharms_rc -eq 0 ] && [ -t 0 ] && [ -t 1 ] && command -v zsh >/dev/null 2>&1; then
                echo "[+] Reloading this shell as a login zsh..."
                exec zsh -l
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

    sync_shell_hook
    info "Downloads auto-cleanup disabled"

    # Sync to config file
    config_set downloads_cleanup_enabled false
    config_set downloads_cleanup_dir ""
    config_set downloads_cleanup_method hook
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
    cat > "$tmp" <<PARANOID_EOF
#!/bin/bash
# Generated by olecharms — edit via 'olecharms config', not by hand.
$GENERATOR_STAMP $GENERATOR_VERSION
HOME_DIR=$(printf '%q' "$HOME")
VIM_DIR=$(printf '%q' "$VIM_DIR")

# Purge shell history
rm -f "\$HOME_DIR/.bash_history" "\$HOME_DIR/.zsh_history" 2>/dev/null

# Purge vim swap and undo files
find -H "\$VIM_DIR/swapfiles" -type f -delete 2>/dev/null
find -H "\$VIM_DIR/undodir" -type f -delete 2>/dev/null
exit 0
PARANOID_EOF
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

# Emit "name<TAB>command" for every stored alias. awk rather than sed: BSD/macOS
# sed has no \t in replacements. Plain POSIX awk, so mawk and BWK awk work too.
alias_list_raw() {
    [ -f "$ALIAS_FILE" ] || return 0
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
        }' "$ALIAS_FILE"
}

# Every stored alias except $1, compared exactly: a grep pattern would treat
# the "." allowed in names as a wildcard and drop "gas" along with "g.s".
alias_list_except() {
    alias_list_raw | awk -F'\t' -v n="$1" '$1 != n'
}

alias_get() {
    local name="$1"
    alias_list_raw | awk -F'\t' -v n="$name" '$1 == n { print substr($0, index($0, "\t") + 1); exit }'
}

alias_names() {
    alias_list_raw | cut -f1
}

alias_count() {
    alias_list_raw | grep -c . || true
}

# Rewrite the alias file from "name<TAB>command" lines on stdin.
alias_write_all() {
    local tmpfile status
    mkdir -p "$OLECHARMS_CONFIG_DIR" || { error "Could not create $OLECHARMS_CONFIG_DIR"; return 1; }
    tmpfile=$(mktemp) || { error "mktemp failed"; return 1; }

    {
        echo "$ALIAS_MARKER"
        echo "# Sourced by scripts/olecharms-shell.sh from your shell rc files."
        local name cmd unload=""
        while IFS=$'\t' read -r name cmd; do
            [ -n "$name" ] || continue
            echo "alias ${name}=$(alias_quote "$cmd")"
            unload="$unload unalias ${name} 2>/dev/null;"
        done
        # The loader calls this before re-sourcing the file, so an alias that
        # was just deleted also disappears from the running shell. Emitted as a
        # function rather than a name list because zsh does not word-split
        # unquoted parameters.
        echo "_olecharms_unload_aliases() {${unload} return 0; }"
    } > "$tmpfile"

    write_file_contents "$tmpfile" "$ALIAS_FILE"
    status=$?
    rm -f "$tmpfile"
    return $status
}

alias_set() {
    local name="$1" cmd="$2"
    { alias_list_except "$name"; printf '%s\t%s\n' "$name" "$cmd"; } \
        | sort -f | alias_write_all
}

alias_unset() {
    alias_list_except "$1" | alias_write_all
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

# ─── Downloads Cleanup Engine ───────────────────────────────────────────────
# One implementation behind `olecharms cleanup`, its --dry-run, the config
# menu preview and the scheduled runs (the generated scripts/cleanup-downloads.sh
# only calls `olecharms cleanup --scheduled`).

# Resolve the folder to clean to its real path, refusing anything that is — or
# leads to — $HOME or /. Prints the real path.
cleanup_real_dir() {
    local dir="$1" real home_real d
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    real=$(cd -P "$dir" 2>/dev/null && pwd) || return 1
    home_real=$(cd -P "$HOME" 2>/dev/null && pwd)
    for d in "$dir" "$real"; do
        d="${d%/}"
        if [ -z "$d" ] || [ "$d" = "${HOME%/}" ] || [ "$d" = "${home_real%/}" ]; then
            return 1
        fi
    done
    printf '%s\n' "$real"
}

# Files older than $2 days under real dir $1, NUL-separated into file $3.
# desktop.ini (Windows) and .localized (macOS) are old by nature but give the
# folder its localized name ("Descargas"), so they always stay.
cleanup_collect() {
    find "$1" -type f -mtime "+$2" ! -name desktop.ini ! -name .localized -print0 2>/dev/null > "$3"
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
                if win_powershell >/dev/null; then
                    echo recycle-bin
                    return 0
                fi
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
                *)                       echo delete ;;
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
    local list="$1" backend="$2" log="$3" root="$4" f verb n_done=0 n_failed=0
    case "$backend" in
        delete)      xargs -0 rm -f < "$list" 2>/dev/null ;;
        gio)         xargs -0 gio trash < "$list" 2>/dev/null ;;
        trash-put)   xargs -0 trash-put < "$list" 2>/dev/null ;;
        macos-trash) cleanup_macos_trash "$list" ;;
        recycle-bin) win_recycle "$list" "$root" >/dev/null ;;
    esac
    verb=trashed
    [ "$backend" = delete ] && verb=deleted
    while IFS= read -r -d '' f; do
        if [ -e "$f" ]; then
            n_failed=$((n_failed + 1))
            printf 'failed   %s\n' "$f"
        else
            n_done=$((n_done + 1))
            printf '%-8s %s\n' "$verb" "$f"
        fi
    done < "$list" >> "$log"
    echo "$n_done $n_failed"
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
    [ -n "$CLEANUP_LOCK" ] && rm -rf "$CLEANUP_LOCK"
    CLEANUP_LOCK=""
}

# One cleanup pass: lock, collect, act, log. $4 is the trigger (scheduled or
# manual); $5 an already collected list to act on. Scheduled runs are silent —
# they run in the background of a new shell — and leave their trace in the log.
cleanup_run() {
    local dir="$1" days="$2" action="$3" trigger="$4" list="${5:-}"
    local own_list="" real backend count kb result n_done n_failed lock
    if ! real=$(cleanup_real_dir "$dir"); then
        cleanup_log_line "$trigger: skipped — ${dir:-<no folder>} is missing or resolves to \$HOME or /"
        [ "$trigger" = scheduled ] || error "Cannot clean ${dir:-<no folder>} (missing, or it resolves to \$HOME or /)"
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
            rm -rf "$lock"
            mkdir "$lock" 2>/dev/null || return 0
        else
            [ "$trigger" = scheduled ] || warn "Another cleanup is running right now; try again in a moment"
            return 0
        fi
    fi
    CLEANUP_LOCK="$lock"
    trap cleanup_release_lock EXIT
    trap 'cleanup_release_lock; exit 130' INT TERM

    if [ -z "$list" ]; then
        list=$(mktemp) || { cleanup_release_lock; return 1; }
        own_list=1
        cleanup_collect "$real" "$days" "$list"
    fi
    count=$(cleanup_count "$list")
    n_done=0
    n_failed=0
    if [ "$count" -gt 0 ]; then
        kb=$(cleanup_size_kb "$list" "$count")
        cleanup_log_line "$trigger  $real  >${days}d  $backend  $count files, $(human_kb "$kb")"
        result=$(cleanup_apply "$list" "$backend" "$CLEANUP_LOG" "$real")
        n_done=${result% *}
        n_failed=${result#* }
        find "$real" -mindepth 1 -type d -empty -delete 2>/dev/null
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
    echo "  Rule:     files older than $days days (desktop.ini and .localized always stay)"
    echo "  Action:   $(cleanup_backend_label "$backend")"
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
$ok = 0; $fail = 0
foreach ($p in [IO.File]::ReadAllLines($ListFile, [Text.Encoding]::UTF8)) {
    if ($p -eq '') { continue }
    $null = [OlecharmsRecycle]::Recycle($p)
    if (Test-Path -LiteralPath $p) { $fail++ } else { $ok++ }
}
"RESULT $ok $fail"
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
    while IFS= read -r line; do
        key=${line%%=*}
        val=${line#*=}
        [ -n "$val" ] || continue
        case "$key" in
            USERPROFILE)    WIN_USERPROFILE=$(wslpath -u "$val" 2>/dev/null) ;;
            LOCALAPPDATA)   WIN_LOCALAPPDATA=$(wslpath -u "$val" 2>/dev/null) ;;
            HOME)           WIN_HOME_RAW=$val ;;
            DOWNLOADS)      WIN_DOWNLOADS=$(wslpath -u "$val" 2>/dev/null) ;;
            PROGRAMFILES)   WIN_PROGRAMFILES=$(wslpath -u "$val" 2>/dev/null) ;;
            PROGRAMFILES86) WIN_PROGRAMFILES86=$(wslpath -u "$val" 2>/dev/null) ;;
            GVIM_REG)       WIN_GVIM_REG=$val ;;
            GVIM_PATH)      WIN_GVIM_PATH=$val ;;
            FONT)           WIN_FONT_FILES="$WIN_FONT_FILES$val"$'\n' ;;
        esac
    done <<< "$out"
    [ -n "$WIN_USERPROFILE" ] && [ -d "$WIN_USERPROFILE" ] || return 1

    # Windows Vim looks for _vimrc and vimfiles in %HOME% when it is set,
    # otherwise in %USERPROFILE%.
    WIN_VIM_HOME="$WIN_USERPROFILE"
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
    WIN_PS_TIMEOUT=3600 win_ps_run "\$ListFile = $(ps_quote "$(wslpath -w "$tmp")")" "$PS_RECYCLE"
    rm -f "$tmp"
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
# auto: Windows Recycle Bin / macOS Trash when there is one, else delete
downloads_cleanup_action=$(config_get downloads_cleanup_action auto)

paranoid_mode_enabled=$(config_get paranoid_mode_enabled false)
paranoid_mode_method=$(config_get paranoid_mode_method hook)

# WSL only: manage Windows' gVim and fonts too (auto | off)
windows_integration=$(config_get windows_integration auto)

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
            enable_downloads_cleanup "$dl_dir" "$dl_method" "$dl_age"
        fi
    fi

    p_enabled=$(config_get paranoid_mode_enabled false)
    if [ "$p_enabled" = "true" ]; then
        p_method=$(config_get paranoid_mode_method hook)
        if [ ! -x "$PARANOID_SCRIPT" ] || { [ "$p_method" = "cron" ] && ! is_paranoid_cron_enabled; }; then
            info "Restoring paranoid mode ($p_method)"
        fi
        enable_paranoid_mode "$p_method"
    fi

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
        for pkg in "${packages[@]}"; do
            if ! dpkg -s "$pkg" >/dev/null 2>&1; then
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
        "${sudo_cmd[@]}" apt-get install -y -qq "${missing[@]}" \
            || error "Some packages failed to install"
    elif [ "$OS" = "macos" ]; then
        if check_command brew; then
            brew install "${missing[@]}" 2>/dev/null || {
                warn "Some brew packages may have already been installed"
            }
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

        if ! clone_or_pull "$url" "$dest" "$name" "$fallback"; then
            [ -d "$dest" ] || error "Plugin $name is not installed and could not be fetched"
        fi
    done
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
        if check_command curl; then
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        elif check_command wget; then
            sh -c "$(wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        else
            error "Neither curl nor wget available. Cannot install Oh My Zsh."
            return 1
        fi

        # Verify the install actually worked
        if [ ! -d "$omz_dir" ]; then
            error "Oh My Zsh installation failed"
            return 1
        fi
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
        return
    fi
    if [ -d "$SCRIPT_DIR/.git" ]; then
        info "Updating olecharms repo..."
        local before_script before_conf stash_before stash_after
        before_script=$(_file_hash "$SCRIPT_PATH")
        before_conf=$(_file_hash "$CONF_FILE")

        # packages.conf is tracked: local edits collide with the pull below
        if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain -- "$(basename "$CONF_FILE")" 2>/dev/null)" ]; then
            warn "packages.conf has local changes. Move them to $LOCAL_CONF_FILE, which updates never touch."
        fi
        stash_before=$(git -C "$SCRIPT_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')

        git -C "$SCRIPT_DIR" pull --rebase --autostash 2>/dev/null || {
            warn "Could not update olecharms repo"
        }

        # --autostash parks local changes in the stash when re-applying them
        # conflicts — silently, unless we say so.
        stash_after=$(git -C "$SCRIPT_DIR" stash list 2>/dev/null | wc -l | tr -d ' ')
        if [ "$stash_after" -gt "$stash_before" ]; then
            warn "Your local changes clashed with the update and were set aside in git stash."
            warn "Inspect them with: git -C \"$SCRIPT_DIR\" stash show -p"
        fi

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
    for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$SHELL_LOADER" "$ALIAS_FILE"; do
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
run_setup_steps() {
    ensure_local_conf_template
    install_packages
    create_vim_dirs
    install_pathogen
    install_plugins
    install_vimrc
    install_fonts
    install_omz
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
}

# ─── Doctor ─────────────────────────────────────────────────────────────────

DOC_OK=0
DOC_WARN=0
DOC_FAIL=0
doc_ok()      { echo -e "  ${GREEN}✓${NC} $*"; DOC_OK=$((DOC_OK + 1)); }
doc_warn()    { echo -e "  ${YELLOW}~${NC} $*"; DOC_WARN=$((DOC_WARN + 1)); }
doc_fail()    { echo -e "  ${RED}✗${NC} $*"; DOC_FAIL=$((DOC_FAIL + 1)); }
doc_hint()    { echo -e "      ${BLUE}→${NC} $*"; }
doc_section() { echo ""; echo -e "${BLUE}$*:${NC}"; }

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
        doc_warn "Shell loader was generated by an older olecharms"
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
    doc_ok "$(alias_count) aliases defined ($ALIAS_FILE)"
    if check_command autojump; then
        if d=$(autojump_script_dir); then
            doc_ok "autojump activated by the shell loader ($d)"
        else
            doc_warn "autojump is installed but no autojump.zsh/autojump.bash was found to activate it"
        fi
    fi
    sh=$(login_shell)
    case "$sh" in
        *zsh) doc_ok "Login shell is $sh" ;;
        *)
            doc_warn "Login shell is ${sh:-unknown}, not zsh"
            doc_hint "chsh -s \"$(command -v zsh 2>/dev/null || echo /bin/zsh)\""
            ;;
    esac
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
        doc_warn "$VIMRC also holds an old full copy of olevimrc.vim, so the config loads twice"
        doc_hint "Keep only the two olecharms lines unless you rely on that copy (it enables mswin.vim everywhere)"
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
        doc_warn "$(basename "$script") was generated by an older olecharms"
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
        doc_fail "Folder ${dir:-<unset>} is missing or unsafe (resolves to \$HOME or /)"
        return
    fi
    doc_ok "Folder $dir$([ "$real" != "$dir" ] && echo " → $real")"
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
        if grep -q '"face"[^,}]*Powerline' "$wt"; then
            doc_ok "Windows Terminal uses a Powerline font"
        else
            doc_warn "Windows Terminal does not use a Powerline font (vim-airline symbols may not render)"
            doc_hint "Windows Terminal → Settings → Profiles → Defaults → Appearance → Font face: DejaVu Sans Mono for Powerline"
        fi
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

doctor_run_checks() {
    DOC_OK=0
    DOC_WARN=0
    DOC_FAIL=0
    doctor_check_commands
    doctor_check_launcher
    doctor_check_shell
    doctor_check_vim
    doctor_check_zsh
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
cmd_doctor() {
    local fix="" arg
    for arg in "$@"; do
        case "$arg" in
            --fix) fix=1 ;;
            -h|--help) echo "Usage: olecharms doctor [--fix]"; return 0 ;;
            *) error "Unknown doctor option: $arg"; return 1 ;;
        esac
    done
    load_config || return 1

    if [ -n "$fix" ]; then
        echo -e "${BOLD}olecharms doctor --fix${NC}"
        echo ""
        create_vim_dirs
        install_vimrc
        install_shell_commands
        install_binary
        install_editor_env
        restore_scheduled_features
        sync_windows_side
        config_set install_dir "$SCRIPT_DIR"
        echo ""
    fi

    echo -e "${BOLD}olecharms doctor${NC}"
    doctor_run_checks
    if [ "$DOC_FAIL" -gt 0 ]; then
        [ -z "$fix" ] && echo "Run 'olecharms doctor --fix' for local repairs, or 'olecharms update' for packages and plugins."
        return 1
    fi
    return 0
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
        echo "  No trash is available for this folder: old files will be deleted permanently." >&2
        echo delete
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
    echo "    1) auto    — Windows Recycle Bin / macOS Trash when there is one, else delete"
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

config_cleanup_age() {
    local days
    read -rp "  Delete files older than how many days? [$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")] " days
    [ -z "$days" ] && { info "No changes made"; return 0; }
    if ! [[ "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ] || [ "$days" -gt 3650 ]; then
        error "Enter a number of days between 1 and 3650"
        return 1
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
        error "Refusing $selected: it resolves to \$HOME or /"
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
        echo "  Paranoid mode clears every 12 hours:"
        echo "    - Bash history (~/.bash_history)"
        echo "    - Zsh history (~/.zsh_history)"
        echo "    - Vim swap files ($VIM_DIR/swapfiles/)"
        echo "    - Vim undo files ($VIM_DIR/undodir/)"
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
    else
        echo -e "  Status: ${RED}disabled${NC}"
        echo ""
        echo "  Every 12 hours, paranoid mode will delete:"
        echo "    - Bash history (~/.bash_history)"
        echo "    - Zsh history (~/.zsh_history)"
        echo "    - Vim swap files ($VIM_DIR/swapfiles/)"
        echo "    - Vim undo files ($VIM_DIR/undodir/)"
        echo ""

        if ! is_downloads_cleanup_enabled; then
            echo -e "  ${YELLOW}Note:${NC} Downloads auto-cleanup is not enabled."
            echo "  Paranoid mode will also enable it (with $(( DOWNLOADS_MAX_AGE_DAYS / 2 ))-day max age)."
            echo ""
        fi

        echo "  Select scheduling method:"
        echo ""
        echo "    1) Shell hook — checked on shell open (recommended)"
        echo "    2) Cron job — every 12 hours"
        echo ""
        echo "    0) Cancel"
        echo ""

        local method_choice
        read -rp "  Select: " method_choice

        local mode
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
                return
                ;;
            *)
                error "Invalid selection"
                return 1
                ;;
        esac

        # Also enable downloads cleanup if not already on
        if ! is_downloads_cleanup_enabled; then
            echo ""
            local selected rc
            selected=$(choose_downloads_dir)
            rc=$?
            if [ "$rc" -ne 0 ]; then
                [ "$rc" -eq 1 ] && info "Cancelled"
                return $((rc - 1))
            fi
            enable_downloads_cleanup "$selected" "$mode" "$((DOWNLOADS_MAX_AGE_DAYS / 2))" || return 1
            info "Downloads auto-cleanup enabled for $selected ($(( DOWNLOADS_MAX_AGE_DAYS / 2 ))-day max age, $(config_get downloads_cleanup_action auto))"
        fi

        enable_paranoid_mode "$mode"
        info "Paranoid mode enabled"
        if [ "$mode" = "cron" ]; then
            info "Cron job installed (every 12 hours)."
        else
            info "Changes take effect in your next shell session."
        fi
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
    echo "Usage: olecharms cleanup [--dry-run | --log] [--yes]"
    echo ""
    echo "  (no option)    show what would go, ask, then clean the downloads folder now"
    echo "  -n, --dry-run  list the files the next run would remove; change nothing"
    echo "      --log      show the history of past cleanups"
    echo "  -y, --yes      do not ask for confirmation"
}

# olecharms cleanup — the same engine the scheduled runs use, on demand.
cmd_cleanup() {
    local mode=run assume_yes="" arg
    for arg in "$@"; do
        case "$arg" in
            -n|--dry-run) mode=dry ;;
            -y|--yes)     assume_yes=1 ;;
            --log)        mode=log ;;
            --scheduled)  mode=scheduled ;;
            -h|--help)    cleanup_usage; return 0 ;;
            *)            error "Unknown cleanup option: $arg"; cleanup_usage; return 1 ;;
        esac
    done
    if [ "$mode" = "log" ]; then
        cleanup_show_log
        return 0
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
        error "Cannot clean $dir (missing, or it resolves to \$HOME or /)"
        return 1
    fi
    if ! backend=$(cleanup_effective_backend "$real" "$action"); then
        error "Action is 'trash' but $real has no trash; change it in 'olecharms config'"
        return 1
    fi

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
    if [ -z "$assume_yes" ]; then
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
    local name="$1"; shift
    local cmd="$*"

    if [ -z "$name" ] || [ -z "$cmd" ]; then
        error "Usage: olecharms alias add <name> <command...>"
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

    local existing
    existing=$(alias_get "$name")

    echo ""
    if [ -n "$existing" ]; then
        echo -e "  ${BOLD}Replace${NC} alias ${BOLD}${name}${NC}"
        echo "    old: $existing"
        echo "    new: $cmd"
    else
        echo -e "  ${BOLD}Add${NC} alias ${BOLD}${name}${NC}"
        echo "    $cmd"
        # Set by the shell wrapper: sees oh-my-zsh aliases and functions
        if [ -n "${OLECHARMS_NAME_TYPE:-}" ]; then
            warn "  Note: ${OLECHARMS_NAME_TYPE} — your alias will take precedence."
        elif check_command "$name"; then
            warn "  Note: '$name' is also a command at $(command -v "$name") — the alias will shadow it."
        fi
    fi
    echo ""

    if ! confirm_default_yes "  Add this alias?"; then
        info "Cancelled"
        return 0
    fi

    alias_set "$name" "$cmd" || return 1
    info "Alias '$name' saved to $ALIAS_FILE"
    alias_activation_note
}

alias_delete() {
    local name="$1"

    if [ -z "$name" ]; then
        error "Usage: olecharms alias delete <name>"
        return 1
    fi

    local existing
    existing=$(alias_get "$name")
    if [ -z "$existing" ]; then
        error "No such alias: $name"
        return 1
    fi

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
    alias_activation_note
}

alias_show_list() {
    local count
    count=$(alias_count)
    if [ "$count" -eq 0 ]; then
        echo "  (no aliases defined — add one with: olecharms alias add <name> <command...>)"
        return 0
    fi

    # Pad the name column to the widest name
    local width=0 name cmd
    while IFS=$'\t' read -r name cmd; do
        [ ${#name} -gt "$width" ] && width=${#name}
    done < <(alias_list_raw)

    while IFS=$'\t' read -r name cmd; do
        printf "  ${GREEN}%-${width}s${NC}  %s\n" "$name" "$cmd"
    done < <(alias_list_raw)
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
            echo "  Stored in $ALIAS_FILE"
            ;;
        *)
            error "Unknown alias subcommand: $sub"
            echo ""
            echo "  olecharms alias add <name> <command...>   Create or replace an alias"
            echo "  olecharms alias list                      Show all aliases"
            echo "  olecharms alias delete <name>             Remove an alias"
            return 1
            ;;
    esac
}

cmd_help() {
    echo -e "${BOLD}olecharms${NC} — Environment management for olecharms"
    echo ""
    echo -e "Usage: ${BOLD}olecharms${NC} <command>"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  install   Full idempotent setup: self-update, packages, vim, plugins, fonts, omz"
    echo "  update    Same as install (alias for convenience)"
    echo "  doctor    Check the whole setup, exit 1 on problems; --fix repairs what it can"
    echo "            offline (alias: check)"
    echo "  status    Show what's installed with version info"
    echo "  config    Interactive menu: downloads cleanup, paranoid mode, Windows sync (WSL)"
    echo "  cleanup   Clean the downloads folder now; --dry-run lists what would go,"
    echo "            --log shows past runs"
    echo "  alias     Manage shell aliases (add / list / delete)"
    [ -n "${IS_WSL:-}" ] && echo "  windows   Sync Windows' gVim (config, plugins) and fonts now; 'status' to check"
    echo "  help      Show this help message"
    echo ""
    echo -e "${BLUE}Aliases:${NC}"
    echo "  olecharms alias add <name> <command...>   Create or replace an alias"
    echo "  olecharms alias list                      Show all aliases"
    echo "  olecharms alias delete <name>             Remove an alias"

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
        install|update|config)
            config_ensure
            fix_moved_install fix
            ;;
        alias|cleanup|windows)
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
        doctor|check) shift; cmd_doctor "$@" || cmd_rc=$? ;;
        status)  cmd_status || cmd_rc=$? ;;
        config)  cmd_config || cmd_rc=$? ;;
        cleanup) shift; cmd_cleanup "$@" || cmd_rc=$? ;;
        windows) shift; cmd_windows "$@" || cmd_rc=$? ;;
        alias)   shift; cmd_alias "$@" || cmd_rc=$? ;;
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
