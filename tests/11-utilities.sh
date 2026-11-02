#!/bin/bash
# The commands in bin/ and their links in ~/.local/bin, trash, running and
# murder, tryna, timer, jsonformat, url, line, scratch; tempe and wt; zoxide,
# fzf's file lists and mise in the loader; installing mise and tldr's pages.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home R=$SB/repo B=$SB/repo/bin L=$SB/home/.local/bin
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
export OLECHARMS_WIN_VIM_HOME=$SB/winhome GIT_CONFIG_NOSYSTEM=1
unset XDG_CURRENT_DESKTOP
bash -c "source '$R/lib.sh'; config_ensure >/dev/null; config_set windows_integration off; config_set daily_doctor off" >/dev/null 2>&1
grep -q '^windows_integration=off' "$H/.config/olecharms/config" || { echo "ABORT: could not disable Windows integration"; exit 1; }
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
plain() { sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'; }
lib() { bash -c "source '$R/lib.sh'; detect_os; config_ensure >/dev/null 2>&1; $1" 2>&1 | plain; }
OC="bash $R/olecharms.sh"
git config --global user.name tester; git config --global user.email t@t
mkdir -p "$SB/sys" "$SB/fake"
cd "$SB" || exit 1

echo "== 1. commands linked into ~/.local/bin"
lib 'install_bin_links' >/dev/null
chk "trash linked"                          test "$(readlink "$L/trash")" = "$B/trash"
chk "ssk linked"                            test "$(readlink "$L/ssk")" = "$B/ssk"
rm -f "$L/url"; echo mine > "$L/url"
lib 'install_bin_links' >/dev/null
chk "a file of yours with that name is kept" grep -qx mine "$L/url"
printf '#!/bin/sh\necho system-timer\n' > "$SB/sys/timer"; chmod +x "$SB/sys/timer"; rm -f "$L/timer"
PATH="$SB/sys:$PATH" lib 'install_bin_links' >/dev/null
chk "another program's name is not shadowed" test ! -e "$L/timer"
printf '#!/bin/sh\necho fdfind "$@"\n' > "$SB/sys/fdfind"; chmod +x "$SB/sys/fdfind"
rm -f "$L/fd"   # a host with fd-find already got fd → its own /usr/bin/fdfind above
PATH="$SB/sys:$PATH" lib 'install_bin_links' >/dev/null
chk "fd linked to Debian's fdfind"          test "$(readlink "$L/fd")" = "$SB/sys/fdfind"
ln -s /nonexistent/olecharms-old/bin/ssk "$L/ssk2" 2>/dev/null
ln -s /nonexistent/nvm/bin/node "$L/node"
rm -f "$L/trash"; ln -s "$SB/old-checkout/bin/trash" "$L/trash"
lib 'install_bin_links' >/dev/null
chk "link from a vanished checkout redone"  test "$(readlink "$L/trash")" = "$B/trash"
chk "a broken link of yours is left alone"  test -L "$L/node"
rm -f "$SB/sys/fdfind"
lib 'install_bin_links' >/dev/null
chk "shim whose program went away removed"  test "$(readlink "$L/fd")" != "$SB/sys/fdfind"
rm -f "$L/url" "$L/node" "$L/ssk2"
lib 'install_bin_links' >/dev/null
out=$($OC help 2>&1 | plain)
chk "help lists the commands"               bash -c 'grep -q "^  trash  *move files" <<< "$1" && grep -q "^  ssk  " <<< "$1"' _ "$out"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: commands section"              grep -q "In ~/.local/bin: .*trash" <<< "$out"

echo "== 2. trash"
T=$SB/work; mkdir -p "$T/dir/sub" "$T/other"; echo a > "$T/a.txt"; echo b > "$T/dir/sub/b.txt"; echo c > "$T/other/c.txt"
out=$("$L/trash" "$T/a.txt" "$T/dir" "$T/other/c.txt" 2>&1 | plain); rc=$?
chk "trash a file, a folder, one elsewhere (rc=$rc)" test ! -e "$T/a.txt" -a ! -e "$T/dir" -a ! -e "$T/other/c.txt"
Q=$H/.local/share/olecharms/quarantine
chk "into the quarantine (no desktop trash here)" grep -q "quarantine" <<< "$out"
chk "one batch per folder, never merged"    test "$(ls "$Q" | wc -l)" -eq 2
chk "folder kept whole"                     bash -c 'ls "$1"/*/dir/sub/b.txt >/dev/null 2>&1' _ "$Q"
chk "each batch knows where it came from"   bash -c 'cat "$1"/*/.origin | sort | tr "\n" " " | grep -qx "$2 $2/other "' _ "$Q" "$T"
out=$("$L/trash" --list 2>&1 | plain)
chk "--list shows the batches"              grep -q "2 items from" <<< "$out"
out=$(printf '\n' | script -qc "OLECHARMS_NO_FZF=1 $L/trash --restore" /dev/null 2>&1 | plain)
chk "--restore puts the newest batch back"  test -f "$T/other/c.txt"
ln -s "$T/other" "$T/link"
"$L/trash" "$T/link" >/dev/null 2>&1
chk "a symlink goes, not what it points to" test ! -L "$T/link" -a -f "$T/other/c.txt"
for v in "$H" "$R" / "$SB" . "$H/.." /etc/hostname /mnt/c /usr; do
    out=$("$L/trash" "$v" 2>&1); rc=$?
    chk "refused: $v (rc=$rc)"              bash -c '[ "$2" -ne 0 ] && grep -qE "refusing|no such" <<< "$1"' _ "$out" "$rc"
done
chk "home and checkout untouched"           test -d "$H/.config" -a -f "$R/olecharms.sh"
out=$("$L/trash" "$T/nope" 2>&1); rc=$?
chk "a missing file: error, rc 1"           test "$rc" -eq 1
chk "no args: usage, rc 1"                  bash -c '! "$1" >/dev/null 2>&1' _ "$L/trash"

echo "== 3. running and murder"
sleep 3001 & p1=$!
sleep 3001 & p2=$!
python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(3002)' & p3=$!
sleep 0.5
out=$("$L/running" "sleep 3001")
chk "running lists both"                    bash -c 'grep -q "^ *$2 " <<< "$1" && grep -q "^ *$3 " <<< "$1"' _ "$out" "$p1" "$p2"
chk "running does not list itself"          bash -c '! grep -q "running sleep" <<< "$1"' _ "$out"
out=$("$L/murder" "sleep 3001" </dev/null 2>&1); rc=$?
chk "a text matching two: refused without -y (rc=$rc)" bash -c '[ "$1" -ne 0 ] && kill -0 "$2" && grep -q "matches 2 processes" <<< "$3"' _ "$rc" "$p1" "$out"
"$L/murder" "$p1" >/dev/null 2>&1; sleep 0.5
chk "murder PID (TERM)"                     bash -c '! kill -0 "$1" 2>/dev/null' _ "$p1"
"$L/murder" -y "sleep 3001" >/dev/null 2>&1; sleep 0.5
chk "murder -y text"                        bash -c '! kill -0 "$1" 2>/dev/null' _ "$p2"
out=$("$L/murder" "$p3" 2>&1)
chk "one that ignores TERM and INT gets KILL" grep -q "Stopped $p3 (KILL)" <<< "$out"
out=$("$L/murder" 1 2>&1); rc=$?
chk "PID 1 refused"                         test "$rc" -ne 0
kill -9 "$p1" "$p2" "$p3" 2>/dev/null

echo "== 4. tryna, timer, jsonformat, url, line, scratch"
rm -f "$SB/count"
"$L/tryna" -d 0 -n 5 sh -c 'n=$(cat "$1" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$1"; [ $n -ge 3 ]' _ "$SB/count" 2>/dev/null; rc=$?
chk "tryna: succeeds on the 3rd try"        test "$rc" -eq 0 -a "$(cat "$SB/count")" = 3
out=$("$L/tryna" -d 0 -n 2 false 2>&1); rc=$?
chk "tryna -n 2: gives up, rc 1"            bash -c '[ "$2" -eq 1 ] && grep -q "gave up after 2 tries" <<< "$1"' _ "$out" "$rc"
out=$(OLECHARMS_NOTIFY=none "$L/timer" 1s tea 2>&1); rc=$?
chk "timer 1s rings and says it"            bash -c '[ "$2" -eq 0 ] && grep -q $'"'"'\a'"'"'"tea" <<< "$1"' _ "$out" "$rc"
"$L/timer" 5x >/dev/null 2>&1; rc=$?
chk "timer: bad duration, rc 2"             test "$rc" -eq 2
chk "jsonformat"                            test "$(echo '{"a":1}' | "$L/jsonformat" | tr -d ' \n')" = '{"a":1}'
chk "jsonformat: invalid JSON fails"        bash -c '! echo "{bad" | "$1" >/dev/null 2>&1' _ "$L/jsonformat"
out=$("$L/url" 'https://u:secret@ex.com:8443/a%20b?q=%C3%B1&x=#top')
chk "url: parts, decoded query, no password shown" bash -c 'grep -q "^host *ex.com" <<< "$1" && grep -q "q = ñ" <<< "$1" && grep -q "^port *8443" <<< "$1" && ! grep -q secret <<< "$1"' _ "$out"
chk "line 2"                                test "$(printf 'a\nb\nc\n' | "$L/line" 2)" = b
chk "line -1"                               test "$(printf 'a\nb\nc\n' | "$L/line" -1)" = c
chk "line 0 refused"                        bash -c '! printf "a\n" | "$1" 0 2>/dev/null' _ "$L/line"
out=$(EDITOR=true VISUAL= "$L/scratch" md 2>&1)
chk "scratch: an untouched file is not kept" test -z "$out"
out=$(EDITOR="sh -c 'echo note > \"\$1\"' _" VISUAL= "$L/scratch" md 2>&1)
chk "scratch: a written one is"             bash -c 'f=${1#Kept in }; [ -f "$f" ] && [ "${f##*.}" = md ]' _ "$out"

echo "== 5. tempe and wt"
out=$(bash -c "source '$R/shell/tempe.sh'; tempe proj >/dev/null; pwd")
chk "tempe: a new folder in the temp dir"   bash -c '[ -d "$1" ] && case "$1" in "${TMPDIR:-/tmp}"/proj.*) ;; *) exit 1 ;; esac' _ "$out"
chk "tempe: a name with / refused"          bash -c "source '$R/shell/tempe.sh'; ! tempe a/b 2>/dev/null"
P=$SB/proj; mkdir -p "$P"; (cd "$P" && git init -q -b main && echo 1 > f && git add f && git commit -qm one)
wt() { bash -c "cd '$1' && source '$R/shell/wt.sh' && ${2}" 2>&1; }
out=$(wt "$P" 'wt feat/x >/dev/null 2>&1 && pwd && git branch --show-current')
chk "wt feat/x: worktree next to the repo, on its branch" test "$out" = "$P.worktrees/feat-x"$'\n'"feat/x"
out=$(wt "$P.worktrees/feat-x" 'wt root && pwd')
chk "wt root: back to the main checkout"    test "$out" = "$P"
echo dirty > "$P.worktrees/feat-x/new.txt"
out=$(wt "$P" 'wt rm feat/x'); rc=$?
chk "wt rm refuses with untracked work"     bash -c '[ -f "$1/new.txt" ] && grep -q "kept" <<< "$2"' _ "$P.worktrees/feat-x" "$out"
(cd "$P.worktrees/feat-x" && git add new.txt && git commit -qm wip)
out=$(wt "$P" 'wt rm feat/x')
chk "wt rm: removed, unmerged branch kept"  bash -c '[ ! -d "$1" ] && grep -q "Kept branch feat/x" <<< "$2" && git -C "$3" show-ref --verify --quiet refs/heads/feat/x' _ "$P.worktrees/feat-x" "$out" "$P"
out=$(wt "$P" 'wt t2 >/dev/null; cd .. && cd "'"$P"'" && wt rm t2')
chk "wt rm: a merged branch is deleted"     bash -c 'grep -q "Deleted branch t2" <<< "$1"' _ "$out"
out=$(wt "$P" 'wt "-x"'); rc=$?
chk "wt: invalid name refused"              test "$rc" -ne 0

echo "== 6. loader: zoxide, fzf's lists, mise"
printf '#!/bin/sh\ncase "$1" in init) echo "j() { echo zoxide-j \\"\\$@\\"; }" ;; import) echo "$@" >> "%s/zoxide-import.log" ;; esac\n' "$SB" > "$SB/fake/zoxide"
printf '#!/bin/sh\n[ "$1" = activate ] && echo "export MISE_ACTIVE_FOR=$2"\n' > "$SB/fake/mise"
printf '#!/bin/sh\necho fd\n' > "$SB/fake/fd"
printf '#!/bin/sh\necho bat\n' > "$SB/fake/bat"
chmod +x "$SB/fake"/*
lib 'config_set zsh_extras on; install_shell_commands' >/dev/null
zx() { (cd "$H" && HOME=$H ZDOTDIR=$H PATH="$SB/fake:$PATH" "$@" 2>&1) | plain; }
out=$(zx zsh -ic 'j docs' </dev/null)
chk "j comes from zoxide"                   grep -q "zoxide-j docs" <<< "$out"
out=$(zx zsh -ic 'echo "mise=$MISE_ACTIVE_FOR"' </dev/null)
chk "mise activated, even without a terminal" grep -q "mise=zsh" <<< "$out"
lib 'config_set mise off; install_shell_commands' >/dev/null
out=$(zx zsh -ic 'echo "mise=$MISE_ACTIVE_FOR"' </dev/null)
chk "mise off: not activated"               grep -qx "mise=" <<< "$out"
lib 'config_set mise on; install_shell_commands' >/dev/null
echo 'echo "D=$FZF_DEFAULT_COMMAND|A=$FZF_ALT_C_COMMAND|T=$FZF_CTRL_T_OPTS"' > "$SB/show-fzf.sh"
out=$(zx script -qc "zsh -ic 'source $SB/show-fzf.sh'" /dev/null </dev/null | grep '^D=')
chk "fzf lists with fd, previews with bat"  bash -c 'grep -q "^D=fd --type f --hidden --exclude .git|A=fd --type d" <<< "$1" && grep -q "T=--preview .bat --color" <<< "$1"' _ "$out"
out=$(FZF_DEFAULT_COMMAND="mine" zx script -qc "zsh -ic 'source $SB/show-fzf.sh'" /dev/null </dev/null | grep '^D=')
chk "your own FZF_DEFAULT_COMMAND is kept"  grep -q "^D=mine|" <<< "$out"
mkdir -p "$H/.local/share/autojump"; printf '10\t/somewhere\n' > "$H/.local/share/autojump/autojump.txt"
PATH="$SB/fake:$PATH" lib 'zoxide_import_autojump; zoxide_import_autojump' >/dev/null
chk "autojump's folders imported, once"     test "$(cat "$SB/zoxide-import.log")" = "import --from autojump --merge $H/.local/share/autojump/autojump.txt"

echo "== 7. installing mise (checksum checked) and tldr's pages"
REL=$SB/rel/v2026.1.1; mkdir -p "$REL"
arch=x64; case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; esac
printf '#!/bin/sh\necho "2026.1.1 linux-%s"\n' "$arch" > "$REL/mise-v2026.1.1-linux-$arch"
( cd "$REL" && sha256sum "mise-v2026.1.1-linux-$arch" | sed 's/  /  .\//' > SHASUMS256.txt )
export OLECHARMS_MISE_TAG=v2026.1.1 OLECHARMS_MISE_BASE="file://$SB/rel"
out=$(lib 'install_mise')
chk "mise installed into ~/.local/bin"      bash -c '[ -x "$1/mise" ] && "$1/mise" --version | grep -q 2026.1.1' _ "$L"
chk "its version recorded"                  test "$(cat "$H/.local/state/olecharms/mise-version")" = v2026.1.1
rm -rf "$SB/rel"
out=$(lib 'install_mise')
chk "same release: nothing downloaded"      test -z "$out"
mkdir -p "$SB/rel/v2026.2.0"
printf '#!/bin/sh\necho evil\n' > "$SB/rel/v2026.2.0/mise-v2026.2.0-linux-$arch"
echo "0000000000000000000000000000000000000000000000000000000000000000  ./mise-v2026.2.0-linux-$arch" > "$SB/rel/v2026.2.0/SHASUMS256.txt"
out=$(OLECHARMS_MISE_TAG=v2026.2.0 lib 'install_mise')
chk "a wrong checksum: refused, old mise kept" bash -c 'grep -q "does not match" <<< "$1" && "$2/mise" --version | grep -q 2026.1.1' _ "$out" "$L"
rm -f "$L/mise" "$H/.local/state/olecharms/mise-version"
printf '#!/bin/sh\necho other\n' > "$SB/sys/mise"; chmod +x "$SB/sys/mise"
out=$(PATH="$SB/sys:$PATH" OLECHARMS_MISE_TAG=v2026.2.0 lib 'install_mise')
chk "a mise installed another way: left alone" bash -c '[ ! -e "$1/mise" ] && [ -z "$2" ]' _ "$L" "$out"
rm -f "$SB/sys/mise"
unset OLECHARMS_MISE_TAG OLECHARMS_MISE_BASE
printf '#!/bin/sh\ncase "$1" in --version) echo "tealdeer 1.6.1" ;; --update) echo updated >> "%s/tldr.log" ;; esac\n' "$SB" > "$SB/fake/tldr"; chmod +x "$SB/fake/tldr"
PATH="$SB/fake:$PATH" lib 'tldr_cache_update' >/dev/null
chk "tldr (tealdeer) pages downloaded"      grep -qx updated "$SB/tldr.log"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
