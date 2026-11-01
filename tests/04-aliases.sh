#!/bin/bash
# aliaslast + global aliases. Sandboxed HOME; the "remote" is a bare repo in
# the sandbox, so nothing reaches the real checkout or GitHub.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home R=$SB/repo
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
export OLECHARMS_WIN_VIM_HOME=$SB/winhome GIT_CONFIG_NOSYSTEM=1
unset XDG_DATA_HOME XDG_STATE_HOME ZSH ZSH_CUSTOM HISTFILE
OC="bash $R/olecharms.sh"
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$R/lib.sh'; $1" 2>&1; }
bash -c "source '$R/lib.sh'; config_ensure; config_set windows_integration off" >/dev/null 2>&1
lget() { lib "alias_get '$1' ${2:+\"\$GLOBAL_ALIAS_FILE\"}"; }

SNAP=$SB/snap; mkdir -p "$SNAP"
printf '%s\0' 'git status' 'ls -la' $'for i in 1\ndo echo $i\ndone' 'git status' 'docker compose up -d' 'olecharms aliaslast' > "$SNAP/history.nul"
printf "%s\n" "alias gst='git status'" "alias -g ...=../.." "alias -- -='cd -'" > "$SNAP/aliases"
printf "%s\n" mkcd take > "$SNAP/functions"
printf "%s\n" cd print if > "$SNAP/builtins"
export OLECHARMS_SHELL_SNAPSHOT=$SNAP

echo "== A. history parsing (zsh snapshot, bash fc, history file)"
out=$(lib aliaslast_history)
chk "zsh: dedupe, drop multi-line + aliaslast ($(echo $out | tr '\n' '|'))" test "$out" = $'ls -la\ngit status\ndocker compose up -d'
mkdir -p "$SB/snapb"; printf '1\t git status\n2\t for i in 1\ndo echo\ndone\n3\t make test\n4*\t echo  x  \n' > "$SB/snapb/history.fc"
out=$(OLECHARMS_SHELL_SNAPSHOT=$SB/snapb lib aliaslast_history)
chk "bash fc: ($(echo $out | tr '\n' '|'))" test "$out" = $'git status\nmake test\necho  x'
printf ': 1700000000:0;echo hola\n: 1700000001:0;for i in 1\\\ndo x\\\ndone\n: 1700000002:0;npm run build\n' > "$H/.zsh_history"
out=$(OLECHARMS_SHELL_SNAPSHOT= HISTFILE=$H/.zsh_history lib aliaslast_history)
chk "history file fallback ($(echo $out | tr '\n' '|'))" test "$out" = $'echo hola\nnpm run build'

echo "== B. pick default (last) and save locally (no git upstream: no global question)"
out=$(printf '\ndcu\n' | $OC aliaslast 2>&1); echo "$out" | grep -E 'Command|saved|global' | sed 's/^/    /'
chk "dcu saved"                         test "$(lget dcu)" = "docker compose up -d"
chk "no global question without git"    bash -c "! grep -q 'Make' <<< \"\$1\"" _ "$out"

echo "== C. name checks: shell alias, function, builtin, command, own alias, invalid"
out=$(printf '1\ngst\nn\nmkcd\nn\ncd\nn\nls\nn\ndcu\nn\n1abc\nlla\n' | $OC aliaslast 2>&1)
chk "omz-style shell alias reported"    grep -q "'gst' is already an alias in your shell (oh-my-zsh or your rc files): git status" <<< "$out"
chk "function reported"                 grep -q "'mkcd' is a shell function" <<< "$out"
chk "builtin reported"                  grep -q "'cd' is a shell builtin or keyword" <<< "$out"
chk "command on PATH reported"          grep -qE "'ls' is a command: /(usr/)?bin/ls" <<< "$out"
chk "own alias reported"                grep -q "'dcu' is already one of your aliases on this machine: docker compose up -d" <<< "$out"
chk "invalid name rejected"             grep -q 'Invalid alias name: 1abc' <<< "$out"
chk "lla saved with 'ls -la'"           test "$(lget lla)" = "ls -la"
chk "gst not created"                   test -z "$(lget gst)"
out=$(printf '2\ngst\ny\n' | $OC aliaslast 2>&1)
chk "'use anyway' creates it"           test "$(lget gst)" = "git status"
out=$(printf '\n\n' | $OC aliaslast 2>&1)
chk "empty name cancels"                grep -q Cancelled <<< "$out"

echo "== D. global aliases through git (bare remote in the sandbox)"
git -C "$R" init -q -b master && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm init
git init -q --bare "$SB/remote.git" && git -C "$R" remote add origin "$SB/remote.git" && git -C "$R" push -qu origin master 2>/dev/null
out=$(printf '\ngdc\ny\n' | $OC aliaslast 2>&1)
chk "no git identity → error, kept local" grep -q 'git has no identity' <<< "$out"
chk "  gdc saved locally"                 test "$(lget gdc)" = "docker compose up -d"
git -C "$R" config user.name Tester; git -C "$R" config user.email tester@example.com
out=$(printf '\ngdc\ny\ny\n' | $OC aliaslast 2>&1); echo "$out" | grep -E 'global|Checking|Updating' | sed 's/^/    /'
chk "global alias in repo file"         test "$(lget gdc g)" = "docker compose up -d"
chk "local copy dropped"                test -z "$(lget gdc)"
chk "pushed to remote"                  bash -c "git -C '$SB/remote.git' show master:global-aliases.sh | grep -q \"alias gdc='docker compose up -d'\""
chk "commit touches only that file"     test "$(git -C "$R" show --name-only --format= HEAD)" = global-aliases.sh
chk "commit message"                    test "$(git -C "$R" log -1 --format=%s)" = "Add global alias gdc"
chk "loader loads global aliases (zsh)" test "$(zsh -c "source '$R/scripts/olecharms-shell.sh' 2>/dev/null || { bash -c \"source '$R/lib.sh'; install_shell_commands\" >/dev/null; source '$R/scripts/olecharms-shell.sh'; }; alias gdc")" = "gdc='docker compose up -d'"
git clone -q "$SB/remote.git" "$SB/machineB"
chk "machine B gets it from the remote" grep -q "alias gdc=" "$SB/machineB/global-aliases.sh"
lib 'alias_set gdc "echo local"' >/dev/null
chk "per-machine wins over global"      test "$(zsh -c "source '$R/scripts/olecharms-shell.sh'; alias gdc")" = "gdc='echo local'"
lout=$($OC alias list 2>&1)
chk "list marks global overridden here" grep -q 'overridden here' <<< "$lout"
lib 'alias_unset gdc' >/dev/null

echo "== E. no push access → instructions, wait, retry until it works"
git -C "$R" remote set-url --push origin "$SB/nope.git"
( sleep 4; git -C "$R" remote set-url --push origin "$SB/remote.git" ) &
out=$( { printf '1\ngls\ny\n'; sleep 1; printf '\n'; sleep 5; printf '\n'; } | $OC aliaslast 2>&1); wait
echo "$out" | grep -E 'cannot push|SSH|Press Enter|Checking again' | head -4 | sed 's/^/    /'
chk "says it cannot push"               grep -q 'This machine cannot push to' <<< "$out"
chk "shows how to grant access"         grep -q "SSH key write access" <<< "$out"
chk "retried and published"             bash -c "git -C '$SB/remote.git' show master:global-aliases.sh | grep -q 'alias gls='"
git -C "$R" remote set-url --push origin "$SB/nope.git"
out=$(printf '1\ngl2\ny\nl\n' | $OC aliaslast 2>&1)
chk "'l' keeps it on this machine"      test "$(lget gl2)" = "ls -la"
chk "  and says so"                     grep -q "Saving 'gl2' on this machine only" <<< "$out"
git -C "$R" remote set-url --push origin "$SB/remote.git"

echo "== F. unpushed local commits are not pushed without asking"
echo x >> "$R/LOCALWORK"; git -C "$R" add LOCALWORK; git -C "$R" commit -qm "local work"
out=$(printf '1\ngl3\ny\nn\n' | $OC aliaslast 2>&1)
chk "warns about the local commit"      grep -q '1 local commit(s) not on origin/master' <<< "$out"
chk "remote untouched"                  bash -c "! git -C '$SB/remote.git' log master --format=%s | grep -q 'local work'"
chk "fell back to local"                test "$(lget gl3)" = "ls -la"
git -C "$R" reset -q --hard HEAD~1

echo "== G. alias add --global / delete global"
out=$(printf 'y\n' | $OC alias add --global hi echo hola 2>&1)
chk "add --global published"            bash -c "git -C '$SB/remote.git' show master:global-aliases.sh | grep -q \"alias hi='echo hola'\""
out=$(printf 'y\n' | $OC alias delete hi 2>&1)
chk "delete global removes it remotely" bash -c "! git -C '$SB/remote.git' show master:global-aliases.sh | grep -q 'alias hi='"
chk "commit message for removal"        test "$(git -C "$SB/remote.git" log -1 --format=%s master)" = "Remove global alias hi"

echo "== H. real interactive shells: arrow-key picker + wrapper"
unset OLECHARMS_SHELL_SNAPSHOT
lib 'install_shell_commands' >/dev/null
for sh in zsh bash; do
    rm -f "$SB/ed-$sh"
    if [ $sh = zsh ]; then cmd="zsh -i"; else cmd="bash --rcfile $H/.bashrc -i"; fi
    { sleep 1.5; printf 'echo uno\r'; sleep 0.4; printf 'echo dos\r'; sleep 0.4; printf 'olecharms aliaslast\r'; sleep 2.5
      printf '\033[A'; sleep 0.4; printf '\r'; sleep 0.6; printf 'e1%s\r' $sh; sleep 1; printf '\r'; sleep 1.5
      printf 'alias e1%s > %s\r' $sh "$SB/ed-$sh"; sleep 0.6; printf 'exit\r'; sleep 0.3; } \
      | (cd "$H" && ZDOTDIR=$H HISTSIZE=100 script -qc "$cmd" "$SB/typescript-$sh" >/dev/null 2>&1)
    chk "$sh: picked 'echo uno' with ↑, alias usable in the same shell ($(cat "$SB/ed-$sh" 2>/dev/null))" grep -q 'echo uno' "$SB/ed-$sh"
    chk "$sh: cursor shown again" grep -q $'\033\\[?25h' "$SB/typescript-$sh"
done

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
