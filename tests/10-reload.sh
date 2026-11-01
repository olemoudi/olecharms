#!/bin/bash
# Reloading the terminal after update / sync / doctor --fix / config: the
# loader's load time, stale detection, the final notice, and the shell
# function's offer in real interactive zsh and bash.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home R=$SB/repo
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
export OLECHARMS_WIN_VIM_HOME=$SB/winhome
bash -c "source '$R/lib.sh'; config_ensure >/dev/null; config_set windows_integration off; config_set daily_doctor off" >/dev/null 2>&1
grep -q '^windows_integration=off' "$H/.config/olecharms/config" || { echo "ABORT: could not disable Windows integration"; exit 1; }
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$R/lib.sh'; config_ensure >/dev/null 2>&1; $1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
plain() { sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'; }
OC="bash $R/olecharms.sh"
L=$R/scripts/olecharms-shell.sh
NOTICE="previous shell configuration: run 'exec zsh'"
lib 'install_shell_commands' >/dev/null
$OC sync --local >/dev/null 2>&1   # settle: hook, launchers, RC lines

echo "== 1. the loader records when the shell read its configuration"
for sh in zsh bash; do
    v=$($sh -c ". '$L'; echo \$_olecharms_loaded_at" 2>&1)
    chk "$sh: load time in epoch seconds ($v)" bash -c '[[ $1 =~ ^[0-9]{10}$ ]] && [ $(( $(date +%s) - $1 )) -lt 60 ]' _ "$v"
done

echo "== 2. generated files keep their date when unchanged"
touch -d '3 days ago' "$L" "$R/scripts/olecharms-hook.sh" 2>/dev/null
m1=$(stat -c %Y "$L")
lib 'install_shell_commands; sync_shell_hook' >/dev/null
chk "loader not rewritten when identical"   test "$(stat -c %Y "$L")" = "$m1"
lib 'GENERATOR_VERSION=999; install_shell_commands' >/dev/null
chk "rewritten when its content changes"     test "$(stat -c %Y "$L")" != "$m1"
lib 'install_shell_commands' >/dev/null

echo "== 3. stale or not, against the shell's load time"
sleep 1; LA=$(date +%s); sleep 1
out=$(OLECHARMS_SHELL_LOADED_AT=$LA $OC sync --local 2>&1 | plain)
chk "nothing changed since → no notice"     bash -c '! grep -q "previous shell configuration" <<< "$1"' _ "$out"
touch "$R/shell/mkcd.sh"
out=$(OLECHARMS_SHELL_LOADED_AT=$LA $OC sync --local 2>&1 | plain)
chk "a shell/ file changed since → notice"  grep -q "$NOTICE" <<< "$out"
chk "the notice comes last"                  bash -c 'tail -n 2 <<< "$1" | head -n 1 | grep -q "previous shell configuration"' _ "$out"
echo "export X_TOKEN='x'" > "$H/.config/olecharms/secrets"; chmod 600 "$H/.config/olecharms/secrets"
sleep 1; LA=$(date +%s); sleep 1
echo "export X_TOKEN='y'" > "$H/.config/olecharms/secrets"
out=$(OLECHARMS_SHELL_LOADED_AT=$LA $OC sync --local 2>&1 | plain)
chk "secrets changed since → notice"        grep -q "$NOTICE" <<< "$out"
sleep 1; LA=$(date +%s); sleep 1
echo '# mine' >> "$H/.zshrc"
out=$(OLECHARMS_SHELL_LOADED_AT=$LA $OC sync --local 2>&1 | plain)
chk ".zshrc edited (e.g. in another terminal) → notice" grep -q "$NOTICE" <<< "$out"

echo "== 4. without the shell function: before/after snapshot"
out=$($OC sync --local 2>&1 | plain)
chk "nothing changed → no notice"           bash -c '! grep -q "previous shell configuration" <<< "$1"' _ "$out"
out=$(OLECHARMS_SHELL_BEFORE="from before the pull" $OC sync --local 2>&1 | plain)
chk "snapshot from before the pull differs → notice" grep -q "$NOTICE" <<< "$out"
chk "snapshot covers shell/*.sh"             bash -c 'source "$1/lib.sh"; shell_config_snapshot | grep -q "shell/mkcd.sh:"' _ "$R"

echo "== 5. through the shell function: flag instead of notice"
F=$(mktemp "$SB/flag.XXXXXX")
out=$(OLECHARMS_SHELL_LOADED_AT=1 OLECHARMS_RELOAD_FLAG=$F $OC sync --local 2>&1 | plain)
chk "flag set"                               test "$(cat "$F")" = 1
chk "no notice printed (the function asks)"  bash -c '! grep -q "previous shell configuration" <<< "$1"' _ "$out"
out=$(OLECHARMS_SHELL_LOADED_AT=1 OLECHARMS_RELOAD_FLAG=$SB/nonexistent $OC sync --local 2>&1 | plain)
chk "flag path that does not exist: notice, no file" bash -c 'grep -q "previous shell configuration" <<< "$1" && [ ! -e "$2" ]' _ "$out" "$SB/nonexistent"

echo "== 6. doctor --fix and config end with it too"
out=$(OLECHARMS_SHELL_LOADED_AT=1 $OC doctor --fix </dev/null 2>&1 | plain)
chk "doctor --fix: notice"                   grep -q "$NOTICE" <<< "$out"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "plain doctor: never"                    bash -c '! grep -q "previous shell configuration" <<< "$1"' _ "$out"
out=$(echo 0 | OLECHARMS_SHELL_LOADED_AT=1 $OC config 2>&1 | plain)
chk "config: notice on exit"                 grep -q "$NOTICE" <<< "$out"
out=$(echo 0 | OLECHARMS_SHELL_LOADED_AT=$(( $(date +%s) + 100 )) $OC config 2>&1 | plain)
chk "config, nothing changed: none"          bash -c '! grep -q "previous shell configuration" <<< "$1"' _ "$out"

echo "== 7. real interactive shells: the offer"
# $1 shell, $2 commands, then the lines typed at the terminal (one per second)
tty_run() {
    local sh="$1" cmd="$2"; shift 2
    { for l in "$@"; do sleep 1; printf '%s\n' "$l"; done; sleep 1; } |
        (cd "$H" && ZDOTDIR=$H script -qc "$sh -i -c '$cmd'" /dev/null) 2>&1 | plain
}
old='_olecharms_loaded_at=1'
out=$(tty_run zsh "$old; olecharms sync --local; echo STILL_HERE" n)
chk "zsh: asks to reload"                    grep -qF "Reload it now (exec zsh)? [Y/n]" <<< "$out"
chk "zsh: n keeps the shell, says how later" bash -c 'grep -q "Later: run .exec zsh." <<< "$1" && grep -q STILL_HERE <<< "$1"' _ "$out"
out=$(tty_run zsh "$old; olecharms sync --local; echo STILL_HERE" y 'echo NEW_SHELL_$((6*7)); exit')
chk "zsh: y replaces the shell with a new one" bash -c 'grep -q NEW_SHELL_42 <<< "$1" && ! grep -q STILL_HERE <<< "$1"' _ "$out"
out=$(tty_run zsh "sleep 30 & $old; olecharms sync --local; echo STILL_HERE; kill %1")
chk "zsh: with a background job, no offer"   bash -c 'grep -q "background jobs: run .exec zsh. once" <<< "$1" && ! grep -q "Reload it now" <<< "$1" && grep -q STILL_HERE <<< "$1"' _ "$out"
out=$(tty_run zsh "olecharms sync --local; echo STILL_HERE")
chk "zsh: fresh shell, nothing changed → silent" bash -c '! grep -q "previous configuration" <<< "$1" && grep -q STILL_HERE <<< "$1"' _ "$out"
out=$(tty_run zsh "$old; olecharms alias list >/dev/null; echo STILL_HERE")
chk "zsh: other commands never ask"          bash -c '! grep -q "Reload it now" <<< "$1"' _ "$out"
out=$(tty_run bash "$old; olecharms sync --local; echo STILL_HERE" n)
chk "bash: asks with exec bash"              grep -qF "Reload it now (exec bash)? [Y/n]" <<< "$out"
chk "no flag files left behind"              bash -c '! ls "${TMPDIR:-/tmp}"/olecharms-reload.* >/dev/null 2>&1'

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
