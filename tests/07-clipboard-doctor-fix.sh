#!/bin/bash
# Clipboard (olecharms-clip, copy/paste, terminal Vim) and doctor repairs
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home
# A ~/.vimrc from before olecharms: an old pasted copy of olevimrc.vim
REALVIMRC_BACKUP=$TESTS_DIR/fixtures/old-vimrc-copy.vim
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
unset XDG_DATA_HOME ZSH ZSH_CUSTOM
export OLECHARMS_WIN_VIM_HOME=$SB/winhome
bash -c "source '$SB/repo/lib.sh'; config_ensure >/dev/null; config_set windows_integration off; config_set daily_doctor off" >/dev/null 2>&1
grep -q '^windows_integration=off' "$H/.config/olecharms/config" || { echo "ABORT: could not disable Windows integration"; exit 1; }
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$SB/repo/lib.sh'; $1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
C=$SB/repo/bin/olecharms-clip
CF=$SB/clipfile

echo "== 1. olecharms-clip"
chk "POSIX sh syntax (dash)"                 dash -n "$C"
chk "executable bit"                        test -x "$C"
pwd | OLECHARMS_CLIP_FILE=$CF sh "$C" copy
chk "single line loses its newline"          test "$(od -An -c "$CF" | tr -d ' \n')" = "$(pwd | tr -d '\n' | od -An -c | tr -d ' \n')"
printf 'a\nb\n' | OLECHARMS_CLIP_FILE=$CF sh "$C" copy
chk "two lines kept as they are"             test "$(od -An -c "$CF" | tr -d ' \n')" = 'a\nb\n'
printf 'x ñ €' | OLECHARMS_CLIP_FILE=$CF dash "$C" copy
chk "UTF-8 round trip through paste"         test "$(OLECHARMS_CLIP_FILE=$CF sh "$C" paste)" = 'x ñ €'
chk "ssh backend without a display"          test "$(SSH_CONNECTION='1 2 3 4' DISPLAY= WAYLAND_DISPLAY= sh "$C" backend)" = ssh
chk "X forwarding keeps x11/wsl backend"     test "$(SSH_CONNECTION='1 2 3 4' DISPLAY=:0 sh "$C" backend)" != ssh
osc=$(SSH_CONNECTION='1 2 3 4' DISPLAY= WAYLAND_DISPLAY= script -qc "printf hola | sh $C copy" /dev/null | od -An -c | tr -d ' \n')
chk "OSC 52 sequence written ($osc)"         test "$osc" = '033]52;c;aG9sYQ==\a'
osc=$(SSH_CONNECTION='1 2 3 4' DISPLAY= WAYLAND_DISPLAY= TMUX=x script -qc "printf hola | sh $C copy" /dev/null | od -An -c | tr -d ' \n')
chk "tmux passthrough wrapping"              test "$osc" = '033Ptmux;033033]52;c;aG9sYQ==\a033\'
out=$(SSH_CONNECTION='1 2 3 4' DISPLAY= WAYLAND_DISPLAY= sh "$C" paste 2>&1); rc=$?
chk "paste over SSH explains and fails"      bash -c '[ "$1" -ne 0 ] && grep -q "paste with the terminal" <<< "$2"' _ "$rc" "$out"
chk "unknown subcommand → usage, rc 2"       bash -c 'sh "$1" bogus 2>/dev/null; [ $? -eq 2 ]' _ "$C"

echo "== 2. copy / paste shell functions (bash and zsh)"
for sh in bash zsh; do
    out=$($sh -c "_olecharms_bin=$SB/repo/olecharms.sh; . $SB/repo/shell/clipboard.sh
        export OLECHARMS_CLIP_FILE=$CF
        echo hola-$sh | copy; cat $CF; echo
        printf '1\n2\n' > $SB/p1; printf 'a\nb\n' > $SB/p2
        paste $SB/p1 $SB/p2 | tr '\t' :
        copy $SB/nofile 2>&1; echo rc=\$?
        copy $SB/p1 $SB/p2; tr '\n' , < $CF; echo
        copy < /dev/null; echo rc=\$?" 2>&1)
    chk "$sh: pipe into copy"                     grep -qx "hola-$sh" <<< "$out"
    chk "$sh: paste FILE FILE is still paste(1)"  grep -qx '1:a' <<< "$out"
    chk "$sh: copy of a missing file fails"       grep -q 'cannot read' <<< "$out"
    chk "$sh: copy FILE FILE concatenates"        grep -qx '1,2,a,b,' <<< "$out"
done
out=$(script -qc "bash -c '_olecharms_bin=$SB/repo/olecharms.sh; . $SB/repo/shell/clipboard.sh; OLECHARMS_CLIP_FILE=$CF; export OLECHARMS_CLIP_FILE; printf PEGADO > $CF; paste; echo; copy; echo rc=\$?'" /dev/null 2>&1 | tr -d '\r')
chk "paste at a terminal prints the clipboard" grep -qx 'PEGADO' <<< "$out"
chk "copy at a terminal without input: usage" bash -c 'grep -q "usage" <<< "$1" && grep -qx "rc=2" <<< "$1"' _ "$out"

echo "== 3. terminal Vim"
printf 'uno\ndos ñ\ntres\n' > "$SB/v.txt"
vrun() { (cd "$SB" && OLECHARMS_CLIP_FILE=$CF TERM=xterm vim -Nu "$SB/repo/vimthings/olevimrc.vim" -i NONE -n -es v.txt "$@" +'qa!' >/dev/null 2>&1); }
rm -f "$CF"; vrun +'normal ggyy'
chk "yy copies (newline of one line dropped)" test "$(cat "$CF")" = uno
rm -f "$CF"; vrun +'normal ggj"+yiw'
chk '"+yiw copies the word'                  test "$(cat "$CF")" = dos
rm -f "$CF"; vrun +'normal ggjdd'
chk "dd does not touch the clipboard"        test ! -e "$CF"
rm -f "$CF"; vrun +'normal ggj"*dd'
chk '"*dd copies'                            test "$(cat "$CF")" = 'dos ñ'
rm -f "$CF"; vrun +'exe "normal ggjviw\<C-c>"'
chk "visual Ctrl-C copies"                   test "$(cat "$CF")" = dos
printf 'PEGADO' > "$CF"; vrun +'normal gg"+p' +'w! out.txt'
chk '"+p pastes after the cursor'            test "$(head -1 "$SB/out.txt")" = uPEGADOno
printf 'L1\nL2\n' > "$CF"; vrun +'normal gg"+P' +'w! out.txt'
chk 'linewise "+P above'                     test "$(head -3 "$SB/out.txt" | tr '\n' ,)" = 'L1,L2,uno,'
printf 'XX' > "$CF"; vrun +'normal ggviw"+p' +'w! out.txt'
chk 'visual "+p replaces the selection'      test "$(head -1 "$SB/out.txt")" = XX
printf 'ZZ' > "$CF"; vrun +'exe "normal ggA \<C-r>+"' +'w! out.txt'
chk 'insert-mode <C-r>+'                     test "$(head -1 "$SB/out.txt")" = 'uno ZZ'
printf 'S' > "$CF"; vrun +'normal ggx' +'exe "normal \<C-s>"'
chk "Ctrl-S saves"                           test "$(head -1 "$SB/v.txt")" = no
chk "no vim errors at startup"               test -z "$(cd "$SB" && TERM=xterm vim -Nu "$SB/repo/vimthings/olevimrc.vim" -i NONE -n -es +'redir! > verr.txt | silent messages | redir END' +'qa!' >/dev/null 2>&1; grep -E 'E[0-9]+:' "$SB/verr.txt" | grep -v pathogen)"

echo "== 4. doctor: git password helpers"
( cd "$SB/repo" && git init -q -b master && git add -A >/dev/null && git -c user.name=t -c user.email=t@t commit -qm init &&
  git remote add origin https://github.com/olemoudi/olecharms && git config branch.master.remote origin )
BROKEN='/mnt/c/Program\ Files/Nope/git-credential-manager.exe'
git config --global credential.helper "$BROKEN"
d=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_git_helpers master; echo "OFFERS=${#DOC_OFFER_Q[@]}"')
chk "only helper broken → cannot push"      grep -q 'Git cannot log in to push olecharms' <<< "$d"
chk "path with spaces parsed"               grep -q 'Missing program: /mnt/c/Program Files/Nope/' <<< "$d"
chk "removal offered"                       grep -q 'OFFERS=1' <<< "$d"
git config --global credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper '!/bin/true'
d=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_git_helpers master')
chk "GitHub override → olecharms unaffected" grep -q 'Pushing olecharms works' <<< "$d"
chk "...and no 'cannot push' warning"       bash -c '! grep -q "cannot log in" <<< "$1"' _ "$d"
chk "effective helpers for GitHub = /bin/true" test "$(lib 'SCRIPT_DIR='"$SB/repo"'; git_effective_helpers https://user@github.com/x/y')" = '!/bin/true'
chk "effective helpers elsewhere = broken"  test "$(lib 'SCRIPT_DIR='"$SB/repo"'; git_effective_helpers https://gitlab.com/x/y')" = "$BROKEN"
lib "git_helper_remove '$H/.gitconfig' credential.helper '$BROKEN'" >/dev/null
chk "removal drops exactly that entry"      bash -c '! git config --global --get-all credential.helper >/dev/null && [ "$(git config --global --get-all credential.https://github.com.helper | tail -1)" = "!/bin/true" ]'
chk "gitconfig backup kept"                 bash -c 'ls "$1"/.gitconfig.backup.* >/dev/null 2>&1' _ "$H"
git config --global credential.helper '!f() { echo x; }; f'
git config --global --add credential.helper store
d=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_git_helpers master')
chk "shell-snippet and store helpers: quiet" test -z "$d"
git config --global --unset-all credential.helper

echo "== 5. doctor: old copy in ~/.vimrc"
if [ -f "$REALVIMRC_BACKUP" ]; then
    cp "$REALVIMRC_BACKUP" "$H/.vimrc"
else
    { echo '" author: @olemoudi'; cat "$SB/repo/vimthings/olevimrc.vim"; } > "$H/.vimrc"
fi
SRC="source $SB/repo/vimthings/olevimrc.vim"
printf '%s\n' '" olecharms managed config - do not remove this line' "$SRC" >> "$H/.vimrc"
d=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_vim; echo "OFFERS=${#DOC_OFFER_Q[@]}"')
chk "old copy detected"                     grep -q 'old pasted copy' <<< "$d"
chk "explains the Windows-style keys"       grep -q 'Ctrl-V pastes' <<< "$d"
chk "all lines recognised → fix offered"    grep -q 'OFFERS=1' <<< "$d"
echo 'set relativenumber' >> "$H/.vimrc"
d=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_vim; echo "OFFERS=${#DOC_OFFER_Q[@]}"')
chk "own line listed before removal"        grep -q '^          set relativenumber' <<< "$d"
chk "still offered (≤10 own lines)"         grep -q 'OFFERS=1' <<< "$d"
for i in $(seq 1 11); do echo "let g:mine_$i = 1"; done >> "$H/.vimrc"
d=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_vim; echo "OFFERS=${#DOC_OFFER_Q[@]}"')
chk "many own lines → hand edit, no offer"  bash -c 'grep -q "Edit .* by hand" <<< "$1" && grep -q "OFFERS=0" <<< "$1"' _ "$d"
lib 'vimrc_remove_old_copy' >/dev/null
chk "removal leaves the two olecharms lines" test "$(cat "$H/.vimrc")" = "$(printf '%s\n%s' '" olecharms managed config - do not remove this line' "$SRC")"
chk "vimrc backup kept"                     bash -c 'ls "$1"/.vimrc.backup.* >/dev/null 2>&1' _ "$H"

echo "== 6. doctor: Windows Terminal font (on a copy)"
mkdir -p "$SB/wt"
cat > "$SB/wt/settings.json" <<'EOF'
{
    "profiles": {
        "defaults": {},
        "list": [
            { "name": "PowerShell", "font": { "face": "Cascadia Mono" } },
            { "name": "Ubuntu", "source": "Microsoft.WSL" },
            { "name": "Debian", "source": "Windows.Terminal.Wsl", "font": { "face": "Consolas" } },
            { "name": "Símbolo del sistema" }
        ]
    }
}
EOF
chk "state bad"                             test "$(lib "wt_font_state '$SB/wt/settings.json'")" = bad
lib "wt_set_font '$SB/wt/settings.json'" >/dev/null
chk "state ok after the fix"                test "$(lib "wt_font_state '$SB/wt/settings.json'")" = ok
chk "WSL profile override replaced"         python3 -c "import json,sys; d=json.load(open('$SB/wt/settings.json')); sys.exit(0 if d['profiles']['list'][2]['font']['face'].endswith('Powerline') else 1)"
chk "PowerShell profile left alone"         python3 -c "import json,sys; d=json.load(open('$SB/wt/settings.json')); sys.exit(0 if d['profiles']['list'][0]['font']['face']=='Cascadia Mono' else 1)"
chk "non-ASCII names kept"                  grep -q 'Símbolo del sistema' "$SB/wt/settings.json"
echo '{ // comment
 "profiles": {} }' > "$SB/wt/c.json"
chk "unreadable JSON → unknown (no fix)"    test "$(lib "wt_font_state '$SB/wt/c.json'")" = unknown

echo "== 7. doctor --fix asks, and only at a terminal"
git config --global credential.helper "$BROKEN"
out=$(bash "$SB/repo/olecharms.sh" doctor --fix < /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "no terminal: says to run it in one"     grep -q 'need your OK' <<< "$out"
chk "...and changes nothing"                 test "$(git config --global --get credential.helper)" = "$BROKEN"
out=$(printf 'n\nn\n' | script -qc "bash $SB/repo/olecharms.sh doctor --fix" /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
chk "terminal + 'n': asked, left as is"      bash -c 'grep -q "Remove the broken password helper" <<< "$1" && grep -q "Left as it is" <<< "$1"' _ "$out"
chk "...helper still there"                  test "$(git config --global --get credential.helper)" = "$BROKEN"
out=$(printf 'y\nn\n' | script -qc "bash $SB/repo/olecharms.sh doctor --fix" /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
chk "terminal + 'y': helper removed"         bash -c '! git config --global --get credential.helper >/dev/null'
chk "summary after the repairs"              grep -q 'After the repairs:' <<< "$out"
out=$(bash "$SB/repo/olecharms.sh" doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "plain doctor points at --fix"           grep -q "Run 'olecharms doctor --fix'" <<< "$out"
chk "clipboard line in doctor"               grep -q 'Clipboard:' <<< "$out"
GV=$(sed -n 's/^GENERATOR_VERSION=//p' "$SB/repo/olecharms.sh")
chk "generated loader has generator $GV"     grep -qx "# olecharms-generator: $GV" "$SB/repo/scripts/olecharms-shell.sh"
chk "wrapper reloads aliases after doctor"   grep -q 'alias|aliaslast|update|sync|doctor)' "$SB/repo/scripts/olecharms-shell.sh"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
