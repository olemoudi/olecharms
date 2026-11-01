# Sourced first by every suite. Builds a throwaway sandbox and points the
# whole environment at it, so nothing a test does can reach your real files:
#   $SB/repo   a copy of this checkout (without .git and scripts/)
#   $SB/home   a fake HOME, with .bashrc/.zshrc and a "downloads" symlink
#   $SB/win    a fake Windows downloads folder holding back-dated files
#   $SB/bin    first on PATH: a fake crontab (backed by a file) and a sudo
#              that always refuses, so no test installs system packages
# The sandbox lives in $OLECHARMS_TEST_TMP (tests/run.sh creates it) or, when
# a suite runs on its own, in a new temporary folder removed at exit. Either
# way it must hold the .olecharms-test marker: nothing is ever deleted
# outside a folder that carries it.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_SRC=$(cd "$TESTS_DIR/.." && pwd)
REAL_HOME=$HOME
TEST_OMZ=${OLECHARMS_TEST_OMZ:-$HOME/.oh-my-zsh}   # read before the environment is cleaned

if [ -n "${OLECHARMS_TEST_TMP:-}" ]; then
    S=$OLECHARMS_TEST_TMP
else
    S=$(mktemp -d "${TMPDIR:-/tmp}/olecharms-test.XXXXXX") || exit 1
    touch "$S/.olecharms-test"
    trap '[ -f "$S/.olecharms-test" ] && rm -rf "$S"' EXIT
fi
case "$S" in
    /*) ;;
    *) echo "ABORT: test folder must be an absolute path: $S"; exit 1 ;;
esac
[ -f "$S/.olecharms-test" ] || { echo "ABORT: $S is not an olecharms test folder (no .olecharms-test)"; exit 1; }
SB=$S/sb

# Nothing from the real environment may steer olecharms or git
for _v in $(compgen -e | grep -E '^(OLECHARMS_|GIT_)'); do unset "$_v"; done
unset _v XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ZSH ZSH_CUSTOM ZDOTDIR HISTFILE
unset SSH_CONNECTION SSH_TTY TMUX
export GIT_CONFIG_NOSYSTEM=1

# The Windows user's profile folder on WSL (empty elsewhere)
win_profile() {
    [ -d /mnt/c ] && command -v cmd.exe >/dev/null 2>&1 || return 0
    local p
    p=$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')
    case "$p" in
        [A-Za-z]:\\*) wslpath -u "$p" 2>/dev/null ;;
    esac
}

build_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB"/{bin,home,win/Downloads/sub,win/Downloads/emptydir} || return 1
    rsync -a --exclude .git --exclude scripts --exclude tests "$REPO_SRC/" "$SB/repo/" || return 1
    # The script as a library: without the trailing `main "$@"; exit $?`,
    # and told where it lives
    head -n -2 "$SB/repo/olecharms.sh" |
        sed "s#^_src=\"\${BASH_SOURCE\[0\]}\"#_src=$SB/repo/olecharms.sh#" > "$SB/repo/lib.sh"
    grep -q "^_src=$SB/repo/olecharms.sh" "$SB/repo/lib.sh" || { echo "lib.sh patch failed"; return 1; }

    cat > "$SB/bin/crontab" <<'EOF'
#!/bin/bash
F="$CRON_FILE"
case "$1" in
  -l) if [ -n "$CRON_FAIL" ]; then echo "crontab: permission denied" >&2; exit 1; fi
      [ -f "$F" ] || { echo "no crontab for tester" >&2; exit 1; }; cat "$F" ;;
  -r) rm -f "$F"; echo w >> "$F.writes" ;;
  -)  cat > "$F"; echo w >> "$F.writes" ;;
esac
EOF
    printf '#!/bin/sh\necho "sudo: disabled in the olecharms tests" >&2\nexit 1\n' > "$SB/bin/sudo"
    chmod +x "$SB/bin/crontab" "$SB/bin/sudo"

    local H=$SB/home D=$SB/win/Downloads
    printf '# user bashrc\nalias ll="ls -l"\n' > "$H/.bashrc"
    printf '# user zshrc\n' > "$H/.zshrc"
    ln -s "$SB/win/Downloads" "$H/downloads"
    touch -d '60 days ago' "$D/old1.zip" "$D/sub/old2.pdf" "$D/desktop.ini" "$D/.localized"
    touch "$D/new.txt"
}
build_sandbox >/dev/null || { echo "ABORT: could not build the sandbox in $SB"; exit 1; }

# From here on HOME, config, PATH and crontab are the sandbox's; each suite
# repeats this and adds its own variables
export HOME=$SB/home XDG_CONFIG_HOME=$SB/home/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
# The Windows side (gVim's home) is redirected into the sandbox too
export OLECHARMS_WIN_VIM_HOME=$SB/winhome
