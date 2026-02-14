#!/bin/bash
# olecharms.sh — Environment management script for olecharms
# Usage: ./olecharms.sh {install|update|check|status|config|help}

# ─── Constants & Globals ─────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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

    # If directory exists but is not a git repo, move to bundle_disabled and re-clone
    if [ -d "$dest" ] && [ ! -d "$dest/.git" ]; then
        warn "$name exists but is not a git repo. Moving to bundle_disabled and re-cloning."
        local disabled_dest="$VIM_DIR/bundle_disabled/${name}.replaced.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$VIM_DIR/bundle_disabled"
        mv "$dest" "$disabled_dest"
        info "Moved $dest → $disabled_dest"
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

is_downloads_cron_enabled() {
    check_command crontab && crontab -l 2>/dev/null | grep -qF "$CRON_MARKER_DOWNLOADS"
}

is_paranoid_cron_enabled() {
    check_command crontab && crontab -l 2>/dev/null | grep -qF "$CRON_MARKER_PARANOID"
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
HOOK_EOF

    # Only include features that are hook-scheduled (not cron)
    if is_downloads_cleanup_enabled && ! is_downloads_cron_enabled; then
        echo "_olecharms_check_and_run \"$CLEANUP_SCRIPT\" \"downloads-cleanup\" $DOWNLOADS_INTERVAL" >> "$HOOK_SCRIPT"
    fi
    if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
        echo "_olecharms_check_and_run \"$PARANOID_SCRIPT\" \"paranoid-cleanup\" $PARANOID_INTERVAL" >> "$HOOK_SCRIPT"
    fi

    {
        echo ""
        echo "unset -f _olecharms_check_and_run"
    } >> "$HOOK_SCRIPT"
    chmod +x "$HOOK_SCRIPT"
}

install_shell_hook() {
    local rc_files=()
    [ -f "$HOME/.bashrc" ] && rc_files+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && rc_files+=("$HOME/.bash_profile")
    [ -f "$HOME/.zshrc" ] && rc_files+=("$HOME/.zshrc")

    # Default to .bashrc if none exist
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
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
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

generate_shell_loader() {
    mkdir -p "$SCRIPTS_DIR"

    cat > "$SHELL_LOADER" <<LOADER_EOF
#!/bin/bash
# olecharms-shell.sh — sources shell command files from $SHELL_DIR
for _olecharms_f in "$SHELL_DIR"/*.sh; do
    [ -f "\$_olecharms_f" ] && source "\$_olecharms_f"
done
unset _olecharms_f
LOADER_EOF
    chmod +x "$SHELL_LOADER"
}

install_shell_commands() {
    # Check if shell dir exists and has files
    if [ ! -d "$SHELL_DIR" ] || [ -z "$(ls "$SHELL_DIR"/*.sh 2>/dev/null)" ]; then
        return
    fi

    generate_shell_loader

    local rc_files=()
    [ -f "$HOME/.bashrc" ] && rc_files+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && rc_files+=("$HOME/.bash_profile")
    [ -f "$HOME/.zshrc" ] && rc_files+=("$HOME/.zshrc")

    # Default to .bashrc if none exist
    if [ ${#rc_files[@]} -eq 0 ]; then
        rc_files=("$HOME/.bashrc")
    fi

    for rc in "${rc_files[@]}"; do
        if grep -qF "$SHELL_MARKER" "$rc" 2>/dev/null; then
            continue
        fi
        {
            echo ""
            echo "$SHELL_MARKER"
            echo "[ -f \"$SHELL_LOADER\" ] && source \"$SHELL_LOADER\""
        } >> "$rc"
        info "Shell commands installed in $rc"
    done
}

remove_shell_commands() {
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        [ ! -f "$rc" ] && continue
        if grep -qF "$SHELL_MARKER" "$rc" 2>/dev/null; then
            local tmpfile
            tmpfile=$(mktemp)
            grep -vF "$SHELL_MARKER" "$rc" | grep -vF "source \"$SHELL_LOADER\"" > "$tmpfile"
            mv "$tmpfile" "$rc"
            info "Shell commands removed from $rc"
        fi
    done
    rm -f "$SHELL_LOADER"
}

install_binary() {
    mkdir -p "$BIN_DIR"
    ln -sf "$SCRIPT_DIR/olecharms.sh" "$BIN_DIR/olecharms"
    info "Symlinked olecharms → $BIN_DIR/olecharms"

    # Check if ~/.local/bin is already on PATH
    if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR" 2>/dev/null; then
        return
    fi

    local rc_files=()
    [ -f "$HOME/.bashrc" ] && rc_files+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && rc_files+=("$HOME/.bash_profile")
    [ -f "$HOME/.zshrc" ] && rc_files+=("$HOME/.zshrc")

    if [ ${#rc_files[@]} -eq 0 ]; then
        rc_files=("$HOME/.bashrc")
    fi

    for rc in "${rc_files[@]}"; do
        if grep -qF "$BIN_MARKER" "$rc" 2>/dev/null; then
            continue
        fi
        {
            echo ""
            echo "$BIN_MARKER"
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
        } >> "$rc"
        info "Added ~/.local/bin to PATH in $rc"
    done
}

enable_downloads_cleanup() {
    local downloads_dir="$1"
    local mode="${2:-hook}"

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

    if [ "$mode" = "cron" ]; then
        local new_entry="$DOWNLOADS_CRON_MIN $DOWNLOADS_CRON_HOUR * * * $CLEANUP_SCRIPT $CRON_MARKER_DOWNLOADS"
        local existing
        existing=$(crontab -l 2>/dev/null | grep -v "$CRON_MARKER_DOWNLOADS") || true
        if [ -n "$existing" ]; then
            printf '%s\n%s\n' "$existing" "$new_entry" | crontab -
        else
            echo "$new_entry" | crontab -
        fi
        # Regenerate hook script to exclude downloads if paranoid uses it
        if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
            generate_hook_script
        fi
    else
        generate_hook_script
        install_shell_hook
    fi
}

disable_downloads_cleanup() {
    if ! is_downloads_cleanup_enabled; then
        warn "Downloads auto-cleanup is already disabled"
        return
    fi

    # Remove cron entry if present
    if is_downloads_cron_enabled; then
        local existing
        existing=$(crontab -l 2>/dev/null | grep -v "$CRON_MARKER_DOWNLOADS") || true
        if [ -n "$existing" ]; then
            echo "$existing" | crontab -
        else
            crontab -r 2>/dev/null || true
        fi
    fi

    rm -f "$CLEANUP_SCRIPT"
    rm -f "$LASTRUN_DIR/downloads-cleanup"

    if is_paranoid_mode_enabled && ! is_paranoid_cron_enabled; then
        generate_hook_script
    else
        remove_shell_hook
    fi
    info "Downloads auto-cleanup disabled"
}

enable_paranoid_mode() {
    local mode="${1:-hook}"

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

    if [ "$mode" = "cron" ]; then
        local new_entry="$PARANOID_CRON_SCHEDULE $PARANOID_SCRIPT $CRON_MARKER_PARANOID"
        local existing
        existing=$(crontab -l 2>/dev/null | grep -v "$CRON_MARKER_PARANOID") || true
        if [ -n "$existing" ]; then
            printf '%s\n%s\n' "$existing" "$new_entry" | crontab -
        else
            echo "$new_entry" | crontab -
        fi
        # Regenerate hook script to exclude paranoid if downloads uses it
        if is_downloads_cleanup_enabled && ! is_downloads_cron_enabled; then
            generate_hook_script
        fi
    else
        generate_hook_script
        install_shell_hook
    fi
}

disable_paranoid_mode() {
    if ! is_paranoid_mode_enabled; then
        warn "Paranoid mode is already disabled"
        return
    fi

    # Remove cron entry if present
    if is_paranoid_cron_enabled; then
        local existing
        existing=$(crontab -l 2>/dev/null | grep -v "$CRON_MARKER_PARANOID") || true
        if [ -n "$existing" ]; then
            echo "$existing" | crontab -
        else
            crontab -r 2>/dev/null || true
        fi
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
    if [ -f "$VIMRC" ]; then
        # Already has the exact current source line — nothing to do
        if grep -qF "$SOURCE_LINE" "$VIMRC"; then
            info "vimrc source line already present in $VIMRC"
            return
        fi

        # Has an old source line with a different path — replace it
        if grep -q 'source .*/vimthings/olevimrc\.vim' "$VIMRC"; then
            sed -i "s|source .*/vimthings/olevimrc\.vim|$SOURCE_LINE|" "$VIMRC"
            info "Updated source line path in $VIMRC"
            return
        fi

        backup_file "$VIMRC"
    fi

    # Append fresh
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

install_omz() {
    # Install Oh My Zsh if not present
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        info "Installing Oh My Zsh..."
        if check_command curl; then
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        elif check_command wget; then
            sh -c "$(wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        else
            error "Neither curl nor wget available. Cannot install Oh My Zsh."
            return 1
        fi
    else
        info "Oh My Zsh already installed"
    fi

    # Create custom theme with random host color (only on first install)
    local theme_dir="$HOME/.oh-my-zsh/custom/themes"
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
            sed -i 's/^ZSH_THEME=.*/ZSH_THEME="olecharms"/' "$zshrc"
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
    install_omz
    run_post_commands
    install_shell_commands
    install_binary

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
        before_script=$(_file_hash "$SCRIPT_DIR/olecharms.sh")
        before_conf=$(_file_hash "$CONF_FILE")

        git -C "$SCRIPT_DIR" pull --rebase --autostash 2>/dev/null || {
            warn "Could not update olecharms repo"
        }

        local after_script after_conf
        after_script=$(_file_hash "$SCRIPT_DIR/olecharms.sh")
        after_conf=$(_file_hash "$CONF_FILE")

        if [ "$before_script" != "$after_script" ] || [ "$before_conf" != "$after_conf" ]; then
            info "olecharms.sh or packages.conf was updated. Relaunching..."
            exec "$SCRIPT_DIR/olecharms.sh" update
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

    # Ensure shell commands are installed
    install_shell_commands
    install_binary

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
            echo "  Paranoid mode will also enable it."
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
            enable_downloads_cleanup "$selected" "$mode"
            info "Downloads auto-cleanup enabled for $selected"
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
    echo "  install   Full install: packages, vim dirs, pathogen, plugins, vimrc, fonts"
    echo "  update    Pull latest changes for repo, plugins, pathogen, and fonts"
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
}

main "$@"
