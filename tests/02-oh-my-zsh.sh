#!/bin/bash
# oh-my-zsh integration tests (sandboxed HOME, copy of the real oh-my-zsh)
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
unset XDG_DATA_HOME ZSH ZSH_CUSTOM
# Never touch the real Windows profile: vim home in the sandbox AND integration off
export OLECHARMS_WIN_VIM_HOME=$SB/winhome
# A copy of your oh-my-zsh (it writes caches into its own folder)
OMZ_SRC=$TEST_OMZ
[ -f "$OMZ_SRC/oh-my-zsh.sh" ] || { echo "SKIP: oh-my-zsh not found in $OMZ_SRC (set OLECHARMS_TEST_OMZ)"; exit 77; }
rsync -a --exclude .git "$OMZ_SRC/" "$S/omz/" || exit 1
bash -c "source '$SB/repo/lib.sh'; config_ensure >/dev/null; config_set windows_integration off; config_set daily_doctor off" >/dev/null 2>&1
grep -q '^windows_integration=off' "$H/.config/olecharms/config" || { echo "ABORT: could not disable Windows integration"; exit 1; }
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
lib() { bash -c "source '$SB/repo/lib.sh'; $1" 2>&1; }
L=$SB/repo/scripts/olecharms-shell.sh

# .zshrc like the user's: oh-my-zsh first, olecharms block appended after
cat > "$H/.zshrc" <<EOF
export ZSH="$S/omz"
ZSH_THEME="olecharms"
zstyle ':omz:update' mode disabled
plugins=(git common-aliases)
source \$ZSH/oh-my-zsh.sh
EOF
lib 'install_shell_commands' >/dev/null
zi() { (cd "$H" && ZDOTDIR=$H zsh -ic "$1" 2>&1 </dev/null); }

echo "== 1. loader after oh-my-zsh (zsh -i)"
out=$(zi 'functions switchsshkey')
chk "omz alias cp='cp -i' is defined"      grep -q "cp -i" <<< "$(zi 'alias cp')"
chk "ssk body has plain cp, not cp -i"     bash -c "grep -q 'cp \"' <<< \"\$1\" && ! grep -q 'cp -i' <<< \"\$1\"" _ "$out"
chk "aliases option still on afterwards"   test "$(zi '[[ -o aliases ]] && echo on')" = on
chk "null_glob not leaked"                 test "$(zi '[[ -o null_glob ]] && echo on || echo off')" = off
chk "omz git alias usable (gst)"           grep -q 'git status' <<< "$(zi 'alias gst')"
chk "wrapper defined"                      grep -q function <<< "$(zi 'whence -w olecharms')"
chk "no startup errors"                    test -z "$(zi 'true')"

echo "== 2. bash -i with an alias defined before the loader"
printf 'alias cp="cp -i"\n' > "$H/.bashrc.pre"
cat "$H/.bashrc.pre" "$H/.bashrc" > "$H/.bashrc.new" && mv "$H/.bashrc.new" "$H/.bashrc"
bout=$(cd "$H" && bash -ic 'type switchsshkey; shopt expand_aliases' 2>&1 </dev/null)
chk "bash: function body has plain cp"     bash -c "! grep -q 'cp -i' <<< \"\$1\"" _ "$bout"
chk "bash: expand_aliases restored"        grep -qE 'expand_aliases\s+on' <<< "$bout"

echo "== 3. empty shell/ dir"
mkdir -p "$SB/shell.off"; mv "$SB/repo/shell/"*.sh "$SB/shell.off/"
eout=$(zsh -c "source '$L'; whence -w olecharms" 2>&1)
chk "zsh: no 'no matches found', wrapper loaded ($eout)" test "$eout" = "olecharms: function"
eout=$(bash -c "source '$L'; type -t olecharms" 2>&1)
chk "bash: wrapper loaded ($eout)"          test "$eout" = "function"
mv "$SB/shell.off/"*.sh "$SB/repo/shell/"

echo "== 4. alias add sees oh-my-zsh aliases through the wrapper"
aout=$(zi 'olecharms alias add gst "git status -sb" <<< n')
echo "$aout" | grep -i note | sed 's/^/    /'
chk "note names the omz alias"             grep -q "gst is an alias for git status" <<< "$aout"
aout=$(zi 'olecharms alias add take "echo hi" <<< n')
chk "note names an omz function (take)"    grep -q "take is a shell function" <<< "$aout"
aout=$(zi 'olecharms alias add zzqq "echo hi" <<< n')
chk "no note for a free name"              bash -c "! grep -qi note <<< \"\$1\"" _ "$aout"
zi 'olecharms alias add gst "git status -sb" <<< y' >/dev/null
chk "user alias overrides omz gst"         test "$(zi 'alias gst')" = "gst='git status -sb'"

echo "== 5. loader sourced before oh-my-zsh is moved after it"
{ echo '# olecharms shell commands - do not remove this line'
  echo "[ -f \"$L\" ] && source \"$L\""
  cat <<EOF
export ZSH="$S/omz"
ZSH_THEME="olecharms"
zstyle ':omz:update' mode disabled
plugins=(git)
source \$ZSH/oh-my-zsh.sh
EOF
} > "$H/.zshrc"
chk "user alias lost to omz before fix"    test "$(zi 'alias gst')" = "gst='git status'"
dout=$(bash "$SB/repo/olecharms.sh" doctor 2>&1)
chk "doctor warns about the order"         grep -q "before oh-my-zsh" <<< "$dout"
bash "$SB/repo/olecharms.sh" doctor --fix >/dev/null 2>&1
chk "loader now after omz"                 bash -c "source '$SB/repo/lib.sh'; ! loader_before_omz '$H/.zshrc'"
chk "exactly one loader line"              test "$(grep -c 'olecharms-shell.sh' "$H/.zshrc")" -eq 1
chk "exactly one marker"                   test "$(grep -c 'olecharms shell commands' "$H/.zshrc")" -eq 1
chk "user alias wins after fix"            test "$(zi 'alias gst')" = "gst='git status -sb'"
dout=$(bash "$SB/repo/olecharms.sh" doctor 2>&1)
chk "doctor quiet about order now"         bash -c "! grep -q 'before oh-my-zsh' <<< \"\$1\"" _ "$dout"
lib 'install_shell_commands' >/dev/null
chk "install is a no-op when order is right" test "$(grep -c 'olecharms-shell.sh' "$H/.zshrc")" -eq 1

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
