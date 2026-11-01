#!/bin/bash
# A full `olecharms update` (twice) in the sandbox, then the real Windows
# vim.exe loading the synced config; also the cleanup engine, doctor, the
# loader, packages.local.conf, config migration and the self-update stash
# warning. Only run by `tests/run.sh --full`: it needs WSL with Windows Vim
# installed and the network (plugins, fonts and oh-my-zsh are cloned).
# Linux side: sandbox HOME/crontab. Windows side: gVim's home is our own
# folder in your Windows temp dir ($WSB). Like a real update, it installs
# the Powerline fonts for your Windows user if they are missing.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
WINP=$(win_profile)
VIMEXE=$(ls -d "/mnt/c/Program Files"*/Vim/vim*/vim.exe 2>/dev/null | sort | tail -n 1)
if [ -z "$WINP" ] || [ -z "$VIMEXE" ]; then
    echo "SKIP: needs WSL with Windows Vim installed"; exit 77
fi
WSB=$WINP/AppData/Local/Temp/olecharms-test
case "$WSB" in
    /mnt/?/*/AppData/Local/Temp/olecharms-test) rm -rf "$WSB" ;;
    *) echo "ABORT: unexpected Windows test folder: $WSB"; exit 1 ;;
esac
mkdir -p "$WSB/Downloads" "$WSB/home" || exit 1
H=$SB/home D=$SB/win/Downloads
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
# files can be back-dated (mtime) but not their ctime
export OLECHARMS_TEST_IGNORE_CTIME=1
export OLECHARMS_WIN_VIM_HOME=$WSB/home
unset XDG_DATA_HOME XDG_STATE_HOME ZSH ZSH_CUSTOM
LOG=$H/.local/state/olecharms/cleanup.log
OC="bash $SB/repo/olecharms.sh"
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$SB/repo/lib.sh'; detect_os; config_ensure >/dev/null; $1" 2>&1; }
# Safety: never let a test point the cleanup at a real folder
guard() { grep -q "^downloads_cleanup_dir=\($SB\|$WSB\)" "$H/.config/olecharms/config" || { echo "ABORT: cleanup dir outside sandbox"; exit 1; }; }

echo "== A. cleanup engine (Linux folder → auto = delete)"
lib 'enable_downloads_cleanup "$HOME/downloads" hook 30' >/dev/null; guard
CS=$SB/repo/scripts/cleanup-downloads.sh
chk "launcher stamped with generator version" grep -q '^# olecharms-generator: 5$' "$CS"
out=$($OC cleanup --dry-run 2>&1)
chk "dry-run lists old1.zip"              grep -q 'old1.zip' <<< "$out"
chk "dry-run hides desktop.ini/.localized" bash -c "! grep -qE 'desktop.ini$|\.localized$' <<< \"\$1\"" _ "$out"
chk "dry-run changes nothing"             test -e "$D/old1.zip"
chk "dry-run says quarantine (auto, Linux FS)" grep -q 'move to quarantine' <<< "$out"
mkdir "$H/.local/state/olecharms" -p; mkdir "$H/.local/state/olecharms/cleanup.lock"
bash "$CS"; chk "fresh lock blocks a 2nd run"     test -e "$D/old1.zip"
touch -d '2 days ago' "$H/.local/state/olecharms/cleanup.lock"
bash "$CS"; chk "stale lock is taken over; run deletes" test ! -e "$D/old1.zip"
chk "lock released after run"            test ! -e "$H/.local/state/olecharms/cleanup.lock"
chk "log header"                          grep -qE '^=== .* scheduled .* quarantine +2 files' "$LOG"
chk "log lists quarantined file"          grep -q "^quarant\. .*old1.zip" "$LOG"
chk "desktop.ini + .localized + new kept" test -e "$D/desktop.ini" -a -e "$D/.localized" -a -e "$D/new.txt"
out=$($OC cleanup --log 2>&1); chk "cleanup --log shows the run" grep -q 'scheduled' <<< "$out"
touch -d '60 days ago' "$D/old3.txt"
echo n | $OC cleanup >/dev/null 2>&1; rc=$?
chk "manual run without tty refuses (rc=$rc)" test "$rc" -ne 0 -a -e "$D/old3.txt"
$OC cleanup --yes >/dev/null 2>&1; chk "manual --yes deletes" test ! -e "$D/old3.txt"
lib 'config_set downloads_cleanup_enabled false'; touch -d '60 days ago' "$D/old4.txt"
bash "$CS"; chk "scheduled run is a no-op when disabled" test -e "$D/old4.txt"
lib 'config_set downloads_cleanup_enabled true; config_set downloads_cleanup_action trash'
bash "$CS"; chk "action=trash on Linux uses gio" test ! -e "$D/old4.txt" -a -n "$(ls "$H/.local/share/Trash/files" 2>/dev/null)"
lib 'config_set downloads_cleanup_action auto'

echo "== C. full update twice in sandbox (incl. Windows gVim sync into $WSB/home)"
cd "$SB/repo"
timeout 500 $OC update </dev/null > "$S/u1.log" 2>&1; rc=$?
chk "update #1 exit 0 (got $rc)" test "$rc" -eq 0
grep -E '\[-\]|Windows|gVim|_vimrc|fonts' "$S/u1.log" | sed 's/^/    /'
VF=$WSB/home/vimfiles
chk "_vimrc created with marker + source line" bash -c "tr -d '\r' < '$WSB/home/_vimrc' | grep -qx 'source ~/vimfiles/olecharms/olevimrc.vim'"
chk "_vimrc uses CRLF"                    grep -q $'\r$' "$WSB/home/_vimrc"
n=$(ls "$VF/bundle" | wc -l); chk "9 plugins copied to vimfiles\\bundle ($n)" test "$n" -eq 9
chk "every copy stamped as managed"       test "$(ls "$VF"/bundle/*/.olecharms-managed | wc -l)" -eq 9
chk "no .git copied to Windows"           test -z "$(find "$VF/bundle" -name .git -maxdepth 2)"
chk "pathogen + olevimrc + undo/swap dirs" test -f "$VF/autoload/pathogen.vim" -a -f "$VF/olecharms/olevimrc.vim" -a -d "$VF/undodir" -a -d "$VF/swapfiles"
chk "local conf template created"         test -f "$H/.config/olecharms/packages.local.conf"
mkdir -p "$VF/bundle/mine"; echo x > "$VF/bundle/mine/plugin.vim"
cp "$WSB/home/_vimrc" "$S/vimrc1"
timeout 300 $OC update </dev/null > "$S/u2.log" 2>&1; rc=$?
chk "update #2 exit 0 (got $rc)" test "$rc" -eq 0
chk "update #2: _vimrc untouched"         cmp -s "$S/vimrc1" "$WSB/home/_vimrc"
chk "update #2: says already sources"     grep -q 'already sources olecharms' "$S/u2.log"
chk "user's own plugin dir left alone"    test -f "$VF/bundle/mine/plugin.vim"
chk "update #2: no shell-config-changed notice" bash -c "! grep -q 'Shell configuration changed' '$S/u2.log'"

echo "== D. real Windows vim.exe loads the synced config"
WOUT=$(wslpath -w "$WSB/out.txt")
( cd /mnt/c && HOME="$WSB/home" WSLENV=HOME/p timeout 60 "$VIMEXE" -N -i NONE -es -u "$(wslpath -w "$WSB/home/_vimrc")" \
    "+runtime! plugin/**/*.vim" "+redir! > $WOUT" "+scriptnames" \
    "+echo 'ENC=' . &encoding" "+echo 'UNDO=' . &undodir" "+echo 'GUIFONT=' . &guifont" \
    "+echo 'NERD=' . exists(':NERDTree') . ' CTRLP=' . exists(':CtrlP') . ' AIR=' . exists('g:loaded_airline') . ' FUG=' . exists(':Git')" \
    "+messages" "+redir END" "+qa!" ) </dev/null >/dev/null 2>&1
tr -d '\r' < "$WSB/out.txt" > "$S/vimout.txt" 2>/dev/null
grep -E 'olevimrc|pathogen|ENC=|UNDO=|GUIFONT=|NERD=|E[0-9]+:' "$S/vimout.txt" | sed 's/^/    /'
chk "vim.exe sourced olevimrc.vim from vimfiles" grep -q 'vimfiles.olecharms.olevimrc.vim' "$S/vimout.txt"
chk "encoding utf-8"                        grep -q 'ENC=utf-8' "$S/vimout.txt"
chk "undodir under vimfiles"                grep -q 'UNDO=.*vimfiles.undodir' "$S/vimout.txt"
chk "plugins loaded (NERDTree, CtrlP, airline, fugitive)" grep -q 'NERD=2 CTRLP=2 AIR=1 FUG=2' "$S/vimout.txt"
chk "no E-errors at startup"                bash -c "! grep -qE '\bE[0-9]+:' '$S/vimout.txt'"

echo "== E. doctor"
out=$($OC doctor 2>&1); rc=$?
echo "$out" | grep -E '✗|~|ok,' | sed 's/^/    /'
chk "doctor exit 0 on a healthy sandbox (got $rc)" test "$rc" -eq 0
rm -f "$H/.local/bin/olecharms"
$OC doctor >/dev/null 2>&1; rc=$?; chk "doctor exit 1 with missing launcher (got $rc)" test "$rc" -eq 1
$OC doctor --fix >/dev/null 2>&1; rc=$?; chk "doctor --fix repairs it (got $rc)" test "$rc" -eq 0 -a -L "$H/.local/bin/olecharms"
rm -f "$WSB/home/_vimrc"
$OC windows status >/dev/null 2>&1; rc=$?; chk "windows status fails without _vimrc (got $rc)" test "$rc" -eq 1
$OC windows >/dev/null 2>&1; chk "olecharms windows recreates _vimrc" test -f "$WSB/home/_vimrc"
out=$($OC check 2>&1); chk "'check' is an alias of doctor" grep -q 'olecharms doctor' <<< "$out"

echo "== F. shell loader: autojump + wrapper"
for sh in zsh bash; do
  chk "$sh: j defined by loader" $sh -c "source '$SB/repo/scripts/olecharms-shell.sh'; command -v j >/dev/null"
done
chk "loader wrapper execs zsh after install"  grep -q 'exec zsh -l' "$SB/repo/scripts/olecharms-shell.sh"

echo "== G. packages.local.conf + config migration"
echo 'APT_PACKAGES+=( zzfake ); [ -n "$OLECHARMS_WSL" ] && LOCAL_SAW_WSL=1' >> "$H/.config/olecharms/packages.local.conf"
out=$(lib 'load_config; echo "${APT_PACKAGES[*]} wsl=$LOCAL_SAW_WSL"')
chk "local conf extends APT_PACKAGES and sees OLECHARMS_WSL ($out)" grep -q 'zzfake wsl=1' <<< "$out"
sed -i '/^downloads_cleanup_action=/d; /^windows_integration=/d; s/^CONFIG_VERSION=.*/CONFIG_VERSION=2/' "$H/.config/olecharms/config"
lib 'true' >/dev/null
chk "v2 → v3 migration adds new keys" grep -q '^downloads_cleanup_action=auto' "$H/.config/olecharms/config"
chk "CONFIG_VERSION=4"                grep -q '^CONFIG_VERSION=4' "$H/.config/olecharms/config"

echo "== H. self-update warns about local packages.conf changes and stash"
G=$SB/git; rm -rf "$G"; mkdir -p "$G"
git init -q --bare "$G/origin.git"
git clone -q "$G/origin.git" "$G/a" 2>/dev/null; rsync -a --exclude lib.sh "$SB/repo/" "$G/a/" --exclude scripts
( cd "$G/a" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init && git push -q origin HEAD 2>/dev/null )
git clone -q "$G/origin.git" "$G/b"
( cd "$G/b" && sed -i 's/^FONT_FAMILIES=.*/FONT_FAMILIES=( "Upstream" )/' packages.conf && git -c user.email=t@t -c user.name=t commit -qam up && git push -q 2>/dev/null )
sed -i 's/^FONT_FAMILIES=.*/FONT_FAMILIES=( "Local" )/' "$G/a/packages.conf"
out=$(cd "$G/a" && bash -c "source <(head -n -2 olecharms.sh | sed 's#^_src=\"\${BASH_SOURCE\[0\]}\"#_src=$G/a/olecharms.sh#'); _self_update status" 2>&1)
echo "$out" | grep -E 'local changes|stash' | sed 's/^/    /'
chk "warns packages.conf has local changes" grep -q 'packages.conf has local changes' <<< "$out"
chk "warns changes were set aside in stash" grep -q 'set aside in git stash' <<< "$out"

# Our folder in the Windows temp dir goes (same check as at the start)
case "$WSB" in /mnt/?/*/AppData/Local/Temp/olecharms-test) rm -rf "$WSB" ;; esac
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
