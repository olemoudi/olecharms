#!/bin/bash
# Deletion safety: every destructive path must stay inside what it owns.
# Sandboxed HOME. Real system paths are only ever used with --dry-run.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home D=$SB/win/Downloads R=$SB/repo
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
export OLECHARMS_WIN_VIM_HOME=$SB/winhome GIT_CONFIG_NOSYSTEM=1
unset XDG_DATA_HOME XDG_STATE_HOME ZSH ZSH_CUSTOM OLECHARMS_TEST_IGNORE_CTIME
OC="bash $R/olecharms.sh"
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$R/lib.sh'; detect_os; config_ensure >/dev/null; $1" 2>&1; }
lib 'config_set windows_integration off; config_set downloads_cleanup_action delete' >/dev/null
setdir() { lib "config_set downloads_cleanup_enabled true; config_set downloads_cleanup_dir '$1'; config_set downloads_cleanup_max_age_days 30" >/dev/null; }

echo "== A. what arrives with an old mtime stays (ctime is recent)"
setdir "$H/downloads"
touch -d '400 days ago' "$D/extracted-from-zip.pdf"
$OC cleanup --yes >/dev/null 2>&1
chk "old-mtime, fresh-ctime file kept"      test -e "$D/extracted-from-zip.pdf"
chk "nothing else removed either"           test -e "$D/old1.zip"
out=$(OLECHARMS_TEST_IGNORE_CTIME=1 $OC cleanup --dry-run 2>&1)
chk "(control: with ctime ignored it would match)" grep -q 'extracted-from-zip.pdf' <<< "$out"

echo "== B. git checkouts, symlinks and olecharms itself are never touched"
export OLECHARMS_TEST_IGNORE_CTIME=1
mkdir -p "$D/project/src" "$D/project/.git/objects/ab" "$SB/outside"
echo x > "$D/project/src/main.c"; echo x > "$D/project/.git/objects/ab/cdef"; echo x > "$D/project/.git/HEAD"
touch -d '400 days ago' "$D/project/src/main.c" "$D/project/.git/objects/ab/cdef" "$D/project/.git/HEAD"
mkdir -p "$D/project/.git/refs/tags"; touch -d '400 days ago' "$D/project/.git/refs/tags"
echo x > "$SB/outside/precious.doc"; touch -d '400 days ago' "$SB/outside/precious.doc"
ln -s "$SB/outside" "$D/link-to-outside"; ln -s "$SB/outside/precious.doc" "$D/file-link.doc"
touch -d '400 days ago' "$D/loose-old.txt"
$OC cleanup --yes >/dev/null 2>&1
chk "loose old file removed (control)"      test ! -e "$D/loose-old.txt"
chk "file in git work tree kept"            test -e "$D/project/src/main.c"
chk "git objects kept"                      test -e "$D/project/.git/objects/ab/cdef" -a -e "$D/project/.git/HEAD"
chk "empty dir inside .git kept"            test -d "$D/project/.git/refs/tags"
chk "file behind a symlinked dir kept"      test -e "$SB/outside/precious.doc"
chk "symlinks themselves kept"              test -L "$D/link-to-outside" -a -L "$D/file-link.doc"

echo "== C. dangerous folders are refused (no deletion, exit 1)"
mkdir -p "$H/.ssh"; echo key > "$H/.ssh/id_x"; touch -d '400 days ago' "$H/.ssh/id_x"
echo h > "$H/old-home-file"; touch -d '400 days ago' "$H/old-home-file"
touch -d '400 days ago' "$R/README.md" 2>/dev/null || { echo r > "$R/README.md"; touch -d '400 days ago' "$R/README.md"; }
for dir in "$H" "$SB" "$H/.ssh" "$R" "$R/vimthings" "$H/.config"; do
    setdir "$dir"
    $OC cleanup --yes >/dev/null 2>&1; rc=$?
    chk "refused: ${dir#$S/} (rc=$rc)"        test "$rc" -ne 0
done
chk "home file survived"                    test -e "$H/old-home-file"
chk "ssh key survived"                      test -e "$H/.ssh/id_x"
chk "checkout file survived"                test -e "$R/README.md"
for dir in / /home /usr /etc /mnt/c /mnt/c/Users "$(win_profile)" /mnt/c/Windows "/mnt/c/Program Files"; do
    [ -d "$dir" ] || continue
    setdir "$dir"
    out=$($OC cleanup --dry-run 2>&1); rc=$?
    chk "dry-run refuses real $dir"           bash -c "[ $rc -ne 0 ] && grep -q 'protected location' <<< \"\$1\"" _ "$out"
done
setdir "$H/downloads"

echo "== D. invalid plugin names never reach rm -rf / rsync --delete"
mkdir -p "$H/.vim/bundle/keepme" "$SB/winhome/vimfiles/bundle/userplugin"
echo k > "$H/.vim/bundle/keepme/plugin.vim"; echo u > "$SB/winhome/vimfiles/bundle/userplugin/x.vim"
out=$(lib 'VIM_PLUGINS=("|https://example.invalid/x.git" "../evil|https://example.invalid/y.git" ".|z"); install_plugins; win_sync_plugins "$OLECHARMS_WIN_VIM_HOME/vimfiles/bundle"')
chk "invalid names reported"                grep -q "Invalid plugin name" <<< "$out"
chk "~/.vim/bundle untouched"               test -e "$H/.vim/bundle/keepme/plugin.vim"
chk "no bundle_disabled move"               test ! -d "$H/.vim/bundle_disabled"
chk "Windows user plugin untouched"         test -e "$SB/winhome/vimfiles/bundle/userplugin/x.vim"
chk "mirror_dir refuses bundle/ itself"     bash -c "source '$R/lib.sh'; ! mirror_dir '$H/.vim/bundle/keepme' '$SB/winhome/vimfiles/bundle'"
chk "  and it is intact"                    test -e "$SB/winhome/vimfiles/bundle/userplugin/x.vim"

echo "== E. plugin with local edits is not reset --hard"
git init -q --bare "$SB/plug.git"; git clone -q "$SB/plug.git" "$SB/plugwork" 2>/dev/null
(cd "$SB/plugwork" && echo v1 > p.vim && git add p.vim && git -c user.name=t -c user.email=t@t commit -qm v1 && git push -q origin HEAD:master 2>/dev/null)
git clone -q "$SB/plug.git" "$H/.vim/bundle/myplug"
echo "my tweak" >> "$H/.vim/bundle/myplug/p.vim"
(cd "$SB/plugwork" && echo v2 > p.vim && git -c user.name=t -c user.email=t@t commit -qam v2 && git push -q origin HEAD:master 2>/dev/null)
lib "clone_or_pull '$SB/plug.git' '$H/.vim/bundle/myplug' myplug" >/dev/null
chk "local tweak still there"               grep -q 'my tweak' "$H/.vim/bundle/myplug/p.vim"

echo "== F. checkout_pull never destroys local work"
git -C "$R" init -q -b master && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init
git init -q --bare "$SB/remote.git" && git -C "$R" remote add origin "$SB/remote.git" && git -C "$R" push -qu origin master 2>/dev/null
git clone -q "$SB/remote.git" "$SB/other"
(cd "$SB/other" && echo "upstream line" >> packages.conf && git -c user.name=t -c user.email=t@t commit -qam up && git push -q 2>/dev/null)
echo "my local line" >> "$R/packages.conf"
out=$(lib 'checkout_pull; echo rc=$?')
chk "conflict reported as set aside"        grep -q 'set aside in git stash' <<< "$out"
chk "no conflict markers left"              bash -c "! grep -q '<<<<<<<' '$R/packages.conf'"
chk "local change safe in stash"            bash -c "git -C '$R' stash show -p | grep -q 'my local line'"
git -C "$R" stash drop -q
# a merge in progress is left alone
(cd "$SB/other" && echo "upstream 2" >> README.md 2>/dev/null; git -C "$SB/other" add -A; git -C "$SB/other" -c user.name=t -c user.email=t@t commit -qm up2; git -C "$SB/other" push -q 2>/dev/null)
echo "local wip" > "$R/wip.txt"; git -C "$R" add wip.txt; git -C "$R" -c user.name=t -c user.email=t@t commit -qm wip
git -C "$R" checkout -q -b side HEAD~1; echo side > "$R/wip.txt"; git -C "$R" add wip.txt; git -C "$R" -c user.name=t -c user.email=t@t commit -qm side
git -C "$R" checkout -q master; git -C "$R" -c user.name=t -c user.email=t@t merge side >/dev/null 2>&1
echo "my resolution in progress" > "$R/wip.txt"
out=$(lib 'checkout_pull; echo rc=$?')
chk "merge in progress: refused"            grep -q 'merge or rebase in progress' <<< "$out"
chk "  resolution untouched"                grep -q 'my resolution in progress' "$R/wip.txt"
git -C "$R" merge --abort 2>/dev/null

echo "== G. paranoid: symlinked undodir → home is not emptied"
mkdir -p "$H/.vim/swapfiles"; rm -rf "$H/.vim/undodir"; ln -s "$H" "$H/.vim/undodir"
echo keep > "$H/precious.txt"
lib 'enable_paranoid_mode hook' >/dev/null
P=$R/scripts/paranoid-cleanup.sh
grep -q '/mnt/c' "$P" && { echo "ABORT: paranoid script mentions /mnt/c"; exit 1; }
bash "$P"
chk "home file kept"                        test -e "$H/precious.txt"
chk "~/.ssh kept"                           test -e "$H/.ssh/id_x"
lib 'disable_paranoid_mode' >/dev/null

echo "== H. aliaslast snapshot removal only takes its own files"
mkdir -p "$SB/olecharms.trap"; echo mine > "$SB/olecharms.trap/notes.txt"; printf 'x\0' > "$SB/olecharms.trap/history.nul"
printf '\n' | OLECHARMS_SHELL_SNAPSHOT="$SB/olecharms.trap" $OC aliaslast >/dev/null 2>&1
chk "foreign file in a look-alike dir kept" test -e "$SB/olecharms.trap/notes.txt"
chk "its own snapshot file removed"         test ! -e "$SB/olecharms.trap/history.nul"

echo "== I. mass-removal brake (second guard)"
export OLECHARMS_TEST_IGNORE_CTIME=1
setdir "$H/downloads"
lib 'enable_downloads_cleanup "$HOME/downloads" hook 30' >/dev/null
lib 'config_set downloads_cleanup_action delete' >/dev/null
mkdir -p "$D/bulk"; for i in $(seq 1 350); do : > "$D/bulk/f$i"; done; touch -d '90 days ago' "$D"/bulk/f*
CS=$R/scripts/cleanup-downloads.sh
bash "$CS"
chk "scheduled run held 350 files"          test "$(ls "$D/bulk" | wc -l)" -eq 350
chk "held marker written"                   grep -q '350 files' "$H/.local/state/olecharms/cleanup.held"
chk "log says held"                         grep -q 'scheduled: held' "$H/.local/state/olecharms/cleanup.log"
out=$(cd "$H" && zsh -c "source '$R/scripts/olecharms-hook.sh'" 2>&1)
chk "new shell shows the hold notice"       grep -q 'Downloads cleanup on hold: 350 files' <<< "$out"
dout=$($OC doctor 2>&1)
chk "doctor shows the hold"                 grep -q 'On hold: 350 files' <<< "$dout"
$OC cleanup --yes >/dev/null 2>&1; rc=$?
chk "--yes alone refused (rc=$rc)"          test "$rc" -ne 0 -a "$(ls "$D/bulk" | wc -l)" -eq 350
{ sleep 2; printf '349\r'; sleep 2; } | script -qc "bash $R/olecharms.sh cleanup" "$SB/ts-wrong" >/dev/null 2>&1
chk "wrong typed count cancels"             test "$(ls "$D/bulk" | wc -l)" -eq 350
n=$(OLECHARMS_TEST_IGNORE_CTIME=1 bash -c "source '$R/lib.sh'; detect_os; l=\$(mktemp); cleanup_collect '$D' 30 \$l; cleanup_count \$l")
{ sleep 2; printf '%s\r' "$n"; sleep 4; } | script -qc "bash $R/olecharms.sh cleanup" "$SB/ts-right" >/dev/null 2>&1
chk "typed count ($n) confirms"             test ! -d "$D/bulk"
chk "hold cleared"                          test ! -e "$H/.local/state/olecharms/cleanup.held"
mkdir -p "$D/half"; for i in $(seq 1 25); do : > "$D/half/old$i"; done; touch -d '90 days ago' "$D"/half/old*
for i in $(seq 1 5); do : > "$D/half/new$i"; done
rm -f "$LASTRUN" "$R/scripts/.last-run/downloads-cleanup"; bash "$CS"
chk "over half the folder is held too"      test "$(ls "$D/half" | grep -c old)" -eq 25
$OC cleanup --yes --force >/dev/null 2>&1
chk "--yes --force removes it"              test "$(ls "$D/half" | grep -c old)" -eq 0 -a "$(ls "$D/half" | grep -c new)" -eq 5

echo "== J. per-file verification right before removal (second guard)"
mkdir -p "$SB/elsewhere"; echo x > "$SB/elsewhere/victim"; echo x > "$D/target"; ln -s "$SB/elsewhere/victim" "$D/alink"
printf '%s\0' "$SB/elsewhere/victim" "$D/alink" "$D/../elsewhere/victim" "$D/project/.git/HEAD" "$D/target" > "$SB/badlist"
log=$SB/verify.log; : > "$log"
res=$(lib "CLEANUP_PROTECT=''; cleanup_apply '$SB/badlist' delete '$log' '$D'")
chk "file outside the folder kept"          test -e "$SB/elsewhere/victim"
chk "symlink kept"                          test -L "$D/alink"
chk "file in .git kept"                     test -e "$D/project/.git/HEAD"
chk "legit file removed ($res)"             test ! -e "$D/target"
chk "skips logged with reasons"             test "$(grep -c '^skipped' "$log")" -eq 4

echo "== K. paranoid only deletes vim's own file names (second guard)"
rm -f "$H/.vim/undodir"; mkdir -p "$H/.vim/undodir" "$H/.vim/swapfiles"
echo n > "$H/.vim/undodir/notes.txt"; echo u > "$H/.vim/undodir/%home%ole%a.txt"
echo n > "$H/.vim/swapfiles/keep.md"; echo s > "$H/.vim/swapfiles/a.txt.swp"; echo s > "$H/.vim/swapfiles/%x%y.swo"
mkdir -p "$H/.vim/undodir/sub"; echo d > "$H/.vim/undodir/sub/%deep"
lib 'enable_paranoid_mode hook' >/dev/null; grep -q '/mnt/c' "$P" && { echo "ABORT"; exit 1; }
bash "$P"
chk "undo file removed"                     test ! -e "$H/.vim/undodir/%home%ole%a.txt"
chk "swap files removed"                    test ! -e "$H/.vim/swapfiles/a.txt.swp" -a ! -e "$H/.vim/swapfiles/%x%y.swo"
chk "other files in undodir kept"           test -e "$H/.vim/undodir/notes.txt"
chk "other files in swapfiles kept"         test -e "$H/.vim/swapfiles/keep.md"
chk "subfolders not descended"              test -e "$H/.vim/undodir/sub/%deep"
lib 'disable_paranoid_mode' >/dev/null

echo "== L. clone_or_pull refuses anything but a plugin folder (second guard)"
mkdir -p "$SB/notaplugin"; echo x > "$SB/notaplugin/data"
lib "clone_or_pull 'https://example.invalid/x.git' '$SB/notaplugin' x" >/dev/null
chk "outside bundle/: untouched"            test -e "$SB/notaplugin/data"
lib "clone_or_pull 'https://example.invalid/x.git' '$H/.vim/bundle/' x" >/dev/null
chk "bundle/ itself: untouched"             test -e "$H/.vim/bundle/keepme/plugin.vim"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
