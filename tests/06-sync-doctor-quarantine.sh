#!/bin/bash
# QoL: sync, doctor checkout checks, daily doctor, quarantine + restore,
# paranoid HISTFILE/histories, plugin retirement, default-branch rename.
# Sandboxed HOME; git remotes are bare repos inside the sandbox.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home D=$SB/win/Downloads R=$SB/repo
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
export OLECHARMS_WIN_VIM_HOME=$SB/winhome GIT_CONFIG_NOSYSTEM=1 OLECHARMS_TEST_IGNORE_CTIME=1
unset XDG_DATA_HOME XDG_STATE_HOME ZSH ZSH_CUSTOM
OC="bash $R/olecharms.sh"
ST=$H/.local/state/olecharms
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$R/lib.sh'; detect_os; config_ensure >/dev/null; $1" 2>&1; }
gc() { git -c user.name=t -c user.email=t@t "$@"; }

echo "== A. config v3 → v4"
mkdir -p "$H/.config/olecharms"
printf 'CONFIG_VERSION=3\ndownloads_cleanup_enabled=false\nwindows_integration=off\n' > "$H/.config/olecharms/config"
lib 'true' >/dev/null
chk "daily_doctor=on added"                  grep -qx 'daily_doctor=on' "$H/.config/olecharms/config"
chk "quarantine days added"                  grep -qx 'downloads_cleanup_quarantine_days=30' "$H/.config/olecharms/config"
CV=$(sed -n 's/^CURRENT_CONFIG_VERSION=//p' "$R/olecharms.sh")
chk "current version ($CV)"                    grep -qx "CONFIG_VERSION=$CV" "$H/.config/olecharms/config"

echo "== B. olecharms sync"
gc -C "$R" init -q -b master && git -C "$R" add -A && gc -C "$R" commit -qm init
git init -q --bare "$SB/remote.git" && git -C "$R" remote add origin "$SB/remote.git" && git -C "$R" push -qu origin master 2>/dev/null
git clone -q "$SB/remote.git" "$SB/machineB"
printf "alias gsb='git status -sb'\n" > "$SB/machineB/global-aliases.sh"
git -C "$SB/machineB" add global-aliases.sh && gc -C "$SB/machineB" commit -qm "Add global alias gsb" && git -C "$SB/machineB" push -q 2>/dev/null
out=$($OC sync 2>&1)
chk "pulled the new commit"                  grep -q 'Add global alias gsb' <<< "$out"
chk "global alias file arrived"              grep -q 'alias gsb=' "$R/global-aliases.sh"
chk "local steps ran (loader written)"       test -f "$R/scripts/olecharms-shell.sh"
chk "loader loads it in zsh"                 test "$(zsh -c "source '$R/scripts/olecharms-shell.sh'; alias gsb")" = "gsb='git status -sb'"
chk "last pull recorded"                     grep -qE '^[0-9]+ [0-9a-f]+$' "$ST/last-pull"
out=$($OC sync 2>&1)
chk "second sync: already up to date"        grep -q 'Already up to date' <<< "$out"

echo "== C. doctor: checkout state"
dout=$($OC doctor 2>&1)
chk "tracking upstream ok"                   grep -q 'On master, tracking origin/master' <<< "$dout"
chk "last update recent"                     grep -q 'Last successful update 0 day' <<< "$dout"
echo x > "$R/LOCAL"; git -C "$R" add LOCAL; gc -C "$R" commit -qm local
echo y >> "$R/packages.conf"; git -C "$R" stash -q
git -C "$R" config credential.helper '/nonexistent/dir/git-credential\ thing.exe'
dout=$($OC doctor 2>&1)
chk "ahead warned"                           grep -q '1 local commit(s) not on origin/master' <<< "$dout"
chk "stash warned"                           grep -q 'git stash holds 1 entry' <<< "$dout"
chk "broken credential helper warned"        grep -qE '(no longer exists|Missing program): /nonexistent/dir/git-credential thing.exe' <<< "$dout"
git -C "$R" config --unset credential.helper; git -C "$R" stash drop -q; git -C "$R" reset -q --hard origin/master
git -C "$R" checkout -q -b nowhere
dout=$($OC doctor 2>&1)
chk "no upstream warned"                     grep -q 'nowhere tracks no remote branch' <<< "$dout"
git -C "$R" checkout -q master; git -C "$R" branch -q -D nowhere

echo "== D. daily doctor"
lib 'restore_scheduled_features' >/dev/null
chk "launcher generated"                     test -x "$R/scripts/doctor-daily.sh"
chk "hook runs it daily"                     grep -q 'doctor-daily.sh' "$R/scripts/olecharms-hook.sh"
chk "hook sourced from rc files"             grep -q 'olecharms-hook.sh' "$H/.zshrc"
mv "$R/scripts/olecharms-shell.sh" "$SB/loader.off"
bash "$R/scripts/doctor-daily.sh"; rc=$?
chk "quiet run prints nothing, rc!=0 ($rc)"  test "$rc" -ne 0
chk "problems file written"                  grep -q 'problem' "$ST/doctor.problems"
out=$(cd "$H" && zsh -c "source '$R/scripts/olecharms-hook.sh'" 2>&1)
chk "new shell mentions it ($out)"           grep -q '\[olecharms\] doctor: .*problem' <<< "$out"
$OC doctor --fix >/dev/null 2>&1
chk "fixed → loader no longer reported"     bash -c "! grep -q 'Shell loader' '$ST/doctor.problems' 2>/dev/null"
printf '4\n0\n' | $OC config >/dev/null 2>&1
chk "toggle off: launcher removed"           test ! -e "$R/scripts/doctor-daily.sh"
chk "toggle off: config says off"            grep -qx 'daily_doctor=off' "$H/.config/olecharms/config"
printf '4\n0\n' | $OC config >/dev/null 2>&1
chk "toggle on again"                        test -x "$R/scripts/doctor-daily.sh"

echo "== E. quarantine + restore"
lib 'config_set downloads_cleanup_action auto; enable_downloads_cleanup "$HOME/downloads" hook 30' >/dev/null
mkdir -p "$D/sub2"; echo a > "$D/qa.txt"; echo b > "$D/sub2/qb.txt"; touch -d '60 days ago' "$D/qa.txt" "$D/sub2/qb.txt"
out=$($OC cleanup --dry-run 2>&1)
chk "auto without trash = quarantine"        grep -q 'move to quarantine, restorable for 30 days' <<< "$out"
$OC cleanup --yes >/dev/null 2>&1
Q=$H/.local/share/olecharms/quarantine
batch=$(ls -d "$Q"/*-* 2>/dev/null | tail -1)
chk "files left the folder"                  test ! -e "$D/qa.txt" -a ! -e "$D/sub2/qb.txt"
chk "kept in a batch with their paths"       test -f "$batch/qa.txt" -a -f "$batch/sub2/qb.txt" -a -f "$batch/.origin"
chk "log says quarantined"                   grep -q '^quarant\. ' "$ST/cleanup.log"
echo "new one" > "$D/qa.txt"
printf '\n' | $OC cleanup --restore >/dev/null 2>&1
chk "restored sub2/qb.txt"                   test -f "$D/sub2/qb.txt"
chk "never overwrote the new qa.txt"         test "$(cat "$D/qa.txt")" = "new one"
chk "taken name stays in quarantine"         test -f "$batch/qa.txt"
rm -f "$D/qa.txt"; printf '\n' | $OC cleanup --restore >/dev/null 2>&1
chk "second restore brings it back"          test "$(cat "$D/qa.txt")" = a
chk "empty batch removed"                    test ! -d "$batch"
echo c > "$D/qc.txt"; touch -d '60 days ago' "$D/qc.txt"; $OC cleanup --yes >/dev/null 2>&1
old=$(ls -d "$Q"/*-* | tail -1); touch -d '40 days ago' "$old"
mkdir -p "$Q/not-a-batch" "$Q/20200101-000000"; echo keep > "$Q/not-a-batch/x"; echo keep > "$Q/20200101-000000/x"; touch -d '400 days ago' "$Q/not-a-batch" "$Q/20200101-000000"
$OC cleanup --yes >/dev/null 2>&1
chk "batch past 30 days purged"              test ! -d "$old"
chk "dir without .origin never purged"       test -f "$Q/20200101-000000/x"
chk "non-batch dir never purged"             test -f "$Q/not-a-batch/x"
chk "other fs → sibling folder" bash -c "source '$R/lib.sh'; fs_id() { case \"\$1\" in *quarantine*) echo 1;; *) echo 2;; esac; }; [ \"\$(cleanup_quarantine_base '$D')\" = '$SB/win/.olecharms-quarantine' ]"

echo "== F. paranoid: \$HISTFILE and other histories"
for f in .my_histfile .lesshst .python_history .node_repl_history .psql_history .wget-hsts notes.txt; do echo x > "$H/$f"; done
echo x > "$SB/outside_history"
lib 'enable_paranoid_mode hook' >/dev/null
P=$R/scripts/paranoid-cleanup.sh
grep -v '^TASKLIST=' "$P" | grep -q '/mnt/c' && { echo "ABORT: paranoid script mentions /mnt/c"; exit 1; }
chk "hook passes HISTFILE"                   grep -q 'paranoid-cleanup.sh.*HISTFILE' "$R/scripts/olecharms-hook.sh"
bash "$P" "$H/.my_histfile"
chk "custom HISTFILE removed"                test ! -e "$H/.my_histfile"
chk "tool histories removed"                 test ! -e "$H/.lesshst" -a ! -e "$H/.python_history" -a ! -e "$H/.node_repl_history" -a ! -e "$H/.psql_history" -a ! -e "$H/.wget-hsts"
bash "$P" "$SB/outside_history"; bash "$P" "$H/notes.txt"
chk "HISTFILE outside home kept"             test -e "$SB/outside_history"
chk "non-history name kept"                  test -e "$H/notes.txt"
lib 'disable_paranoid_mode' >/dev/null

echo "== G. retiring plugins dropped from packages.conf"
mkdir -p "$H/.vim/bundle"/{p1,p2,p3,p4,mine}
printf '%s\n' p1 p2 p3 p4 > "$ST/managed-plugins"
lib 'VIM_PLUGINS=("p1|u" "p2|u" "p3|u"); plugins_retire_unlisted' >/dev/null
chk "unlisted managed plugin moved"          test ! -d "$H/.vim/bundle/p4" -a -n "$(ls -d "$H"/.vim/bundle_disabled/p4.removed.* 2>/dev/null)"
chk "user's own plugin untouched"            test -d "$H/.vim/bundle/mine"
chk "managed list updated"                   test "$(cat "$ST/managed-plugins" | tr '\n' ' ')" = "p1 p2 p3 "
mkdir -p "$H/.vim/bundle"/{p4,p5}; printf '%s\n' p1 p2 p3 p4 p5 > "$ST/managed-plugins"
out=$(lib 'VIM_PLUGINS=("p1|u"); plugins_retire_unlisted')
chk "mass retirement refused"                grep -q 'not retiring them in one go' <<< "$out"
chk "  nothing moved"                        test -d "$H/.vim/bundle/p2" -a -d "$H/.vim/bundle/p5"

echo "== H. plugin follows upstream default-branch rename"
git init -q --bare "$SB/plugr.git"; git clone -q "$SB/plugr.git" "$SB/plugrw" 2>/dev/null
(cd "$SB/plugrw" && git checkout -q -b master && echo v1 > p.vim && git add p.vim && gc commit -qm v1 && git push -q origin master 2>/dev/null)
git -C "$SB/plugr.git" symbolic-ref HEAD refs/heads/master
git clone -q --depth 1 "file://$SB/plugr.git" "$H/.vim/bundle/rplug"
(cd "$SB/plugrw" && git checkout -q -b main && echo v2 > p.vim && gc commit -qam v2 && git push -q origin main 2>/dev/null)
# upstream switches its default to main; the old master stays behind, stale
git -C "$SB/plugr.git" symbolic-ref HEAD refs/heads/main
lib "clone_or_pull 'file://$SB/plugr.git' '$H/.vim/bundle/rplug' rplug" >/dev/null
chk "now on main"                            test "$(git -C "$H/.vim/bundle/rplug" symbolic-ref --short HEAD)" = main
chk "with the new content"                   grep -q v2 "$H/.vim/bundle/rplug/p.vim"
out=$(lib "clone_or_pull 'file://$SB/plugr.git' '$H/.vim/bundle/rplug' rplug")
# a second plugin whose old branch was deleted outright
git clone -q --depth 1 -b master "file://$SB/plugr.git" "$H/.vim/bundle/rplug3" 2>/dev/null
git -C "$SB/plugrw" push -q origin --delete master 2>/dev/null
chk "(old master really deleted upstream)"   bash -c "! git -C '$SB/plugr.git' rev-parse -q --verify refs/heads/master >/dev/null"
lib "clone_or_pull 'file://$SB/plugr.git' '$H/.vim/bundle/rplug3' rplug3" >/dev/null
chk "deleted-branch case also on main"       test "$(git -C "$H/.vim/bundle/rplug3" symbolic-ref --short HEAD)" = main
chk "next update: plain pull, no switch"     bash -c "! grep -q 'followed' <<< \"\$1\"" _ "$out"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
