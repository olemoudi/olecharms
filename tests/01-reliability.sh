#!/bin/bash
# Runs the fixes against the sandbox built by setup.sh. Never touches real HOME/crontab.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home D=$SB/win/Downloads
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
# files can be back-dated (mtime) but not their ctime
export OLECHARMS_TEST_IGNORE_CTIME=1
unset XDG_DATA_HOME
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$SB/repo/lib.sh'; $1" 2>&1; }

echo "== 1. downloads cleanup through a symlinked folder (WSL /mnt/c case)"
lib 'config_ensure >/dev/null; enable_downloads_cleanup "$HOME/downloads" hook 30' >/dev/null
CS=$SB/repo/scripts/cleanup-downloads.sh
chk "cleanup script generated & executable" test -x "$CS"
bash "$CS"; echo "  exit=$?"
chk "old file deleted via symlink"     test ! -e "$D/old1.zip"
chk "old file in subdir deleted"       test ! -e "$D/sub/old2.pdf"
chk "desktop.ini kept"                 test -e "$D/desktop.ini"
chk ".localized kept"                  test -e "$D/.localized"
chk "new file kept"                    test -e "$D/new.txt"
chk "fresh empty dir kept"            test -d "$D/emptydir"
chk "dir emptied by the run removed"  test ! -d "$D/sub"
chk "downloads symlink itself kept"    test -L "$H/downloads"
chk "hook line in .bashrc"             grep -q olecharms-hook.sh "$H/.bashrc"
chk "hook line in .zshrc"              grep -q olecharms-hook.sh "$H/.zshrc"
chk "hook has downloads entry"         grep -q cleanup-downloads.sh "$SB/repo/scripts/olecharms-hook.sh"
chk "no tmp files left"                bash -c "! ls '$SB/repo/scripts/' | grep -q tmp"

echo "== 2. cleanup refuses a folder that resolves to HOME"
ln -s "$H" "$SB/homelink"; touch -d '60 days ago' "$H/precious.txt"
lib 'config_ensure >/dev/null; config_set downloads_cleanup_dir "'"$SB"'/homelink"'
bash "$CS"; rc=$?; chk "exit 1 on HOME via symlink (got $rc)" test "$rc" -eq 1
chk "precious file in HOME survives"   test -e "$H/precious.txt"
chk "skip is logged"                   grep -q 'skipped' "$H/.local/state/olecharms/cleanup.log"
lib 'config_ensure >/dev/null; config_set downloads_cleanup_dir "$HOME/downloads"'

echo "== 3. hook: no job-control noise, survives corrupt timestamp (zsh + bash)"
HK=$SB/repo/scripts/olecharms-hook.sh
mkdir -p "$SB/repo/scripts/.last-run"; : > "$SB/repo/scripts/.last-run/downloads-cleanup"
printf 'source %q\n' "$HK" > "$SB/z.rc"; mkdir -p "$SB/zd"; cp "$SB/z.rc" "$SB/zd/.zshrc"
out=$( (sleep 1; echo 'sleep 0.5; exit') | ZDOTDIR=$SB/zd script -qc "zsh -i" /dev/null 2>&1 | tr -d '\r')
chk "zsh: no '[n] pid' or 'done' notice" bash -c "! grep -qE '^\[[0-9]+\]|done|bad math|error' <<< \"\$1\"" _ "$out"
chk "timestamp rewritten as number"     grep -qE '^[0-9]+$' "$SB/repo/scripts/.last-run/downloads-cleanup"
echo garbage > "$SB/repo/scripts/.last-run/downloads-cleanup"
out=$( (sleep 1; echo 'sleep 0.5; exit') | script -qc "bash --rcfile $SB/z.rc -i" /dev/null 2>&1 | tr -d '\r')
chk "bash: no job notice / arithmetic error" bash -c "! grep -qE '\[[0-9]+\]|Done|syntax error' <<< \"\$1\"" _ "$out"

echo "== 4. hook -> cron switch: hook entry dropped, crontab written once"
lib 'config_ensure >/dev/null; enable_downloads_cleanup "$HOME/downloads" cron 30' | sed 's/^/    /'
chk "crontab has entry"                grep -q 'olecharms:downloads-cleanup' "$CRON_FILE"
chk "hook no longer runs the cleanup"  bash -c "! grep -q cleanup-downloads.sh '$HK'"
chk "hook kept for the daily doctor"   grep -q doctor-daily.sh "$HK"
w1=$(wc -l < "$CRON_FILE.writes")
lib 'config_ensure >/dev/null; restore_scheduled_features' >/dev/null
lib 'config_ensure >/dev/null; restore_scheduled_features' >/dev/null
w2=$(wc -l < "$CRON_FILE.writes")
chk "restore x2 did not rewrite crontab ($w1 -> $w2)" test "$w1" -eq "$w2"
echo "0 5 * * * /usr/bin/backup-job  # user job" >> "$CRON_FILE"
CRON_FAIL=1 lib 'config_ensure >/dev/null; cron_replace_entry "# olecharms:downloads-cleanup" ""' | sed 's/^/    /'
chk "unreadable crontab not wiped"     grep -q backup-job "$CRON_FILE"
lib 'config_ensure >/dev/null; enable_downloads_cleanup "$HOME/downloads" hook 30' >/dev/null
chk "back to hook: cron entry gone"    bash -c "! grep -q olecharms '$CRON_FILE'"
chk "back to hook: user job kept"      grep -q backup-job "$CRON_FILE"
chk "back to hook: hook line back"     grep -q olecharms-hook.sh "$H/.bashrc"

echo "== 5. stale generated scripts refreshed on restore"
echo '#!/bin/bash' > "$CS"; echo 'echo OLD' >> "$CS"
lib 'config_ensure >/dev/null; restore_scheduled_features' >/dev/null
chk "cleanup script regenerated"       grep -q 'cleanup --scheduled' "$CS"

echo "== 6. unreachable downloads dir does not disable the feature"
mv "$D" "$SB/win/Downloads.off"
out=$(lib 'config_ensure >/dev/null; restore_scheduled_features')
echo "$out" | sed 's/^/    /'
chk "config still enabled"            grep -q '^downloads_cleanup_enabled=true' "$H/.config/olecharms/config"
mv "$SB/win/Downloads.off" "$D"

echo "== 7. aliases (gawk and mawk)"
for AWKBIN in gawk mawk; do
  mkdir -p "$SB/awk-$AWKBIN"; ln -sf "$(command -v $AWKBIN)" "$SB/awk-$AWKBIN/awk"
  rm -f "$H/.config/olecharms/aliases"
  PATH="$SB/awk-$AWKBIN:$PATH" lib '
    echo | alias_add gas "git add -A" >/dev/null
    echo | alias_add g.s "git status" >/dev/null
    echo | alias_delete g.s >/dev/null
    alias_list_raw' > "$SB/al.$AWKBIN"
  qcmd="echo 'it'\\''s' && echo \"x\" | sed 's/a/b/'"
  echo | PATH="$SB/awk-$AWKBIN:$PATH" bash "$SB/repo/olecharms.sh" alias add q "$qcmd" >/dev/null
  got=$(PATH="$SB/awk-$AWKBIN:$PATH" lib 'alias_get q')
  chk "$AWKBIN: gas survives deleting g.s"  grep -qP '^gas\tgit add -A$' "$SB/al.$AWKBIN"
  chk "$AWKBIN: g.s deleted"                bash -c "! grep -q '^g\.s' '$SB/al.$AWKBIN'"
  chk "$AWKBIN: quotes round-trip exactly"  test "$got" = "$qcmd"
  chk "$AWKBIN: alias file sources in zsh"  zsh -c "source '$H/.config/olecharms/aliases'"$'\n'"alias q >/dev/null"
done
lib 'echo | alias_add bad "$(printf "a\tb")"' >/dev/null; chk "tab in command rejected" test $? -ne 0
bash "$SB/repo/olecharms.sh" alias delete nosuch >/dev/null 2>&1; chk "exit !=0 for failing alias cmd" test $? -ne 0

echo "== 8. backup of a symlinked vimrc is a real file"
echo 'set nu' > "$SB/dotfiles-vimrc"; ln -sf "$SB/dotfiles-vimrc" "$H/.vimrc"
lib 'backup_file "$HOME/.vimrc"' >/dev/null
b=$(ls "$H"/.vimrc.backup.* | head -1)
chk "backup is a regular file, not a link" test -f "$b" -a ! -L "$b"

echo "== 9. check: fonts with spaces in file names"
mkdir -p "$H/.local/share/fonts"; cp "$SB/repo/vimthings/fonts/powerline/DejaVuSansMono/"*.ttf "$H/.local/share/fonts/"
out=$(bash "$SB/repo/olecharms.sh" check 2>&1 | grep DejaVu)
echo "    $out"
chk "check sees DejaVuSansMono" grep -q '✓' <<< "$out"

echo "== 10. config with CRLF"
sed -i 's/$/\r/' "$H/.config/olecharms/config"
chk "CRLF value parsed" test "$(lib 'config_read; config_get downloads_cleanup_enabled')" = true

echo "== 11. switchsshkey (the shell functions, through bin/ssk)"
export _olecharms_bin=$SB/repo/olecharms.sh
mkdir -p "$H/.ssh"; echo PRIV-ORIG > "$H/.ssh/id_ed25519"; echo "ssh-ed25519 ORIG" > "$H/.ssh/id_ed25519.pub"
out=$(zsh -c "source '$SB/repo/shell/switchsshkey.sh'; ssk list; echo rc=\$?" 2>&1)
chk "zsh: list with no keys ok ($out)" test "$out" = "rc=0"
printf -- '-----BEGIN KEY\nWORK\n' > "$SB/w"; echo "ssh-ed25519 WORK" > "$SB/w.pub"
zsh -c "source '$SB/repo/shell/switchsshkey.sh'; ssk add work '$SB/w' '$SB/w.pub' && ssk work" 2>&1 | sed 's/^/    /'
chk "unsaved original key backed up"   grep -q PRIV-ORIG "$H"/.ssh/backup-*.privatekey
chk "switched to work"                 grep -q WORK "$H/.ssh/id_ed25519"
n=$(ls "$H"/.ssh/backup-* | wc -l)
bash -c "source '$SB/repo/shell/switchsshkey.sh'; ssk work" >/dev/null 2>&1
chk "no extra backup when key is named" test "$(ls "$H"/.ssh/backup-* | wc -l)" -eq "$n"
bash -c "source '$SB/repo/shell/switchsshkey.sh'; ssk add ../evil '$SB/w' '$SB/w.pub'" >/dev/null 2>&1
chk "path-like key name rejected"      test ! -e "$H/evil.pubkey"
unset _olecharms_bin

echo "== 12. generated loader works in zsh and bash"
lib 'install_shell_commands' >/dev/null
for sh in zsh bash; do
  chk "$sh: loader defines olecharms + mkcd" $sh -c "source '$SB/repo/scripts/olecharms-shell.sh'; type olecharms >/dev/null && type mkcd >/dev/null"
done

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
