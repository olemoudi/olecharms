#!/bin/bash
# Instructions for coding agents (Claude Code rules file, Codex/Gemini
# blocks, Claude Code permission rules), the shell history with its secret
# filter in real interactive zsh and bash, paranoid mode wiping it, and the
# shell startup time in the doctor (--profile never shows commands).
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home R=$SB/repo
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
export OLECHARMS_WIN_VIM_HOME=$SB/winhome GIT_CONFIG_NOSYSTEM=1
bash -c "source '$R/lib.sh'; config_ensure >/dev/null; config_set windows_integration off; config_set daily_doctor off" >/dev/null 2>&1
grep -q '^windows_integration=off' "$H/.config/olecharms/config" || { echo "ABORT: could not disable Windows integration"; exit 1; }
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
plain() { sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'; }
lib() { bash -c "source '$R/lib.sh'; detect_os; config_ensure >/dev/null 2>&1; $1" 2>&1 | plain; }
OC="bash $R/olecharms.sh"
cd "$SB" || exit 1
git config --global user.name tester; git config --global user.email t@t
CR=$H/.claude/rules/olecharms.md CX=$H/.codex/AGENTS.md GM=$H/.gemini/GEMINI.md

echo "== 1. agent instructions"
out=$(lib 'agents_refresh')
chk "no agent here: nothing written"        test ! -e "$H/.claude" -a ! -e "$H/.codex"
mkdir -p "$H/.claude" "$H/.codex"
printf '# My notes for Codex\n\nBe brief.\n' > "$CX"
ssh-keygen -q -t ed25519 -N '' -f "$SB/k" 2>/dev/null
bash "$R/bin/ssk" add work "$SB/k" "$SB/k.pub" --email w@corp.example >/dev/null 2>&1
mkdir -p "$SB/work"; bash "$R/bin/ssk" bind work "$SB/work" >/dev/null 2>&1
lib 'install_bin_links' >/dev/null
out=$(lib 'agents_refresh')
chk "Claude Code: its own rules file"       bash -c 'head -n 1 "$1" | grep -q "^<!-- olecharms:begin"' _ "$CR"
chk "Codex: your notes kept, block added"   bash -c 'head -n 1 "$1" | grep -qx "# My notes for Codex" && grep -q "^<!-- olecharms:begin" "$1" && grep -qx "Be brief." "$1"' _ "$CX"
chk "Gemini: not set up, not touched"       test ! -e "$H/.gemini"
chk "names the identity and its folder"     grep -q '^- `work`: w@corp.example; git uses it automatically inside .*/work$' "$CR"
chk "no GitHub user given: none claimed"    bash -c '! grep -q "GitHub user" "$1"' _ "$CR"
chk "says how to run as one, and what not"  bash -c 'grep -q "ssk run <name> -- git push" "$1" && grep -q "Do not run .ssk <name>. on its own" "$1" && grep -q "Never read, print or copy private keys" "$1"' _ "$CR"
chk "mentions trash (it is linked)"         grep -q '`trash <paths>`' "$CR"
chk "lists only commands installed here"    bash -c 'command -v jq >/dev/null && exit 0; ! grep -q "\`jq\`" "$1"' _ "$CR"
h1=$(cksum < "$CX"); out=$(lib 'agents_refresh')
chk "second refresh: no change, silent"     bash -c '[ "$(cksum < "$1")" = "$2" ] && [ -z "$3" ]' _ "$CX" "$h1" "$out"
bash "$R/bin/ssk" set work email changed@corp.example >/dev/null
chk "ssk set refreshes them"                grep -q "changed@corp.example" "$CR"
echo "after" >> "$CX"; sed -i 's/^- `trash/- `TRASH/' "$CX"
lib 'agents_refresh' >/dev/null
chk "an edit inside the block is undone, text after it kept" bash -c '! grep -q "TRASH" "$1" && tail -n 1 "$1" | grep -qx after' _ "$CX"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: instructions current"          grep -q "Instructions for claude codex: identities and commands, current" <<< "$out"
echo "stale" >> "$CR"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: out of date"                   grep -q "instructions for claude codex are out of date" <<< "$out"
mv "$CR" "$SB/ours.md"; echo "# my own rules" > "$CR"
out=$(lib 'agents_refresh')
chk "a rules file of yours is left alone"   bash -c 'grep -qx "# my own rules" "$1" && grep -q "not olecharms" <<< "$2"' _ "$CR" "$out"
rm -f "$CR"
$OC agents off >/dev/null 2>&1
chk "off: file and block removed, notes kept" bash -c '[ ! -e "$1" ] && ! grep -q olecharms:begin "$2" && grep -qx "Be brief." "$2"' _ "$CR" "$CX"
$OC agents on >/dev/null 2>&1
chk "on: back"                              test -f "$CR"

echo "== 2. Claude Code permission rules"
printf '{\n  "model": "x",\n  "permissions": {"allow": ["Bash(ls)"]}\n}\n' > "$H/.claude/settings.json"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: offers the rules"              grep -q "Claude Code may read your private keys" <<< "$out"
$OC agents protect >/dev/null 2>&1
chk "deny rules added, the rest kept"       python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d["permissions"]; sys.exit(0 if d["model"]=="x" and p["allow"]==["Bash(ls)"] and "Read(~/.ssh/id_*)" in p["deny"] and "Read(~/.config/olecharms/secrets)" in p["deny"] else 1)' "$H/.claude/settings.json"
chk "a backup first"                        bash -c 'ls "$1"/.claude/settings.json.backup.* >/dev/null 2>&1' _ "$H"
$OC agents protect >/dev/null 2>&1
chk "twice: no duplicates"                  test "$(grep -c 'Read(~/.ssh/id_\*)' "$H/.claude/settings.json")" -eq 1
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: protected"                     grep -q "Claude Code may not read your private keys" <<< "$out"
echo '{ broken' > "$H/.claude/settings.json"
out=$($OC agents protect 2>&1); rc=$?
chk "invalid JSON: refused, left as it is"  bash -c '[ "$2" -ne 0 ] && [ "$(cat "$1")" = "{ broken" ]' _ "$H/.claude/settings.json" "$rc"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: says it is not valid JSON"     grep -q "settings.json is not valid JSON" <<< "$out"

echo "== 3. shell history, secrets left out"
lib 'config_set shell_history on; config_set zsh_extras off; install_shell_commands' >/dev/null
printf "export MY_SECRET_X='supersecretvalue1'\n" > "$H/.config/olecharms/secrets"; chmod 600 "$H/.config/olecharms/secrets"
lines=(
    'echo normal-line-1'
    'export GITHUB_TOKEN=abc123'
    'echo curl -H "Authorization: Bearer xyz"'
    'echo supersecretvalue1'
    ' echo leading-space'
    'echo https://user:pw@host.example/x'
    'echo ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'echo path-ok PATH=/usr/bin'
    'echo git log --author=bob'
    'echo API_KEY = spaced'
)
# Type the lines into a real interactive shell, one per half second
typein() { { sleep 1; for l in "${lines[@]}"; do printf '%s\n' "$l"; sleep 0.5; done; echo exit; sleep 1; } |
           (cd "$H" && ZDOTDIR=$H script -qc "$1" /dev/null >/dev/null 2>&1); }
typein "zsh -i"
Z=$H/.local/state/olecharms/history/zsh_history
chk "zsh: history file made"                test -f "$Z"
chk "zsh: ordinary lines kept"              bash -c 'grep -q "normal-line-1" "$1" && grep -q "path-ok PATH=" "$1" && grep -q "author=bob" "$1"' _ "$Z"
for pat in GITHUB_TOKEN Bearer supersecretvalue1 leading-space user:pw ghp_ "API_KEY = "; do
    chk "zsh: left out: $pat"               bash -c '! grep -qF -- "$2" "$1"' _ "$Z" "$pat"
done
chk "zsh: file private (600 in a 700 dir)"  test "$(stat -c %a "$Z")$(stat -c %a "${Z%/*}")" = 600700
typein "bash -i"
Bh=$H/.local/state/olecharms/history/bash_history
chk "bash: history file made"               test -f "$Bh"
chk "bash: ordinary lines kept"             bash -c 'grep -q "normal-line-1" "$1" && grep -q "author=bob" "$1"' _ "$Bh"
for pat in GITHUB_TOKEN Bearer supersecretvalue1 leading-space user:pw ghp_ "API_KEY = "; do
    chk "bash: left out: $pat"              bash -c '! grep -qF -- "$2" "$1"' _ "$Bh" "$pat"
done
# bash matches with HISTIGNORE globs, wider than zsh's regexp, so pin the
# other direction too: one stray catch-all pattern would empty the file
lines=(
    'echo path-ok PATH=/usr/bin'
    'echo git clone ssh://git@github.com/u/r'
    'echo make -j8 CC=clang'
    'echo rsync -a src/ user@host:/dest'
    'echo docker run -e FOO=bar img'
    'echo grep -r passthru src/'
    'echo curl -s https://api.example.com/v1/items'
)
typein "bash -i"
for l in "${lines[@]}"; do
    chk "bash: kept: ${l#echo }"            grep -qxF -- "$l" "$Bh"
done
# Nothing is removed: a secret line is never taken down in the first place,
# so it is in neither the file nor the session's own history
lines=( 'export GITHUB_TOKEN=inthissession' "builtin history > $H/sess.txt" )
typein "bash -i"
chk "bash: a secret is not taken down at all"   bash -c '! grep -q inthissession "$1" && ! grep -q inthissession "$2"' _ "$H/sess.txt" "$Bh"
chk "bash: a new session loads the earlier lines" grep -q "normal-line-1" "$H/sess.txt"
chk "bash: and writes none of them again"       test "$(grep -c '^echo normal-line-1$' "$Bh")" -eq 1
chk "bash: HISTFILE is the olecharms file"      bash -c 'cd "$1" && HOME="$1" bash -ic "echo HF=\$HISTFILE" </dev/null 2>/dev/null | grep -qx "HF=$2"' _ "$H" "$Bh"
out=$(cd "$H" && ZDOTDIR=$H zsh -ic 'echo "HF=$HISTFILE"' </dev/null 2>/dev/null)
chk "zsh uses the olecharms file"           grep -qx "HF=$Z" <<< "$out"
lib 'config_set shell_history off; install_shell_commands' >/dev/null
out=$(cd "$H" && ZDOTDIR=$H zsh -ic 'echo "HF=$HISTFILE"' </dev/null 2>/dev/null)
chk "history off: not olecharms' file"      bash -c '! grep -qx "HF=$2" <<< "$1"' _ "$out" "$Z"
lib 'config_set shell_history on; install_shell_commands' >/dev/null
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: kept, without secrets"         grep -q "Kept in ~/.local/state/olecharms/history, without lines that look like secrets" <<< "$out"
echo 'unset HISTFILE' >> "$H/.zshrc"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "doctor: an unset HISTFILE after the block" grep -q "changes HISTFILE after olecharms' block" <<< "$out"
sed -i '$d' "$H/.zshrc"
lib 'enable_paranoid_mode hook' >/dev/null
P=$R/scripts/paranoid-cleanup.sh
grep -E '^(HOME_DIR|VIM_DIR|CLEANUP_LOG|HISTORY_DIR)=' "$P" | grep -v "=$SB" && { echo "ABORT: paranoid path outside the sandbox"; exit 1; }
grep -v '^TASKLIST=' "$P" | grep -q '/mnt/c' && { echo "ABORT: paranoid script mentions /mnt/c"; exit 1; }
bash "$P" >/dev/null 2>&1
chk "paranoid mode wipes the history"       test ! -e "$Z" -a ! -e "$Bh"
lib 'disable_paranoid_mode' >/dev/null

echo "== 4. shell startup time"
echo "export SECRET_IN_RC=topsecretvalue9" >> "$H/.zshrc"
out=$(script -qc "bash $R/olecharms.sh doctor" /dev/null </dev/null 2>&1 | plain)
chk "doctor at a terminal: startup measured" grep -qE "A new zsh (is ready in|takes) [0-9]+ ms" <<< "$out"
out=$($OC doctor </dev/null 2>&1 | plain)
chk "without a terminal: not measured"      grep -q "Not measured (needs zsh and a terminal)" <<< "$out"
# The trace zsh -x prints holds the commands (and so any secret in ~/.zshrc);
# --profile must not leave it on disk. Compare the tmp files holding the secret
# before and after, so a leftover from an earlier aborted run cannot stand in
# for a fresh leak (/tmp is shared; the check runs against the whole of it).
tmp_with_secret() { grep -l topsecretvalue9 "${TMPDIR:-/tmp}"/* 2>/dev/null | sort; }
before_profile=$(tmp_with_secret)
out=$($OC doctor --profile 2>&1 | plain)
chk "--profile: total and files"            bash -c 'grep -q "Total: [0-9]* ms" <<< "$1" && grep -q ".zshrc" <<< "$1"' _ "$out"
chk "--profile never shows commands"        bash -c '! grep -q topsecretvalue9 <<< "$1"' _ "$out"
chk "--profile leaves no trace file"        bash -c '[ "$(grep -l topsecretvalue9 "${TMPDIR:-/tmp}"/* 2>/dev/null | sort)" = "$1" ]' _ "$before_profile"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
