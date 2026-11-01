#!/bin/bash
# Shared settings, secrets, zsh extras, bootstrap
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
unset XDG_DATA_HOME ZSH ZSH_CUSTOM
export OLECHARMS_WIN_VIM_HOME=$SB/winhome
bash -c "source '$SB/repo/lib.sh'; config_ensure >/dev/null; config_set windows_integration off; config_set daily_doctor off" >/dev/null 2>&1
grep -q '^windows_integration=off' "$H/.config/olecharms/config" || { echo "ABORT: could not disable Windows integration"; exit 1; }
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$SB/repo/lib.sh'; config_ensure >/dev/null 2>&1; $1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
O="bash $SB/repo/olecharms.sh"
CFG=$H/.config/olecharms/config
git config --global user.name tester; git config --global user.email t@t

# checkout with a bare remote, as on a real machine
git init -q --bare "$SB/remote.git"
( cd "$SB/repo" && git init -q -b master && git add -A >/dev/null && git commit -qm init &&
  git remote add origin "file://$SB/remote.git" && git push -q -u origin master 2>/dev/null )

echo "== 1. shared settings"
chk "no shared file: no differences"       test -z "$(lib 'shared_differences')"
lib 'config_set downloads_cleanup_max_age_days 365; config_set daily_doctor on; config_set downloads_cleanup_quarantine_days 45' >/dev/null
out=$(printf 'y\n' | lib 'shared_publish')
chk "publish asks and reports"             grep -q 'Shared: your other machines' <<< "$out"
chk "shared-config committed and pushed"   test "$(git --git-dir="$SB/remote.git" show master:shared-config | grep -c '=')" -eq 7
chk "values written"                       bash -c 'grep -qx "daily_doctor=on" "$1/repo/shared-config" && grep -qx "downloads_cleanup_quarantine_days=45" "$1/repo/shared-config"' _ "$SB"
chk "only that file in the commit"         test "$(git -C "$SB/repo" show --name-only --format= HEAD)" = shared-config
chk "follows right after publishing"       test -z "$(lib 'shared_differences')"
# another machine's choices arrive
sed -i 's/^daily_doctor=on/daily_doctor=off/; s/^zsh_extras=on/zsh_extras=off/; s/^downloads_cleanup_max_age_days=365/downloads_cleanup_max_age_days=90/' "$SB/repo/shared-config"
d=$(lib 'shared_differences' | tr '\n' ' ')
chk "differences listed ($d)"              test "$d" = "daily_doctor zsh_extras "
chk "age ignored while cleanup off on both" bash -c '! grep -q max_age <<< "$1"' _ "$d"
chk "summary in words"                     grep -q 'daily health check on here, daily health check off shared' <<< "$(lib 'shared_differences_summary')"
out=$(lib 'shared_apply' < /dev/null)
chk "no terminal: describes, changes nothing" bash -c 'grep -q "differ here" <<< "$1" && grep -qx "daily_doctor=on" "$2"' _ "$out" "$CFG"
d=$($O doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "doctor warns about the differences"   grep -q 'differs from your shared settings' <<< "$d"
out=$(printf 'y\nk\n' | script -qc "bash -c \"source '$SB/repo/lib.sh'; shared_apply\"" /dev/null 2>&1 | tr -d '\r')
chk "y applies (daily doctor off)"         grep -qx 'daily_doctor=off' "$CFG"
chk "k keeps this machine different"       grep -q '^shared_keep_local=.*zsh_extras' "$CFG"
chk "nothing left to differ"               test -z "$(lib 'shared_differences')"
chk "seen fingerprint stored"              test -s "$H/.local/state/olecharms/shared-seen"
chk "offer after pull: quiet when seen"    test -z "$(lib 'shared_offer_after_pull' < /dev/null)"
sed -i 's/^downloads_cleanup_quarantine_days=45/downloads_cleanup_quarantine_days=10/' "$SB/repo/shared-config"
lib 'config_set downloads_cleanup_enabled true' >/dev/null
out=$(lib 'shared_offer_after_pull' < /dev/null)
chk "offer after pull: speaks up on change" grep -q 'quarantine kept 45 days here, quarantine kept 10 days shared' <<< "$out"
chk "...without applying anything"         grep -qx 'downloads_cleanup_quarantine_days=45' "$CFG"
lib 'config_set downloads_cleanup_enabled false' >/dev/null
git -C "$SB/repo" checkout -q -- shared-config
printf 'y\n' | lib 'shared_publish' >/dev/null
out=$(printf 'y\n' | lib 'shared_publish'; echo "rc=$?")
chk "sharing unchanged settings is fine"   bash -c 'grep -q "Shared: your other machines" <<< "$1" && ! grep -q "Could not commit" <<< "$1"' _ "$out"

echo "== 2. secrets"
echo "v a'l \$x" | $O secret set MY_TOKEN >/dev/null 2>&1
SF=$H/.config/olecharms/secrets
chk "stored with mode 600"                 test "$(ls -ln "$SF" | cut -c1-10)" = '-rw-------'
chk "value round-trips through the shell"  test "$(bash -c ". '$SF'; printf %s \"\$MY_TOKEN\"")" = "v a'l \$x"
chk "zsh reads it the same"                test "$(zsh -c ". '$SF'; printf %s \"\$MY_TOKEN\"")" = "v a'l \$x"
echo second | $O secret set MY_TOKEN >/dev/null 2>&1
chk "set again replaces"                   test "$(grep -c MY_TOKEN "$SF")" -eq 1
out=$($O secret list 2>&1)
chk "list shows names, never values"       bash -c 'grep -q MY_TOKEN <<< "$1" && ! grep -q second <<< "$1"' _ "$out"
chk "PATH refused"                         bash -c '! echo x | $1 secret set PATH >/dev/null 2>&1' _ "$O"
chk "bad name refused"                     bash -c '! echo x | $1 secret set "a-b" >/dev/null 2>&1' _ "$O"
$O secret rm MY_TOKEN >/dev/null 2>&1
chk "rm forgets it"                        bash -c '! grep -q MY_TOKEN "$1"' _ "$SF"
chk "rm of unknown name fails"             bash -c '! $1 secret rm NOPE_TOKEN >/dev/null 2>&1' _ "$O"
cat >> "$H/.zshrc" <<'EOF'
export OPENAI_API_KEY="sk-123"
GITHUB_TOKEN=abc   # comment
KEYTIMEOUT=1
export TOKEN_FILE=$HOME/x
  export INDENTED_TOKEN=x
export A_PASSWORD='p w'
export DB_PASS=$(pass show db)
echo keep-me
EOF
cp "$H/.zshrc" "$SB/zshrc.before"
scan=$(lib 'secret_scan' | cut -f3 | tr '\n' ' ')
chk "scan finds literal secrets ($scan)"   test "$scan" = "OPENAI_API_KEY GITHUB_TOKEN A_PASSWORD "
d=$($O doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "doctor names them"                    grep -q 'Secrets in plain text in your shell startup files: OPENAI_API_KEY (~/.zshrc)' <<< "$d"
chk "doctor never prints the values"       bash -c '! grep -qE "sk-123|p w|abc" <<< "$1"' _ "$d"
lib 'secret_import yes' > "$SB/import.out"
chk "import output has no values"          bash -c '! grep -qE "sk-123|p w" "$1"' _ "$SB/import.out"
chk "lines left .zshrc"                    bash -c '! grep -qE "OPENAI_API_KEY|GITHUB_TOKEN|A_PASSWORD" "$1/.zshrc"' _ "$H"
chk "one line now loads the secrets file"  test "$(grep -c '# olecharms secrets$' "$H/.zshrc")" -eq 1
chk "...in place of the first moved line"  test "$(grep -n '# olecharms secrets$' "$H/.zshrc" | cut -d: -f1)" = "$(grep -n '^export OPENAI_API_KEY' "$SB/zshrc.before" | cut -d: -f1)"
chk "everything else kept"                 test "$(grep -vE '^(export OPENAI_API_KEY|GITHUB_TOKEN|export A_PASSWORD)' "$SB/zshrc.before")" = "$(grep -v '# olecharms secrets$' "$H/.zshrc")"
chk ".zshrc still sources fine"            zsh -n "$H/.zshrc"
printf 'export GH_TOKEN=ghp1\nexport COPY_OF=$GH_TOKEN\n' > "$H/.profile"
lib 'secret_import yes' >/dev/null
chk "later lines still see the secret"     test "$(bash -c '. "$HOME/.profile"; echo "$COPY_OF"')" = ghp1
chk "...and .profile no longer holds it"   bash -c '! grep -q ghp1 "$1/.profile"' _ "$H"
rm -f "$H/.profile"
chk "values in the secrets file"           test "$(bash -c ". '$SF'; echo \"\$OPENAI_API_KEY|\$GITHUB_TOKEN|\$A_PASSWORD\"")" = 'sk-123|abc|p w'
chk "no .zshrc backup with the secret"     bash -c '! grep -lqs sk-123 "$1"/.zshrc.backup.* ' _ "$H"
printf 'if true; then\nexport X_TOKEN=abc\nfi\n' >> "$H/.bashrc"
cp "$H/.bashrc" "$SB/bashrc.before"
lib 'secret_import yes' >/dev/null
chk "line inside a block: not offered"     bash -c '! grep -q X_TOKEN <<< "$1"' _ "$(lib secret_scan)"
chk "...and the file is intact"            cmp -s "$H/.bashrc" "$SB/bashrc.before"
lib 'secret_rm X_TOKEN' >/dev/null
printf 'export LEAK_TOKEN=zzz\n' > "$H/.zshrc.backup.20200101_000000"; chmod 644 "$H/.zshrc.backup.20200101_000000"
lib 'echo y | secret_set LEAK_TOKEN' >/dev/null
d=$($O doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "doctor: old backup readable by others" grep -q 'old backup(s) of your RC files hold secrets' <<< "$d"
lib 'secret_backups_private'
chk "backup made private"                  test "$(ls -ln "$H/.zshrc.backup.20200101_000000" | cut -c1-10)" = '-rw-------'
chmod 644 "$SF"
d=$($O doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "doctor: secrets file mode"            grep -q 'secrets file can be read by others' <<< "$d"
chmod 600 "$SF"
sed -i '/^if true; then$/,/^fi$/d' "$H/.bashrc"

echo "== 3. loader: secrets, zsh extras, fzf"
lib 'install_shell_commands' >/dev/null
L=$SB/repo/scripts/olecharms-shell.sh
cat > "$H/.zshrc" <<EOF
source "$L"
EOF
chk "zsh -i has the secrets"               test "$(cd "$H" && ZDOTDIR=$H zsh -ic 'echo $OPENAI_API_KEY' 2>/dev/null </dev/null)" = sk-123
chk "non-interactive zsh loads no extras"  test -z "$(zsh -c "source '$L'; echo \$fzf_loaded" 2>/dev/null)"
# fake plugins and a fake fzf
for p in zsh-autosuggestions zsh-syntax-highlighting; do
    mkdir -p "$SB/src/$p" && ( cd "$SB/src/$p" && git init -q -b master &&
        case $p in
            zsh-autosuggestions) echo '_zsh_autosuggest_start() { :; }; zas_loaded="$ZSH_AUTOSUGGEST_STRATEGY"' ;;
            *) echo 'ZSH_HIGHLIGHT_VERSION=fake; zsh_hl_after_zas=${zas_loaded:+yes}' ;;
        esac > "$p.zsh" && git add . && git commit -qm v1 )
done
out=$(lib "ZSH_EXTRA_PLUGINS=(\"zsh-autosuggestions|file://$SB/src/zsh-autosuggestions\" \"zsh-syntax-highlighting|file://$SB/src/zsh-syntax-highlighting\"); install_zsh_extras")
chk "plugins cloned"                       test -f "$H/.local/share/olecharms/zsh-plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
cat > "$SB/bin/fzf" <<'EOF'
#!/bin/bash
case "$1" in
  --zsh)  echo 'fzf_loaded=zsh' ;;
  --bash) echo 'fzf_loaded=bash' ;;
  --version) echo '0.99 (fake)' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SB/bin/fzf"
z=$(cd "$H" && ZDOTDIR=$H zsh -ic 'echo "$fzf_loaded|$zas_loaded|$zsh_hl_after_zas"' 2>/dev/null </dev/null)
chk "zsh: fzf, suggestions, colours ($z)"  test "$z" = 'zsh|history completion|yes'
b=$(cd "$H" && bash --rcfile <(echo "source '$L'") -ic 'echo "$fzf_loaded|$zas_loaded"' 2>/dev/null </dev/null | tail -n 1)
chk "bash: fzf only ($b)"                  test "$b" = 'bash|'
lib 'config_set zsh_extras off; install_shell_commands' >/dev/null
z=$(cd "$H" && ZDOTDIR=$H zsh -ic 'echo "$fzf_loaded|$zas_loaded"' 2>/dev/null </dev/null)
chk "extras off: nothing loaded ($z)"      test "$z" = '|'
lib 'config_set zsh_extras on; install_shell_commands' >/dev/null
d=$($O doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
chk "doctor: fzf ok"                       grep -q 'fzf 0.99: Ctrl-R history' <<< "$d"
chk "doctor: zsh plugins ok"               grep -q 'Suggestions as you type and syntax colours' <<< "$d"
out=$(echo zz | script -qc "zsh -c \"source '$L'; olecharms secret set WRAP_TOKEN <<< zz >/dev/null 2>&1; echo got=\\\$WRAP_TOKEN\"" /dev/null 2>&1 | tr -d '\r')
chk "wrapper loads a new secret at once"   grep -qx 'got=zz' <<< "$out"
rm -f "$SB/bin/fzf"
lib 'secret_rm WRAP_TOKEN; secret_rm LEAK_TOKEN' >/dev/null

echo "== 4. bootstrap"
mkdir -p "$SB/fake" && ( cd "$SB/fake" && git init -q -b master &&
    printf '#!/bin/bash\necho "FAKE $* tty=$([ -t 0 ] && echo yes || echo no)"\n' > olecharms.sh && git add . && git commit -qm f )
out=$(OLECHARMS_REPO="file://$SB/fake" OLECHARMS_DIR="$SB/boot/olecharms" bash "$SB/repo/bootstrap.sh" 2>&1)
echo "$out" | sed 's/^/    | /'
chk "clones and runs install"              bash -c 'grep -q "Cloning" <<< "$1" && grep -q "^FAKE install" <<< "$1"' _ "$out"
out=$(OLECHARMS_REPO="file://$SB/fake" OLECHARMS_DIR="$SB/boot/olecharms" bash "$SB/repo/bootstrap.sh" 2>&1)
chk "second run updates instead of cloning" bash -c 'grep -q "already at" <<< "$1" && grep -q "^FAKE install" <<< "$1"' _ "$out"
mkdir -p "$SB/boot/other" && touch "$SB/boot/other/x"
out=$(OLECHARMS_REPO="file://$SB/fake" OLECHARMS_DIR="$SB/boot/other" bash "$SB/repo/bootstrap.sh" 2>&1); rc=$?
chk "refuses a non-checkout folder"        bash -c '[ "$1" -ne 0 ] && grep -q "not an olecharms checkout" <<< "$2" && [ -f "$3" ]' _ "$rc" "$out" "$SB/boot/other/x"
out=$(cat "$SB/repo/bootstrap.sh" | script -qc "OLECHARMS_REPO=file://$SB/fake OLECHARMS_DIR=$SB/boot/olecharms bash" /dev/null 2>&1 | tr -d '\r')
chk "curl|bash: install reads the terminal" grep -q 'FAKE install tty=yes' <<< "$out"

out=$(python3 -c "
import socket, subprocess, os
a, b = socket.socketpair()
r = subprocess.run(['bash', '$SB/repo/bootstrap.sh'], stdin=a, capture_output=True, text=True,
    env=dict(os.environ, OLECHARMS_REPO='file://$SB/fake', OLECHARMS_DIR='$SB/boot/sock/olecharms'))
print(r.stdout + r.stderr)")
chk "stdin is a socket: still runs install" grep -q '^FAKE install' <<< "$out"

echo "== 5. review fixes: Windows Terminal Store profile, Vim edge cases"
mkdir -p "$SB/wt"
cat > "$SB/wt/s.json" <<'EOF'
{ "profiles": { "defaults": {}, "list": [
  { "name": "Ubuntu", "source": "CanonicalGroupLimited.UbuntuonWindows_79rhkp1fndgsc", "fontFace": "Consolas" },
  { "name": "MyDistro", "commandline": "C:/x.exe" } ] } }
EOF
chk "Store Ubuntu profile counts as WSL"   test "$(lib "wt_font_state '$SB/wt/s.json'")" = bad
lib "wt_set_font '$SB/wt/s.json'" >/dev/null
chk "...and gets the font"                 test "$(lib "wt_font_state '$SB/wt/s.json'")" = ok
cat > "$SB/wt/d.json" <<'EOF'
{ "profiles": { "defaults": { "font": { "face": "DejaVu Sans Mono for Powerline" } }, "list": [
  { "name": "MyDistro", "commandline": "C:/x.exe", "fontFace": "Consolas" } ] } }
EOF
chk "profile named like the distro: bad"   test "$(WSL_DISTRO_NAME=MyDistro lib "wt_font_state '$SB/wt/d.json'")" = bad
chk "...other distro name: not WSL, ok"    test "$(WSL_DISTRO_NAME=Other lib "wt_font_state '$SB/wt/d.json'")" = ok
CF=$SB/cf9
printf 'uno\ndos\n' > "$SB/v9.txt"
vrun() { (cd "$SB" && TERM=xterm vim -Nu "$SB/repo/vimthings/olevimrc.vim" -i NONE -n -es v9.txt "$@" +'qa!' >/dev/null 2>&1); }
rm -f "$CF"; OLECHARMS_CLIP_FILE=$CF vrun +'exe "normal gg\"+\<Esc>dd"'
chk "cancelled \"+ then dd: not copied"     test ! -e "$CF"
rm -f "$CF"; OLECHARMS_CLIP_FILE=$CF vrun +'normal ggyy' +'normal ggviwyP'
chk "yank still copies"                    test -e "$CF"
printf 'CLIP' > "$CF"; OLECHARMS_CLIP_FILE=$CF vrun +'normal ggviw"+p' +'sleep 300m'
chk "visual \"+p does not copy the replaced text back" test "$(cat "$CF")" = CLIP
(cd "$SB" && OLECHARMS_CLIP_BACKEND=none TERM=xterm vim -Nu "$SB/repo/vimthings/olevimrc.vim" -i NONE -n -es v9.txt +'normal yy' +'normal jyy' +'redir! > none.txt | silent messages | redir END' +'qa!' >/dev/null 2>&1)
chk "no clipboard: one warning, not per yank" test "$(grep -c 'no system clipboard here' "$SB/none.txt")" -le 1

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
