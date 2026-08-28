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
CURRENT_CONFIG_VERSION=2

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
    # shellcheck source=packages.conf
    source "$CONF_FILE"
}

detect_os() {
    case "$(uname -s)" in
        Linux*)
            OS="linux"
            PKG_MANAGER="apt-get"
            FONT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
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
    local file="$1"
    if [ -e "$file" ]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp -r "$file" "$backup"
        info "Backed up $file → $backup"
    fi
}

clone_or_pull() {
    local url="$1"
    local dest="$2"
    local name="$3"
    local fallback="$4"  # optional bundled fallback path

    if [ -d "$dest/.git" ]; then
        info "Updating $name..."
        if git -C "$dest" pull --ff-only 2>/dev/null; then
            return 0
        fi
        warn "git pull failed for $name, trying reset"
        if git -C "$dest" fetch origin 2>/dev/null; then
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
        if git clone --depth 1 "$url" "$tmp_clone" 2>/dev/null; then
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
    if git clone --depth 1 "$url" "$dest" 2>/dev/null; then
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

# True if any managed RC file contains $1.
rc_has_marker() {
    local marker="$1" rc
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        [ -f "$rc" ] && grep -qF "$marker" "$rc" 2>/dev/null && return 0
    done
    return 1
}

# Quote a path for a crontab command line: cron hands the line to /bin/sh, and
# an unescaped % is turned into a newline.
cron_quote_path() {
    local path="$1"
    path=${path//\'/\'\\\'\'}
    path=${path//%/\\%}
    printf "'%s'" "$path"
}

# Replace (or, with an empty $2, remove) the crontab entry tagged with marker $1.
cron_replace_entry() {
    local marker="$1" entry="${2:-}"
    local existing new_content
    if ! check_command crontab; then
        error "crontab is not available"
        return 1
    fi
    existing=$(crontab -l 2>/dev/null | grep -vF "$marker")
    if [ -n "$entry" ]; then
        if [ -n "$existing" ]; then
            new_content=$(printf '%s\n%s' "$existing" "$entry")
        else
            new_content="$entry"
        fi
    else
        new_content="$existing"
    fi
    if [ -z "$new_content" ]; then
        crontab -r 2>/dev/null || true
        return 0
    fi
    printf '%s\n' "$new_content" | crontab -
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

find_downloads_dirs() {
    local results
    results=$(find -L "$HOME" -maxdepth 1 -iname "downloads" -type d 2>/dev/null)
    if [ -z "$results" ]; then
        return 1
    fi
    echo "$results"
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

generate_hook_script() {
    ensure_scripts_dir || return 1

    cat > "$HOOK_SCRIPT" <<'HOOK_EOF'
#!/bin/bash
# olecharms-hook.sh — sourced from shell profile for scheduled cleanups

_olecharms_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_olecharms_check_and_run() {
    local script="$1" name="$2" interval="$3"
    [ ! -x "$script" ] && return
    local lastrun_dir="$_olecharms_hook_dir/.last-run"
    local lastrun_file="$lastrun_dir/$name"
    local now last=0
    now=$(date +%s)
    [ -f "$lastrun_file" ] && last=$(cat "$lastrun_file" 2>/dev/null)
    if [ $((now - last)) -ge "$interval" ]; then
        mkdir -p "$lastrun_dir"
        echo "$now" > "$lastrun_file"
        "$script" &
    fi
}
HOOK_EOF

    # Only include features that are hook-scheduled (not cron)
    # Dynamic lines — interval values are numeric constants, fine to bake in
    if is_downloads_cleanup_enabled && ! is_downloads_cron_enabled; then
        echo "_olecharms_check_and_run \"\$_olecharms_hook_dir/cleanup-downloads.sh\" \"downloads-cleanup\" $DOWNLOADS_INTERVAL" >> "$HOOK_SCRIPT"
    fi
    if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
        echo "_olecharms_check_and_run \"\$_olecharms_hook_dir/paranoid-cleanup.sh\" \"paranoid-cleanup\" $PARANOID_INTERVAL" >> "$HOOK_SCRIPT"
    fi

    {
        echo ""
        echo "unset -f _olecharms_check_and_run"
        echo "unset _olecharms_hook_dir"
    } >> "$HOOK_SCRIPT"
    chmod +x "$HOOK_SCRIPT"
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

    cat > "$SHELL_LOADER" <<'LOADER_EOF'
#!/bin/bash
# olecharms-shell.sh — sources shell command files
_olecharms_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_olecharms_shell_dir="${_olecharms_dir%/*}/shell"
for _olecharms_f in "$_olecharms_shell_dir"/*.sh; do
    [ -f "$_olecharms_f" ] && source "$_olecharms_f"
done
unset _olecharms_f _olecharms_dir _olecharms_shell_dir
LOADER_EOF
    chmod +x "$SHELL_LOADER"
}

install_shell_commands() {
    # Check if shell dir exists and has files
    local shell_files=("$SHELL_DIR"/*.sh)
    if [ ! -d "$SHELL_DIR" ] || [ ! -e "${shell_files[0]}" ]; then
        return
    fi

    # Cheap and idempotent, and the loader lives in the gitignored scripts/ dir,
    # so regenerate unconditionally rather than only when an RC file changes.
    generate_shell_loader || return 1

    local rc_files=() rc
    while IFS= read -r rc; do rc_files+=("$rc"); done < <(managed_rc_files)

    for rc in "${rc_files[@]}"; do
        if grep -qF "$SHELL_MARKER" "$rc" 2>/dev/null; then
            if grep -qF "source \"$SHELL_LOADER\"" "$rc" 2>/dev/null; then
                continue
            fi
            rc_strip_block "$rc" "$SHELL_MARKER" "olecharms-shell.sh" || return 1
        fi
        append_block "$rc" \
            "$SHELL_MARKER" \
            "[ -f \"$SHELL_LOADER\" ] && source \"$SHELL_LOADER\""
        info "Shell commands installed in $rc"
    done
}

remove_shell_commands() {
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

    cat > "$CLEANUP_SCRIPT" <<CLEANUP_EOF
#!/bin/bash
# Generated by olecharms — edit via 'olecharms config', not by hand.
DOWNLOADS_DIR=$(printf '%q' "$downloads_dir")
MAX_AGE_DAYS=$max_age

# Never let a bad config point this at a whole home directory or the root.
case "\$DOWNLOADS_DIR" in
    ""|"/"|"$HOME"|"$HOME/") exit 1 ;;
esac
[ -d "\$DOWNLOADS_DIR" ] || exit 1
find "\$DOWNLOADS_DIR" -type f -mtime "+\$MAX_AGE_DAYS" -delete 2>/dev/null
find "\$DOWNLOADS_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
CLEANUP_EOF
    chmod +x "$CLEANUP_SCRIPT"

    if [ "$mode" = "cron" ]; then
        local new_entry="$DOWNLOADS_CRON_MIN $DOWNLOADS_CRON_HOUR * * * $(cron_quote_path "$CLEANUP_SCRIPT") $CRON_MARKER_DOWNLOADS"
        cron_replace_entry "$CRON_MARKER_DOWNLOADS" "$new_entry" || return 1
        # Regenerate hook script to exclude downloads if paranoid uses it
        if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
            generate_hook_script
        fi
    else
        check_command crontab && cron_replace_entry "$CRON_MARKER_DOWNLOADS" ""
        generate_hook_script
        install_shell_hook
    fi

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

    if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
        generate_hook_script
    else
        remove_shell_hook
    fi
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

    cat > "$PARANOID_SCRIPT" <<PARANOID_EOF
#!/bin/bash
# Generated by olecharms — edit via 'olecharms config', not by hand.
# Purge shell history
rm -f "$HOME/.bash_history" 2>/dev/null
rm -f "$HOME/.zsh_history" 2>/dev/null

# Purge vim swap files
find "$VIM_DIR/swapfiles" -type f -delete 2>/dev/null

# Purge vim undo files
find "$VIM_DIR/undodir" -type f -delete 2>/dev/null
PARANOID_EOF
    chmod +x "$PARANOID_SCRIPT"

    if [ "$mode" = "cron" ]; then
        local new_entry="$PARANOID_CRON_SCHEDULE $(cron_quote_path "$PARANOID_SCRIPT") $CRON_MARKER_PARANOID"
        cron_replace_entry "$CRON_MARKER_PARANOID" "$new_entry" || return 1
        # Regenerate hook script to exclude paranoid if downloads uses it
        if is_downloads_cleanup_enabled && ! is_downloads_cron_enabled; then
            generate_hook_script
        fi
    else
        check_command crontab && cron_replace_entry "$CRON_MARKER_PARANOID" ""
        generate_hook_script
        install_shell_hook
    fi

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

    if is_downloads_cleanup_enabled && ! is_downloads_cron_enabled; then
        # Downloads still needs the hook, regenerate without paranoid
        generate_hook_script
    else
        remove_shell_hook
    fi
    info "Paranoid mode disabled"

    # Sync to config file
    config_set paranoid_mode_enabled false
    config_set paranoid_mode_method hook
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
    local key="$1" value="$2"
    mkdir -p "$OLECHARMS_CONFIG_DIR"

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

paranoid_mode_enabled=$(config_get paranoid_mode_enabled false)
paranoid_mode_method=$(config_get paranoid_mode_method hook)

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

config_ensure() {
    if [ ! -f "$OLECHARMS_CONFIG_FILE" ]; then
        config_bootstrap
    else
        config_read
        migrate_config
    fi
}

# scripts/ is gitignored, so a fresh clone (or a moved install) has no generated
# cleanup scripts even when the config says the feature is on. Bring the
# filesystem and crontab back in line with the config.
restore_scheduled_features() {
    local force="${1:-}"
    local dl_enabled dl_dir dl_method dl_age p_enabled p_method needs

    dl_enabled=$(config_get downloads_cleanup_enabled false)
    if [ "$dl_enabled" = "true" ]; then
        dl_dir=$(config_get downloads_cleanup_dir)
        dl_method=$(config_get downloads_cleanup_method hook)
        dl_age=$(config_get downloads_cleanup_max_age_days "$DOWNLOADS_MAX_AGE_DAYS")
        if [ -z "$dl_dir" ] || [ ! -d "$dl_dir" ]; then
            warn "Downloads auto-cleanup is enabled but ${dl_dir:-<unset>} is missing; disabling"
            config_set downloads_cleanup_enabled false
        else
            needs="$force"
            [ -x "$CLEANUP_SCRIPT" ] || needs=force
            [ "$dl_method" = "cron" ] && ! is_downloads_cron_enabled && needs=force
            if [ -n "$needs" ]; then
                info "Restoring downloads auto-cleanup ($dl_method)"
                enable_downloads_cleanup "$dl_dir" "$dl_method" "$dl_age"
            fi
        fi
    fi

    p_enabled=$(config_get paranoid_mode_enabled false)
    if [ "$p_enabled" = "true" ]; then
        p_method=$(config_get paranoid_mode_method hook)
        needs="$force"
        [ -x "$PARANOID_SCRIPT" ] || needs=force
        [ "$p_method" = "cron" ] && ! is_paranoid_cron_enabled && needs=force
        if [ -n "$needs" ]; then
            info "Restoring paranoid mode ($p_method)"
            enable_paranoid_mode "$p_method"
        fi
    fi
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
    if [ -f "$HOOK_SCRIPT" ] || rc_has_marker "$HOOK_MARKER"; then
        generate_hook_script
        install_shell_hook
    fi
    install_binary
    # Cron entries and generated scripts hold absolute paths — rewrite them
    restore_scheduled_features force

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
        "${sudo_cmd[@]}" apt-get update -qq \
            && "${sudo_cmd[@]}" apt-get install -y -qq "${missing[@]}" || {
            error "Some packages failed to install"
        }
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

        backup_file "$VIMRC"

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
        # Set ZSH_THEME to olecharms
        if grep -q '^ZSH_THEME=' "$zshrc"; then
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
        local before_script before_conf
        before_script=$(_file_hash "$SCRIPT_PATH")
        before_conf=$(_file_hash "$CONF_FILE")

        git -C "$SCRIPT_DIR" pull --rebase --autostash 2>/dev/null || {
            warn "Could not update olecharms repo"
        }

        local after_script after_conf
        after_script=$(_file_hash "$SCRIPT_PATH")
        after_conf=$(_file_hash "$CONF_FILE")

        if [ "$before_script" != "$after_script" ] || [ "$before_conf" != "$after_conf" ]; then
            if ! bash -n "$SCRIPT_PATH" 2>/dev/null; then
                error "Updated $SCRIPT_PATH has syntax errors — not relaunching"
                return 1
            fi
            info "olecharms.sh or packages.conf was updated. Relaunching..."
            OLECHARMS_RELAUNCHED=1 exec "$SCRIPT_PATH" "$@"
        fi
    fi
}

cmd_install() {
    echo -e "${BOLD}olecharms install${NC}"
    echo ""

    load_config || return 1
    detect_os

    # Self-update: pull the olecharms repo
    _self_update install

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

    echo ""
    if [ $ERROR_COUNT -eq 0 ]; then
        info "Install complete! No errors."
    else
        warn "Install complete with $ERROR_COUNT error(s). Review output above."
    fi

    # Launch a zsh session so the user sees the result — only when we actually
    # have a terminal, otherwise this hangs scripted/CI runs and hides the
    # exit status.
    if [ $ERROR_COUNT -eq 0 ] && [ -t 0 ] && [ -t 1 ] && check_command zsh; then
        info "Launching zsh..."
        exec zsh -l
    fi
    return 0
}

cmd_update() {
    echo -e "${BOLD}olecharms update${NC}"
    echo ""

    load_config || return 1
    detect_os

    # Self-update: pull the olecharms repo
    _self_update update

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

    echo ""
    if [ $ERROR_COUNT -eq 0 ]; then
        info "Update complete! No errors."
    else
        warn "Update complete with $ERROR_COUNT error(s). Review output above."
    fi
}

cmd_check() {
    echo -e "${BOLD}olecharms check${NC}"
    echo ""

    load_config || return 1
    detect_os

    # Check git
    echo -e "${BLUE}System commands:${NC}"
    for cmd in git vim curl fc-cache ag autojump; do
        if check_command "$cmd"; then
            echo -e "  ${GREEN}✓${NC} $cmd  ($(command -v "$cmd"))"
        else
            echo -e "  ${RED}✗${NC} $cmd  (not found)"
        fi
    done

    # Check vim directories
    echo ""
    echo -e "${BLUE}Vim directories:${NC}"
    for d in autoload bundle bundle_disabled undodir swapfiles; do
        if [ -d "$VIM_DIR/$d" ]; then
            echo -e "  ${GREEN}✓${NC} $VIM_DIR/$d"
        else
            echo -e "  ${RED}✗${NC} $VIM_DIR/$d  (missing)"
        fi
    done

    # Check for leftovers from the old re-copy loop
    local replaced_count
    replaced_count=$(find "$VIM_DIR/bundle_disabled" -maxdepth 1 -name '*.replaced.*' 2>/dev/null | wc -l)
    if [ "$replaced_count" -gt 2 ]; then
        echo ""
        warn "$VIM_DIR/bundle_disabled holds $replaced_count '*.replaced.*' dirs ($(du -sh "$VIM_DIR/bundle_disabled" 2>/dev/null | cut -f1)). Safe to delete."
    fi

    # Check pathogen
    echo ""
    echo -e "${BLUE}Pathogen:${NC}"
    if [ -f "$VIM_DIR/autoload/pathogen.vim" ]; then
        echo -e "  ${GREEN}✓${NC} pathogen.vim installed"
    else
        echo -e "  ${RED}✗${NC} pathogen.vim not found"
    fi

    # Check plugins
    echo ""
    echo -e "${BLUE}Vim plugins:${NC}"
    for entry in "${VIM_PLUGINS[@]}"; do
        local name="${entry%%|*}"
        local dest="$VIM_DIR/bundle/$name"
        if [ -d "$dest/.git" ]; then
            echo -e "  ${GREEN}✓${NC} $name  (git repo)"
        elif [ -d "$dest" ]; then
            echo -e "  ${YELLOW}~${NC} $name  (present but not a git repo)"
        else
            echo -e "  ${RED}✗${NC} $name  (not installed)"
        fi
    done

    # Check vimrc
    echo ""
    echo -e "${BLUE}Vimrc:${NC}"
    if [ -f "$VIMRC" ] && grep -qF "$SOURCE_LINE" "$VIMRC"; then
        echo -e "  ${GREEN}✓${NC} source line present in $VIMRC"
    else
        echo -e "  ${RED}✗${NC} source line not found in $VIMRC"
    fi

    # Check fonts
    echo ""
    echo -e "${BLUE}Fonts:${NC}"
    for family in "${FONT_FAMILIES[@]}"; do
        local count
        count=$(ls "$FONT_DIR"/*"$family"* 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} $family  ($count files in $FONT_DIR)"
        else
            echo -e "  ${RED}✗${NC} $family  (not found in $FONT_DIR)"
        fi
    done

    # Check shell commands
    echo ""
    echo -e "${BLUE}Shell commands:${NC}"
    if [ -d "$SHELL_DIR" ] && ls "$SHELL_DIR"/*.sh >/dev/null 2>&1; then
        for f in "$SHELL_DIR"/*.sh; do
            local cmd_name
            cmd_name=$(basename "$f" .sh)
            echo -e "  ${GREEN}✓${NC} $cmd_name  ($f)"
        done
    else
        echo -e "  ${YELLOW}~${NC} No shell commands found in $SHELL_DIR"
    fi
    echo -e "${BLUE}Shell loader:${NC}"
    if [ -f "$SHELL_LOADER" ]; then
        echo -e "  ${GREEN}✓${NC} $SHELL_LOADER"
    else
        echo -e "  ${RED}✗${NC} $SHELL_LOADER  (not generated — run install or update)"
    fi

    # Check EDITOR env
    echo ""
    echo -e "${BLUE}EDITOR environment:${NC}"
    local editor_found=false
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        if [ -f "$rc" ] && grep -qF "$EDITOR_MARKER" "$rc" 2>/dev/null; then
            editor_found=true
            break
        fi
    done
    if $editor_found; then
        echo -e "  ${GREEN}✓${NC} EDITOR=vim exported"
    else
        echo -e "  ${RED}✗${NC} EDITOR=vim not found in RC files"
    fi
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
}

config_downloads_cleanup() {
    if is_downloads_cleanup_enabled; then
        local method_info="shell hook"
        if is_downloads_cron_enabled; then
            method_info="cron, daily at ${DOWNLOADS_CRON_HOUR}:$(printf '%02d' $DOWNLOADS_CRON_MIN)"
        fi
        echo -e "  Status: ${GREEN}enabled${NC} ($method_info)"
        echo ""
        read -rp "  Disable auto-cleanup? [y/N] " answer
        case "$answer" in
            [yY])
                disable_downloads_cleanup
                ;;
            *)
                info "No changes made"
                ;;
        esac
    else
        echo -e "  Status: ${RED}disabled${NC}"
        echo ""

        local dirs
        if ! dirs=$(find_downloads_dirs) || [ -z "$dirs" ]; then
            error "No downloads folder found in $HOME"
            echo "  Create one with: mkdir ~/Downloads"
            return 1
        fi

        local dir_array=()
        while IFS= read -r d; do
            dir_array+=("$d")
        done <<< "$dirs"

        echo "  Found download folders:"
        echo ""
        local i
        for i in "${!dir_array[@]}"; do
            echo "    $((i + 1))) ${dir_array[$i]}"
        done
        echo ""
        echo "    0) Cancel"
        echo ""

        local choice
        read -rp "  Select folder: " choice

        if [ "$choice" = "0" ] || [ -z "$choice" ]; then
            info "Cancelled"
            return
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#dir_array[@]} ]; then
            error "Invalid selection"
            return 1
        fi

        local selected="${dir_array[$((choice - 1))]}"
        echo ""
        echo "  Files older than ${DOWNLOADS_MAX_AGE_DAYS} days will be deleted from:"
        echo "    $selected"
        echo ""
        echo "  Select scheduling method:"
        echo ""
        echo "    1) Shell hook — checked on shell open (recommended)"
        echo "    2) Cron job — daily at ${DOWNLOADS_CRON_HOUR}:$(printf '%02d' $DOWNLOADS_CRON_MIN)"
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

        enable_downloads_cleanup "$selected" "$mode"
        info "Downloads auto-cleanup enabled for $selected"
        if [ "$mode" = "cron" ]; then
            info "Cron job installed (daily at ${DOWNLOADS_CRON_HOUR}:$(printf '%02d' $DOWNLOADS_CRON_MIN))."
        else
            info "Changes take effect in your next shell session."
        fi
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
            local dirs
            if ! dirs=$(find_downloads_dirs) || [ -z "$dirs" ]; then
                error "No downloads folder found in $HOME"
                echo "  Create one with: mkdir ~/Downloads"
                return 1
            fi

            local dir_array=()
            while IFS= read -r d; do
                dir_array+=("$d")
            done <<< "$dirs"

            echo "  Select downloads folder for auto-cleanup:"
            echo ""
            local i
            for i in "${!dir_array[@]}"; do
                echo "    $((i + 1))) ${dir_array[$i]}"
            done
            echo ""
            echo "    0) Cancel"
            echo ""

            local dl_choice
            read -rp "  Select folder: " dl_choice

            if [ "$dl_choice" = "0" ] || [ -z "$dl_choice" ]; then
                info "Cancelled"
                return
            fi

            if ! [[ "$dl_choice" =~ ^[0-9]+$ ]] || [ "$dl_choice" -lt 1 ] || [ "$dl_choice" -gt ${#dir_array[@]} ]; then
                error "Invalid selection"
                return 1
            fi

            local selected="${dir_array[$((dl_choice - 1))]}"
            enable_downloads_cleanup "$selected" "$mode" "$((DOWNLOADS_MAX_AGE_DAYS / 2))"
            info "Downloads auto-cleanup enabled for $selected ($(( DOWNLOADS_MAX_AGE_DAYS / 2 ))-day max age)"
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

cmd_help() {
    echo -e "${BOLD}olecharms${NC} — Environment management for olecharms"
    echo ""
    echo -e "Usage: ${BOLD}olecharms${NC} <command>"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  install   Full idempotent setup: self-update, packages, vim, plugins, fonts, omz"
    echo "  update    Same as install (alias for convenience)"
    echo "  check     Report installed/missing dependencies and plugin status"
    echo "  status    Show what's installed with version info"
    echo "  config    Interactive menu to toggle system features (e.g. downloads cleanup)"
    echo "  help      Show this help message"

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
    echo "  Edit packages.conf to add/remove system packages, vim plugins, font families,"
    echo "  and post-install commands."
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  olecharms install    # First-time setup"
    echo "  olecharms update     # Update everything"
    echo "  olecharms check      # See what's installed/missing"
    echo "  olecharms config     # Toggle system features"
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

    # For operational commands, ensure config is loaded and check for moved install
    case "${1:-}" in
        install|update|config)
            config_ensure
            fix_moved_install fix
            ;;
        check|status)
            config_ensure
            fix_moved_install warn
            ;;
    esac

    case "${1:-}" in
        install) cmd_install ;;
        update)  cmd_update ;;
        check)   cmd_check ;;
        status)  cmd_status ;;
        config)  cmd_config ;;
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

    # Surface failures to callers (CI, cron, `&&` chains) instead of always 0
    [ "$ERROR_COUNT" -gt 0 ] && return 1
    return 0
}

main "$@"
exit $?
