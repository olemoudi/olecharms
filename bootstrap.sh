#!/bin/bash
# olecharms bootstrap — a new machine in one command:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/olemoudi/olecharms/master/bootstrap.sh)"
#
# (or: curl -fsSL .../bootstrap.sh | bash). Gets git if it is missing, clones
# olecharms (or updates an existing checkout) and runs `olecharms install`,
# which also offers the settings you shared from your other machines.
#   OLECHARMS_DIR   where to clone (default: ~/olecharms)
#   OLECHARMS_REPO  what to clone  (default: the GitHub repository)
# Safe to run again: an existing checkout is updated, never replaced.
set -u

REPO="${OLECHARMS_REPO:-https://github.com/olemoudi/olecharms.git}"
DIR="${OLECHARMS_DIR:-$HOME/olecharms}"

say()  { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Run from `curl | bash`, stdin is the script itself: the installer's
# questions must read the terminal instead
# (re-opening /dev/stdin instead is not safe: it fails when stdin is a socket)
TTY_IN=""
if [ ! -t 0 ] && { : < /dev/tty; } 2>/dev/null; then
    TTY_IN=/dev/tty
fi

# Run "$@" reading the terminal when stdin is the piped script
with_tty() {
    if [ -n "$TTY_IN" ]; then "$@" < "$TTY_IN"; else "$@"; fi
}

[ "$(id -u)" != 0 ] || [ -n "${OLECHARMS_ALLOW_ROOT:-}" ] ||
    fail "Run this as your normal user: olecharms sets up your home directory (OLECHARMS_ALLOW_ROOT=1 to override)"

# On a fresh Mac /usr/bin/git exists but is only a stub until Apple's
# Command Line Tools are installed
git_ok() {
    if [ "$(uname -s)" = Darwin ]; then
        xcode-select -p >/dev/null 2>&1 && git --version >/dev/null 2>&1
    else
        command -v git >/dev/null 2>&1
    fi
}

if ! git_ok; then
    say "git is missing; installing it"
    case "$(uname -s)" in
        Darwin)
            # Opens Apple's installer for the command line tools (includes git)
            xcode-select --install 2>/dev/null
            fail "Finish the Command Line Tools install that just opened, then run this again"
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                with_tty sudo apt-get update -qq && with_tty sudo apt-get install -y git
            elif command -v dnf >/dev/null 2>&1; then
                with_tty sudo dnf install -y git
            elif command -v pacman >/dev/null 2>&1; then
                with_tty sudo pacman -S --noconfirm git
            fi
            git_ok || fail "Could not install git; install it and run this again"
            ;;
    esac
fi

if [ -d "$DIR/.git" ]; then
    say "olecharms is already at $DIR; updating it"
    git -C "$DIR" pull --ff-only -q || say "Could not update $DIR (local changes?); installing from it as it is"
elif [ -e "$DIR" ]; then
    fail "$DIR exists and is not an olecharms checkout; set OLECHARMS_DIR to another folder"
else
    say "Cloning $REPO into $DIR"
    GIT_TERMINAL_PROMPT=0 git clone -q "$REPO" "$DIR" || fail "Could not clone $REPO"
fi

[ -f "$DIR/olecharms.sh" ] || fail "$DIR has no olecharms.sh"
say "Running olecharms install"
if [ -n "$TTY_IN" ]; then
    exec bash "$DIR/olecharms.sh" install < "$TTY_IN"
fi
exec bash "$DIR/olecharms.sh" install
