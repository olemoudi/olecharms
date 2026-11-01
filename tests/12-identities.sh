#!/bin/bash
# ssk: identities (add, set, list), folders bound to one (includeIf), one
# command as an identity (run), asking GitHub who a key is (test), the old
# global switch and its ssh-agent warning, and the doctor's checks. A fake
# ssh records how it was called; keys are throwaway ones made here.
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
cd "$SB" || exit 1
command -v ssh-keygen >/dev/null || { echo "SKIP: needs ssh-keygen"; exit 77; }
git config --global user.name tester; git config --global user.email t@t
SSK="bash $R/bin/ssk"
K=$SB/keys; mkdir -p "$K" "$SB/fake"
for n in work personal; do ssh-keygen -q -t ed25519 -N '' -C "$n" -f "$K/$n"; done
# Fake ssh: logs its arguments; GitHub answers "Hi workuser!" to the work key
cat > "$SB/fake/ssh" <<EOF
#!/bin/sh
echo "\$*" >> "$SB/ssh.log"
case " \$* " in
    *"/work.privatekey"*) echo "Hi workuser! You've successfully authenticated, but GitHub does not provide shell access." >&2 ;;
    *) echo "git@github.com: Permission denied (publickey)." >&2 ;;
esac
exit 1
EOF
cat > "$SB/fake/gh" <<'EOF'
#!/bin/sh
[ "$1 $2" = "auth token" ] && case "$*" in *"--user workuser"*) echo TOKEN-W; exit 0 ;; esac
exit 1
EOF
chmod +x "$SB/fake/ssh" "$SB/fake/gh"
FP="$SB/fake:$PATH"

echo "== 1. add, set, list"
out=$($SSK add work "$K/work" "$K/work.pub" --email w@corp.example --name "Work Me" --gh workuser 2>&1)
chk "add with details"                      grep -q "added identity 'work'" <<< "$out"
chk "private key 600, public 644"           test "$(stat -c %a "$H/.ssh/work.privatekey")$(stat -c %a "$H/.ssh/work.pubkey")" = 600644
$SSK add personal "$K/personal" "$K/personal.pub" >/dev/null 2>&1
$SSK set personal email p@me.example >/dev/null
out=$($SSK list --plain)
chk "list --plain"                          bash -c 'grep -qx "work	w@corp.example	workuser	" <<< "$1" && grep -qx "personal	p@me.example		" <<< "$1"' _ "$out"
chk "add: path-like name refused"           bash -c '! $1 add ../evil "$2/work" "$2/work.pub" 2>/dev/null && [ ! -e "$3/evil.pubkey" ]' _ "$SSK" "$K" "$H"
chk "add: swapped files refused"            bash -c '! $1 add swap "$2/work.pub" "$2/work" 2>/dev/null' _ "$SSK" "$K"
chk "add: an existing name refused"         bash -c '! $1 add work "$2/work" "$2/work.pub" 2>/dev/null' _ "$SSK" "$K"
chk "set: unknown detail refused"           bash -c '! $1 set work colour red 2>/dev/null' _ "$SSK"

echo "== 2. bind, which, unbind"
W=$SB/work; P=$W/proj; O=$SB/other
mkdir -p "$P" "$O"; git -C "$P" init -q; git -C "$O" init -q
git config --global --add includeIf.gitdir:/somewhere/mine/.path /somewhere/mine.gitconfig
out=$($SSK bind work "$W" 2>&1)
chk "bind"                                  grep -q "now uses 'work'" <<< "$out"
chk "inside: its email"                     test "$(git -C "$P" config user.email)" = w@corp.example
chk "inside: its key, IdentitiesOnly"       bash -c 'git -C "$1" config core.sshCommand | grep -q "ssh -i .*/work.privatekey. -o IdentitiesOnly=yes"' _ "$P"
chk "outside: untouched"                    test "$(git -C "$O" config user.email)" = t@t
out=$($SSK which "$P")
chk "which: names the identity"             bash -c 'grep -q "identity: work (bound folder)" <<< "$1" && grep -q "email:    w@corp.example" <<< "$1"' _ "$out"
out=$($SSK which "$O")
chk "which elsewhere: none bound"           grep -q "identity: none bound" <<< "$out"
chk "bind refuses the home folder"          bash -c '! $1 bind work "$2" 2>/dev/null' _ "$SSK" "$H"
chk "bind refuses /"                        bash -c '! $1 bind work / 2>/dev/null' _ "$SSK"
$SSK bind personal "$W" >/dev/null 2>&1
chk "rebinding a folder replaces, not adds" test "$(git config --global --get-all "includeIf.gitdir:$W/.path" | wc -l)" -eq 1 -a "$(git -C "$P" config user.email)" = p@me.example
$SSK bind work "$W" >/dev/null 2>&1
$SSK set work email new@corp.example >/dev/null
chk "set: bound folders follow"             test "$(git -C "$P" config user.email)" = new@corp.example
out=$($SSK list)
chk "list shows the folder"                 grep -q "work .*folders: $W" <<< "$out"
$SSK unbind "$W" >/dev/null
chk "unbind: back to the global identity"   test "$(git -C "$P" config user.email)" = t@t
chk "unbind: your own includeIf kept"       test "$(git config --global --get includeIf.gitdir:/somewhere/mine/.path)" = /somewhere/mine.gitconfig
G=$SB/gone; mkdir -p "$G"; $SSK bind work "$G" >/dev/null 2>&1; rmdir "$G"
$SSK unbind "$G" >/dev/null 2>&1
chk "unbind a deleted folder by its path"   test -z "$(git config --global --get-all "includeIf.gitdir:$G/.path")"

echo "== 3. run: one command as an identity"
out=$(PATH="$FP" $SSK run work -- sh -c 'echo "$GIT_SSH_COMMAND|$GIT_AUTHOR_EMAIL|$GIT_COMMITTER_NAME|$GH_TOKEN"')
chk "run: key, author, GH_TOKEN"            bash -c 'grep -q "^ssh -i .*/work.privatekey. -o IdentitiesOnly=yes|new@corp.example|Work Me|TOKEN-W$" <<< "$1"' _ "$out"
rm -f "$SB/ssh.log"
PATH="$FP" $SSK run work -- git -C "$O" ls-remote git@github.com:x/y.git >/dev/null 2>&1
chk "git over ssh used that key"            grep -q -- "-i $H/.ssh/work.privatekey -o IdentitiesOnly=yes .*git@github.com" "$SB/ssh.log"
chk "nothing global changed"                bash -c '[ "$(git -C "$1" config user.email)" = t@t ] && [ ! -e "$2/.ssh/id_ed25519" ]' _ "$O" "$H"
$SSK bind work "$W" >/dev/null 2>&1; rm -f "$SB/ssh.log"
PATH="$FP" git -C "$P" ls-remote git@github.com:x/y.git >/dev/null 2>&1
chk "bound folder: plain git uses the key"  grep -q "/work.privatekey" "$SB/ssh.log"
chk "run: unknown identity refused"         bash -c '! $1 run nobody -- true 2>/dev/null' _ "$SSK"

echo "== 4. test: who GitHub says the key is"
out=$(PATH="$FP" $SSK test work 2>&1); rc=$?
chk "test work → workuser (rc=$rc)"         bash -c '[ "$2" -eq 0 ] && grep -q "knows this key as: workuser" <<< "$1"' _ "$out" "$rc"
out=$(PATH="$FP" $SSK test personal 2>&1); rc=$?
chk "test personal → not accepted"          bash -c '[ "$2" -ne 0 ] && grep -q "did not accept" <<< "$1"' _ "$out" "$rc"

echo "== 5. the old global switch"
cp "$K/personal" "$SB/unnamed"; ssh-keygen -q -t ed25519 -N '' -f "$SB/unnamed2"
cp "$SB/unnamed2" "$H/.ssh/id_ed25519"; cp "$SB/unnamed2.pub" "$H/.ssh/id_ed25519.pub"
printf '#!/bin/sh\necho "256 SHA256:SomeOtherKey other (ED25519)"\n' > "$SB/fake/ssh-add"; chmod +x "$SB/fake/ssh-add"
out=$(PATH="$FP" $SSK work 2>&1)
chk "switch: copied over id_ed25519"        cmp -s "$H/.ssh/id_ed25519" "$H/.ssh/work.privatekey"
chk "switch: the unnamed key was kept"      bash -c 'ls "$1"/.ssh/backup-*.privatekey >/dev/null 2>&1' _ "$H"
chk "switch: warns about ssh-agent's keys"  grep -q "ssh-agent still holds other keys" <<< "$out"
chk "current"                               test "$($SSK)" = work
printf '#!/bin/sh\nexit 1\n' > "$SB/fake/ssh-add"
out=$(PATH="$FP" $SSK personal 2>&1)
chk "no agent: no warning"                  bash -c '! grep -q ssh-agent <<< "$1"' _ "$out"

echo "== 6. doctor"
chmod 644 "$H/.ssh/personal.privatekey"
G2=$SB/gone2; mkdir -p "$G2"; $SSK bind personal "$G2" >/dev/null 2>&1; rmdir "$G2"
out=$(bash "$R/olecharms.sh" doctor </dev/null 2>&1 | plain)
chk "doctor: key others can read"           grep -q "personal.privatekey can be read by others" <<< "$out"
chk "doctor: bound folder gone"             grep -q "gone2 is bound to 'personal' but no longer exists" <<< "$out"
chk "doctor: counts identities"             grep -qE "[0-9]+ identities; ssk list" <<< "$out"
out=$(printf 'y\nn\nn\nn\nn\nn\n' | script -qc "bash $R/olecharms.sh doctor --fix" /dev/null 2>&1 | plain)
chk "doctor --fix: chmod after asking"      test "$(stat -c %a "$H/.ssh/personal.privatekey")" = 600

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
