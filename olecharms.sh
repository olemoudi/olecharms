#!/bin/bash
# olecharms.sh — Environment management script for olecharms
# Usage: ./olecharms.sh {install|update|check|status|config|help}

# ─── Constants & Globals ─────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/packages.conf"
VIM_DIR="$HOME/.vim"
VIMRC="$HOME/.vimrc"
BUNDLED_DIR="$SCRIPT_DIR/vimthings"
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

# Source line we manage in ~/.vimrc
SOURCE_MARKER="\" olecharms managed config - do not remove this line"
SOURCE_LINE="source $SCRIPT_DIR/vimthings/olevimrc.vim"

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
            FONT_DIR="$HOME/.local/share/fonts"
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
        else
            warn "git pull failed for $name, trying reset"
            git -C "$dest" fetch origin 2>/dev/null
            local branch
            branch=$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null || echo "master")
            git -C "$dest" reset --hard "origin/$branch" 2>/dev/null && return 0
            warn "Could not update $name (may be offline)"
            return 1
        fi
    fi

    # If directory exists but is not a git repo, back it up
    if [ -d "$dest" ] && [ ! -d "$dest/.git" ]; then
        warn "$name exists but is not a git repo. Backing up and re-cloning."
        backup_file "$dest"
        rm -rf "$dest"
    fi

    info "Cloning $name..."
    if git clone --depth 1 "$url" "$dest" 2>/dev/null; then
        return 0
    fi

    # Fallback to bundled copy
    if [ -n "$fallback" ] && [ -d "$fallback" ]; then
        warn "Clone failed for $name. Using bundled copy from $fallback"
        cp -r "$fallback" "$dest"
        return 0
    fi

    error "Failed to clone $name and no bundled fallback available"
    return 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

find_downloads_dirs() {
    local results
    results=$(find "$HOME" -maxdepth 1 -iname "downloads" -type d 2>/dev/null)
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

any_feature_enabled() {
    is_downloads_cleanup_enabled || is_paranoid_mode_enabled
}

generate_hook_script() {
    mkdir -p "$SCRIPTS_DIR"

    cat > "$HOOK_SCRIPT" <<HOOK_EOF
#!/bin/bash
# olecharms-hook.sh — sourced from shell profile for scheduled cleanups

_olecharms_check_and_run() {
    local script="\$1" name="\$2" interval="\$3"
    [ ! -x "\$script" ] && return
    local lastrun_file="$LASTRUN_DIR/\$name"
    local now last=0
    now=\$(date +%s)
    [ -f "\$lastrun_file" ] && last=\$(cat "\$lastrun_file" 2>/dev/null)
    if [ \$((now - last)) -ge "\$interval" ]; then
        mkdir -p "$LASTRUN_DIR"
        echo "\$now" > "\$lastrun_file"
        "\$script" &
    fi
}

_olecharms_check_and_run "$CLEANUP_SCRIPT" "downloads-cleanup" $DOWNLOADS_INTERVAL
_olecharms_check_and_run "$PARANOID_SCRIPT" "paranoid-cleanup" $PARANOID_INTERVAL

unset -f _olecharms_check_and_run
HOOK_EOF
    chmod +x "$HOOK_SCRIPT"
}

install_shell_hook() {
    local rc_files=()
    [ -f "$HOME/.bashrc" ] && rc_files+=("$HOME/.bashrc")
    [ -f "$HOME/.zshrc" ] && rc_files+=("$HOME/.zshrc")

    # Default to .bashrc if neither exists
    if [ ${#rc_files[@]} -eq 0 ]; then
        rc_files=("$HOME/.bashrc")
    fi

    for rc in "${rc_files[@]}"; do
        if grep -qF "$HOOK_MARKER" "$rc" 2>/dev/null; then
            continue
        fi
        {
            echo ""
            echo "$HOOK_MARKER"
            echo "[ -f \"$HOOK_SCRIPT\" ] && source \"$HOOK_SCRIPT\""
        } >> "$rc"
        info "Shell hook installed in $rc"
    done
}

remove_shell_hook() {
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ ! -f "$rc" ] && continue
        if grep -qF "$HOOK_MARKER" "$rc" 2>/dev/null; then
            local tmpfile
            tmpfile=$(mktemp)
            grep -vF "$HOOK_MARKER" "$rc" | grep -vF "source \"$HOOK_SCRIPT\"" > "$tmpfile"
            mv "$tmpfile" "$rc"
            info "Shell hook removed from $rc"
        fi
    done
    rm -f "$HOOK_SCRIPT"
}

enable_downloads_cleanup() {
    local downloads_dir="$1"

    mkdir -p "$SCRIPTS_DIR"

    cat > "$CLEANUP_SCRIPT" <<CLEANUP_EOF
#!/bin/bash
DOWNLOADS_DIR="$downloads_dir"
MAX_AGE_DAYS=$DOWNLOADS_MAX_AGE_DAYS

[ ! -d "\$DOWNLOADS_DIR" ] && exit 1
find "\$DOWNLOADS_DIR" -type f -mtime +\${MAX_AGE_DAYS} -delete 2>/dev/null
find "\$DOWNLOADS_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
CLEANUP_EOF
    chmod +x "$CLEANUP_SCRIPT"

    generate_hook_script
    install_shell_hook
}

disable_downloads_cleanup() {
    if ! is_downloads_cleanup_enabled; then
        warn "Downloads auto-cleanup is already disabled"
        return
    fi

    rm -f "$CLEANUP_SCRIPT"
    rm -f "$LASTRUN_DIR/downloads-cleanup"

    if ! any_feature_enabled; then
        remove_shell_hook
    else
        generate_hook_script
    fi
    info "Downloads auto-cleanup disabled"
}

enable_paranoid_mode() {
    mkdir -p "$SCRIPTS_DIR"

    cat > "$PARANOID_SCRIPT" <<PARANOID_EOF
#!/bin/bash
# Purge shell history
rm -f "$HOME/.bash_history" 2>/dev/null
rm -f "$HOME/.zsh_history" 2>/dev/null

# Purge vim swap files
find "$VIM_DIR/swapfiles" -type f -delete 2>/dev/null

# Purge vim undo files
find "$VIM_DIR/undodir" -type f -delete 2>/dev/null
PARANOID_EOF
    chmod +x "$PARANOID_SCRIPT"

    generate_hook_script
    install_shell_hook
}

disable_paranoid_mode() {
    if ! is_paranoid_mode_enabled; then
        warn "Paranoid mode is already disabled"
        return
    fi

    rm -f "$PARANOID_SCRIPT"
    rm -f "$LASTRUN_DIR/paranoid-cleanup"

    if ! any_feature_enabled; then
        remove_shell_hook
    else
        generate_hook_script
    fi
    info "Paranoid mode disabled"
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

    info "Installing system packages: ${packages[*]}"
    if [ "$OS" = "linux" ]; then
        if check_command sudo; then
            sudo apt-get update -qq && sudo apt-get install -y -qq "${packages[@]}" || {
                error "Some packages failed to install"
            }
        else
            error "sudo not available. Install packages manually: apt-get install ${packages[*]}"
        fi
    elif [ "$OS" = "macos" ]; then
        if check_command brew; then
            brew install "${packages[@]}" 2>/dev/null || {
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
    clone_or_pull "$PATHOGEN_REPO" "$PATHOGEN_STAGING" "vim-pathogen" \
        "$BUNDLED_DIR"

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

        clone_or_pull "$url" "$dest" "$name" "$fallback"
    done
}

install_vimrc() {
    # Check if source line already exists
    if [ -f "$VIMRC" ] && grep -qF "$SOURCE_LINE" "$VIMRC"; then
        info "vimrc source line already present in $VIMRC"
        return
    fi

    # Backup existing vimrc if present
    if [ -f "$VIMRC" ]; then
        backup_file "$VIMRC"
    fi

    # Append the source line
    {
        echo ""
        echo "$SOURCE_MARKER"
        echo "$SOURCE_LINE"
    } >> "$VIMRC"
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
    if [ -d "$FONTS_STAGING" ]; then
        font_source="$FONTS_STAGING"
    elif [ -d "$BUNDLED_DIR/fonts/powerline" ]; then
        font_source="$BUNDLED_DIR/fonts/powerline"
        info "Using bundled fonts"
    else
        error "No font source available"
        return
    fi

    # Copy selected font families
    for family in "${FONT_FAMILIES[@]}"; do
        if [ -d "$font_source/$family" ]; then
            cp "$font_source/$family"/*.ttf "$FONT_DIR/" 2>/dev/null
            cp "$font_source/$family"/*.otf "$FONT_DIR/" 2>/dev/null
            info "Installed font family: $family"
        else
            warn "Font family not found: $family"
        fi
    done

    # Rebuild font cache on Linux
    if [ "$OS" = "linux" ] && check_command fc-cache; then
        fc-cache -f "$FONT_DIR"
        info "Font cache updated"
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

cmd_install() {
    echo -e "${BOLD}olecharms install${NC}"
    echo ""

    load_config || return 1
    detect_os

    install_packages
    create_vim_dirs
    install_pathogen
    install_plugins
    install_vimrc
    install_fonts
    run_post_commands

    echo ""
    if [ $ERROR_COUNT -eq 0 ]; then
        info "Install complete! No errors."
    else
        warn "Install complete with $ERROR_COUNT error(s). Review output above."
    fi
}

cmd_update() {
    echo -e "${BOLD}olecharms update${NC}"
    echo ""

    load_config || return 1
    detect_os

    # Self-update: pull the olecharms repo
    if [ -d "$SCRIPT_DIR/.git" ]; then
        info "Updating olecharms repo..."
        local before_script before_conf
        before_script=$(md5sum "$SCRIPT_DIR/olecharms.sh" 2>/dev/null | cut -d' ' -f1)
        before_conf=$(md5sum "$CONF_FILE" 2>/dev/null | cut -d' ' -f1)

        git -C "$SCRIPT_DIR" pull --ff-only 2>/dev/null || {
            warn "Could not update olecharms repo (may have local changes)"
        }

        local after_script after_conf
        after_script=$(md5sum "$SCRIPT_DIR/olecharms.sh" 2>/dev/null | cut -d' ' -f1)
        after_conf=$(md5sum "$CONF_FILE" 2>/dev/null | cut -d' ' -f1)

        if [ "$before_script" != "$after_script" ] || [ "$before_conf" != "$after_conf" ]; then
            warn "olecharms.sh or packages.conf was updated. Please re-run: ./olecharms.sh update"
            exit 0
        fi
    fi

    # Update pathogen
    install_pathogen

    # Update plugins
    install_plugins

    # Update fonts
    install_fonts

    # Run post-install commands
    run_post_commands

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
}

cmd_status() {
    echo -e "${BOLD}olecharms status${NC}"
    echo ""

    load_config || return 1
    detect_os

    echo -e "${BLUE}OS:${NC} $OS ($PKG_MANAGER)"
    echo -e "${BLUE}Repo:${NC} $SCRIPT_DIR"
    echo -e "${BLUE}Vim dir:${NC} $VIM_DIR"
    echo -e "${BLUE}Font dir:${NC} $FONT_DIR"

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
}

config_downloads_cleanup() {
    if is_downloads_cleanup_enabled; then
        echo -e "  Status: ${GREEN}enabled${NC}"
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
        echo "  Once a day (on next shell open), files older than ${DOWNLOADS_MAX_AGE_DAYS} days will be"
        echo "  deleted from:"
        echo "    $selected"
        echo ""
        read -rp "  Enable auto-cleanup? [y/N] " confirm
        case "$confirm" in
            [yY])
                enable_downloads_cleanup "$selected"
                info "Downloads auto-cleanup enabled for $selected"
                info "Changes take effect in your next shell session."
                ;;
            *)
                info "No changes made"
                ;;
        esac
    fi
}

config_paranoid_mode() {
    if is_paranoid_mode_enabled; then
        echo -e "  Status: ${GREEN}enabled${NC}"
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
        echo "  Every 12 hours (checked on shell open), paranoid mode will delete:"
        echo "    - Bash history (~/.bash_history)"
        echo "    - Zsh history (~/.zsh_history)"
        echo "    - Vim swap files ($VIM_DIR/swapfiles/)"
        echo "    - Vim undo files ($VIM_DIR/undodir/)"
        echo ""

        if ! is_downloads_cleanup_enabled; then
            echo -e "  ${YELLOW}Note:${NC} Downloads auto-cleanup is not enabled."
            echo "  Paranoid mode will also enable it."
            echo ""
        fi

        read -rp "  Enable paranoid mode? [y/N] " confirm
        case "$confirm" in
            [yY])
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
                    enable_downloads_cleanup "$selected"
                    info "Downloads auto-cleanup enabled for $selected"
                fi

                enable_paranoid_mode
                info "Paranoid mode enabled"
                info "Changes take effect in your next shell session."
                ;;
            *)
                info "No changes made"
                ;;
        esac
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
    cat <<'EOF'
olecharms.sh — Environment management for olecharms

Usage: ./olecharms.sh <command>

Commands:
  install   Full install: packages, vim dirs, pathogen, plugins, vimrc, fonts
  update    Pull latest changes for repo, plugins, pathogen, and fonts
  check     Report installed/missing dependencies and plugin status
  status    Show what's installed with version info
  config    Interactive menu to toggle system features (e.g. downloads cleanup)
  help      Show this help message

Configuration:
  Edit packages.conf to add/remove system packages, vim plugins, font families,
  and post-install commands.

Examples:
  ./olecharms.sh install    # First-time setup
  ./olecharms.sh update     # Update everything
  ./olecharms.sh check      # See what's installed/missing
  ./olecharms.sh config     # Toggle system features
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        install) cmd_install ;;
        update)  cmd_update ;;
        check)   cmd_check ;;
        status)  cmd_status ;;
        config)  cmd_config ;;
        help|--help|-h) cmd_help ;;
        "")
            error "No command specified"
            echo ""
            cmd_help
            exit 1
            ;;
        *)
            error "Unknown command: $1"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
