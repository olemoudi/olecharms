#!/bin/bash
# Paranoid mode: downloads age 15 (lower / enable), viminfo, Windows gVim purge.
# Sandboxed HOME; the Windows vim home is redirected into the sandbox and every
# generated script is checked for real paths before it is run.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home D=$SB/win/Downloads W=$SB/winhome
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
# files can be back-dated (mtime) but not their ctime
export OLECHARMS_TEST_IGNORE_CTIME=1
export OLECHARMS_WIN_VIM_HOME=$W
unset XDG_DATA_HOME XDG_STATE_HOME ZSH ZSH_CUSTOM
OC="bash $SB/repo/olecharms.sh"
CFG=$H/.config/olecharms/config
P=$SB/repo/scripts/paranoid-cleanup.sh
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$SB/repo/lib.sh'; detect_os; config_ensure >/dev/null; $1" 2>&1; }
cfg() { grep "^$1=" "$CFG" | cut -d= -f2-; }
# Never run a generated script that points outside the sandbox
safe_paranoid() {
    # TASKLIST only lists processes; every path that is deleted from must be in the sandbox
    grep -v '^TASKLIST=' "$P" | grep -q '/mnt/c' && { echo "ABORT: paranoid script mentions /mnt/c"; exit 1; }
    grep -E '^(HOME_DIR|VIM_DIR|WIN_VIM_HOME|CLEANUP_LOG)=' "$P" | grep -v "=$SB" && { echo "ABORT: path outside sandbox"; exit 1; }
    return 0
}

touch -d '20 days ago' "$D/mid.txt"; touch -d '400 days ago' "$D/ancient.txt"
mkdir -p "$W/vimfiles"/{swapfiles,undodir,colors} "$H/.vim"/{swapfiles,undodir}
reset_traces() {
    echo h > "$H/.bash_history"; echo v > "$H/.viminfo"; echo s > "$H/.vim/swapfiles/a.swp"; echo u > "$H/.vim/undodir/%x"
    echo v > "$W/_viminfo"; echo s > "$W/vimfiles/swapfiles/b.swp"; echo u > "$W/vimfiles/undodir/C%%x"
    echo keep > "$W/_vimrc"; echo keep > "$W/vimfiles/colors/keep.vim"
}

echo "== A. cleanup on at 365 days → enabling paranoid lowers it to 15 (with preview)"
lib 'enable_downloads_cleanup "$HOME/downloads" hook 365' >/dev/null
out=$(printf '2\n1\n\n0\n' | $OC config 2>&1)
echo "$out" | grep -E 'Also:|Rule:|Matches:|lowered|Windows gVim|viminfo' | sed 's/^/    /'
chk "menu announces 365 → 15"            grep -q 'goes from 365 to 15 days' <<< "$out"
chk "menu lists ~/.viminfo"              grep -q '~/.viminfo' <<< "$out"
chk "menu lists Windows gVim targets"    grep -q "Windows gVim: $W/_viminfo" <<< "$out"
chk "preview uses 15 days"               grep -q 'for over 15 days' <<< "$out"
chk "preview counts 4 files"             grep -q 'Matches:  4 files' <<< "$out"
chk "max age now 15"                     test "$(cfg downloads_cleanup_max_age_days)" = 15
chk "paranoid enabled"                   test "$(cfg paranoid_mode_enabled)" = true
chk "cleanup still enabled, same folder" test "$(cfg downloads_cleanup_dir)" = "$H/downloads"
chk "nothing deleted by the menu"        test -e "$D/mid.txt" -a -e "$D/ancient.txt"

echo "== B. generated paranoid script purges Linux + Windows traces, nothing else"
safe_paranoid
chk "script has viminfo line"            grep -q 'HOME_DIR/.viminfo' "$P"
chk "script has sandbox WIN_VIM_HOME"    grep -qx "WIN_VIM_HOME=$W" "$P"
GV=$(sed -n 's/^GENERATOR_VERSION=//p' "$SB/repo/olecharms.sh")
chk "script stamped generator $GV"       grep -qx "# olecharms-generator: $GV" "$P"
reset_traces; bash "$P"; echo "  exit=$?"
chk "~/.bash_history gone"               test ! -e "$H/.bash_history"
chk "~/.viminfo gone"                    test ! -e "$H/.viminfo"
chk "linux swap + undo gone"             test "$(find "$H/.vim/swapfiles" "$H/.vim/undodir" -type f | wc -l)" -eq 0
chk "windows _viminfo gone"              test ! -e "$W/_viminfo"
chk "windows swap + undo gone"           test "$(find "$W/vimfiles/swapfiles" "$W/vimfiles/undodir" -type f | wc -l)" -eq 0
chk "windows _vimrc kept"                test -e "$W/_vimrc"
chk "windows other vimfiles kept"        test -e "$W/vimfiles/colors/keep.vim"
chk "windows dirs themselves kept"       test -d "$W/vimfiles/undodir" -a -d "$W/vimfiles/swapfiles"

echo "== C. doctor"
dout=$($OC doctor 2>&1)
chk "doctor: purges Windows gVim"        grep -q 'Also purges the Windows gVim history' <<< "$dout"
chk "doctor: downloads at most 15"       grep -q 'Downloads kept at most 15 days' <<< "$dout"
lib 'config_set downloads_cleanup_max_age_days 365' >/dev/null
dout=$($OC doctor 2>&1)
chk "doctor warns when loosened to 365"  grep -q 'keeps 365 days (paranoid mode sets 15)' <<< "$dout"
lib 'config_set downloads_cleanup_max_age_days 15' >/dev/null

echo "== D. Windows integration off → script regenerated without the Windows part, and back"
printf '3\n0\n' | $OC config >/dev/null 2>&1
chk "integration off"                    test "$(cfg windows_integration)" = off
chk "no Windows block"                   bash -c "! grep -q WIN_VIM_HOME '$P'"
chk "menu no longer lists Windows"       bash -c "! printf '2\nn\n0\n' | $OC config 2>&1 | grep -q 'Windows gVim:'"
printf '3\n0\n' | $OC config >/dev/null 2>&1
chk "Windows block back"                 grep -qx "WIN_VIM_HOME=$W" "$P"; safe_paranoid

echo "== E. disabling paranoid keeps the cleanup and says so"
out=$(printf '2\ny\n0\n' | $OC config 2>&1)
chk "paranoid disabled"                  test "$(cfg paranoid_mode_enabled)" = false
chk "says cleanup stays at 15"           grep -q 'stays on (15 days)' <<< "$out"
chk "cleanup still enabled"              test "$(cfg downloads_cleanup_enabled)" = true

echo "== F. cleanup already ≤ 15 days → unchanged, no confirmation asked"
lib 'config_set downloads_cleanup_max_age_days 7' >/dev/null
out=$(printf '2\n1\n0\n' | $OC config 2>&1)
chk "says unchanged"                     grep -q 'older than 7 days — unchanged' <<< "$out"
chk "no preview shown"                   bash -c "! grep -q 'Matches:' <<< \"\$1\"" _ "$out"
chk "age still 7"                        test "$(cfg downloads_cleanup_max_age_days)" = 7
chk "paranoid enabled"                   test "$(cfg paranoid_mode_enabled)" = true
printf '2\ny\n0\n' | $OC config >/dev/null 2>&1

echo "== G. declining the preview changes nothing"
lib 'config_set downloads_cleanup_max_age_days 365' >/dev/null
out=$(printf '2\n1\nn\n0\n' | $OC config 2>&1)
chk "says cancelled"                     grep -q 'Cancelled' <<< "$out"
chk "age still 365"                      test "$(cfg downloads_cleanup_max_age_days)" = 365
chk "paranoid still disabled"            test "$(cfg paranoid_mode_enabled)" = false

echo "== H. cleanup off → enabling paranoid enables it at 15 days"
lib 'disable_downloads_cleanup' >/dev/null
idx=$(lib 'find_downloads_dirs' | grep -nxF "$H/downloads" | cut -d: -f1)
[ -n "$idx" ] || { echo "ABORT: sandbox downloads folder not offered"; exit 1; }
out=$(printf '2\n1\n%s\n\n0\n' "$idx" | $OC config 2>&1)
echo "$out" | grep -E 'Also:|Matches:|enabled for' | sed 's/^/    /'
chk "menu announces enabling at 15"      grep -q 'enables downloads auto-cleanup for files older than 15 days' <<< "$out"
chk "preview counts 4 files"             grep -q 'Matches:  4 files' <<< "$out"
chk "cleanup enabled on sandbox folder"  test "$(cfg downloads_cleanup_enabled)/$(cfg downloads_cleanup_dir)" = "true/$H/downloads"
chk "max age 15"                         test "$(cfg downloads_cleanup_max_age_days)" = 15
chk "paranoid enabled"                   test "$(cfg paranoid_mode_enabled)" = true
chk "nothing deleted by the menu"        test -e "$D/mid.txt"

echo "== I. restore on update regenerates the Windows part"
rm -f "$P"
lib 'restore_scheduled_features' >/dev/null
safe_paranoid
chk "restored with Windows block"        grep -qx "WIN_VIM_HOME=$W" "$P"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
