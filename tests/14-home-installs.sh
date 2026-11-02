#!/bin/bash
# Installing without root: system packages when sudo cannot be used, the tools
# installed in your home instead (mise, npm, install scripts run from a file),
# npm's global prefix, the summary of what is missing, mise without Homebrew
# or GitHub, and MacVim. Everything external is a fake in $SB/fake: no test
# downloads anything or touches a real package manager.
. "$(dirname "$0")/lib/sandbox.sh" || exit 1
H=$SB/home R=$SB/repo L=$SB/home/.local/bin F=$SB/fake
export HOME=$H XDG_CONFIG_HOME=$H/.config PATH="$SB/bin:$PATH" CRON_FILE=$SB/crontab.txt
export OLECHARMS_WIN_VIM_HOME=$SB/winhome GIT_CONFIG_NOSYSTEM=1 SB
export OLECHARMS_MISE_SCRIPT=file://$SB/no-network/mise-install.sh
bash -c "source '$R/lib.sh'; config_ensure >/dev/null; config_set windows_integration off; config_set daily_doctor off" >/dev/null 2>&1
grep -q '^windows_integration=off' "$H/.config/olecharms/config" || { echo "ABORT: could not disable Windows integration"; exit 1; }
pass=0 fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
plain() { sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'; }
# The script as a library, with the fakes first on PATH
lib() { PATH="$F:$PATH" bash -c "source '$R/lib.sh'; detect_os; config_ensure >/dev/null 2>&1; $1" 2>&1 | plain; }
has() { grep -q -- "$1" <<< "$2"; }
mkdir -p "$F" "$L"
cd "$SB" || exit 1

# ── fakes ──
# dpkg / apt-get: only the packages in $INSTALLED count as installed
cat > "$F/dpkg-query" <<'EOF'
#!/bin/bash
for p in $INSTALLED; do [ "$p" = "${!#}" ] && { echo "install ok installed"; exit 0; }; done
exit 1
EOF
printf '#!/bin/sh\nexit 0\n' > "$F/dpkg"
printf '#!/bin/sh\necho "$*" >> "$SB/apt.log"\n' > "$F/apt-get"
# mise: `use -g aqua:x/NAME@latest` installs a NAME command, `which NAME` finds it
cat > "$F/mise" <<'EOF'
#!/bin/bash
echo "$*" >> "$SB/mise.log"
I=$HOME/.local/share/mise/installs
case "$1" in
    use)   [ -n "$MISE_FAIL" ] && { echo "mise: could not download $3" >&2; exit 1; }
           t=${3%@latest}; n=${t##*/}; mkdir -p "$I/$n/1.0.0"
           printf '#!/bin/sh\necho %s-from-mise\n' "$n" > "$I/$n/1.0.0/$n"; chmod +x "$I/$n/1.0.0/$n" ;;
    which) f=$(ls "$I"/*/*/"$2" 2>/dev/null | sort | tail -n 1); [ -n "$f" ] || exit 1; echo "$f" ;;
    --version) echo "2026.1.1 linux-x64" ;;
esac
EOF
# npm: its global prefix is ~/.npmrc's, else $NPM_SYS (read-only, like /usr)
cat > "$F/npm" <<'EOF'
#!/bin/bash
echo "$*" >> "$SB/npm.log"
rc=$HOME/.npmrc
p=$(sed -n 's/^prefix=//p' "$rc" 2>/dev/null); p=${p:-$NPM_SYS}
case "$1" in
    prefix) echo "$p" ;;
    config) if [ "$2 $3" = "set prefix" ]; then
                { grep -v '^prefix=' "$rc" 2>/dev/null; echo "prefix=$4"; } > "$rc.new" && mv "$rc.new" "$rc"
            fi ;;
    install) n=${!#}; n=${n##*/}
             mkdir -p "$p/bin" 2>/dev/null; [ -w "$p/bin" ] || { echo "npm error code EACCES" >&2; exit 243; }
             printf '#!/bin/sh\necho %s-from-npm\n' "$n" > "$p/bin/$n"; chmod +x "$p/bin/$n" ;;
esac
EOF
chmod +x "$F"/*
export NPM_SYS=$SB/sysnode
mkdir -p "$NPM_SYS/lib/node_modules" "$NPM_SYS/bin"; chmod 555 "$NPM_SYS/lib/node_modules" "$NPM_SYS/bin" "$NPM_SYS/lib" "$NPM_SYS"
mv "$F/mise" "$F/mise.off"     # mise only where a test puts it on PATH
withmise() { mv "$F/mise.off" "$F/mise" 2>/dev/null; }
nomise()   { mv "$F/mise" "$F/mise.off" 2>/dev/null; }

echo "== 1. system packages when sudo cannot be used"
out=$(INSTALLED="git" lib 'APT_PACKAGES=(git zz-pkg-a zz-pkg-b); install_packages </dev/null; echo "MISSING=${SYS_MISSING[*]} EC=$ERROR_COUNT"')
chk "no terminal, sudo needs a password: skipped" has "no terminal; skipping: zz-pkg-a zz-pkg-b" "$out"
chk "the skipped ones are left to the home installs" has "MISSING=zz-pkg-a zz-pkg-b EC=0" "$out"
chk "apt-get never ran"                     test ! -e "$SB/apt.log"
printf '#!/bin/sh\n' > "$L/zz-pkg-b"; chmod +x "$L/zz-pkg-b"
out=$(INSTALLED="git" lib 'APT_PACKAGES=(git zz-pkg-a zz-pkg-b); install_packages </dev/null; echo "MISSING=${SYS_MISSING[*]}"')
chk "a command already in your home needs no package" has "MISSING=zz-pkg-a$" "$out"
rm -f "$L/zz-pkg-b"
out=$(INSTALLED="git zz-pkg-a" lib 'APT_PACKAGES=(git zz-pkg-a); install_packages </dev/null')
chk "all installed: nothing asked"          has "All system packages already installed" "$out"
out=$(lib 'check_command() { case $1 in dpkg|apt-get) return 1 ;; esac; command -v "$1" >/dev/null 2>&1; }
           APT_PACKAGES=(git zz-pkg-a); install_packages; echo "MISSING=${SYS_MISSING[*]} EC=$ERROR_COUNT"')
chk "not Debian: missing judged by command, no error" bash -c 'grep -q "Not a Debian/Ubuntu system" <<< "$1" && grep -q "MISSING=zz-pkg-a EC=0" <<< "$1"' _ "$out"
out=$(lib 'OS=macos; BREW_PACKAGES=(git zz-pkg-a); install_packages; echo "MISSING=${SYS_MISSING[*]} EC=$ERROR_COUNT"')
chk "Mac without Homebrew: said, no error"  bash -c 'grep -q "Homebrew is not installed" <<< "$1" && grep -q "MISSING=zz-pkg-a EC=0" <<< "$1"' _ "$out"

echo "== 2. tools installed in your home with mise"
withmise
out=$(lib 'HOME_TOOLS=("zz-m|aqua:test/zz-m||"); install_home_tools; echo "I=${HOME_INSTALLED[*]} F=${HOME_FAILED[*]}"')
chk "installed with mise, in its global config" bash -c 'grep -q "^use -g aqua:test/zz-m@latest" "$1/mise.log" && grep -q "I=zz-m (mise) F=$" <<< "$2"' _ "$SB" "$out"
chk "linked into ~/.local/bin"              test "$(readlink "$L/zz-m")" = "$H/.local/share/mise/installs/zz-m/1.0.0/zz-m"
chk "the link runs it"                      test "$("$L/zz-m")" = "zz-m-from-mise"
chk "said what went where"                  has "Installed in your home: zz-m (mise)" "$out"
: > "$SB/mise.log"
out=$(lib 'HOME_TOOLS=("zz-m|aqua:test/zz-m||"); install_home_tools')
chk "already there: mise not asked again"   test ! -s "$SB/mise.log"
I=$H/.local/share/mise/installs/zz-m
mv "$I/1.0.0" "$I/2.0.0"
lib 'install_bin_links' >/dev/null
chk "a link mise's upgrade broke follows the new version" test "$(readlink "$L/zz-m")" = "$I/2.0.0/zz-m"
rm -rf "$I"
lib 'install_bin_links' >/dev/null
chk "removed when mise no longer has it"    test ! -L "$L/zz-m"
ln -s /nonexistent/mine "$L/zz-u"
out=$(lib 'HOME_TOOLS=("zz-u|aqua:test/zz-u||"); install_home_tools; echo "F=${HOME_FAILED[*]}"')
chk "a file of yours with that name is kept" bash -c '[ "$(readlink "$1/zz-u")" = /nonexistent/mine ] && grep -q "is yours" <<< "$2" && grep -q "F=zz-u" <<< "$2"' _ "$L" "$out"
rm -f "$L/zz-u"
out=$(MISE_FAIL=1 lib 'HOME_TOOLS=("zz-f|aqua:test/zz-f||"); install_home_tools; echo "F=${HOME_FAILED[*]} EC=$ERROR_COUNT"')
chk "mise fails: shown, reported, no error" bash -c 'grep -q "mise could not install zz-f" <<< "$1" && grep -q "could not download" <<< "$1" && grep -q "F=zz-f EC=0" <<< "$1"' _ "$out"
out=$(lib 'config_set mise off; HOME_TOOLS=("zz-o|aqua:test/zz-o||"); install_home_tools; echo "F=${HOME_FAILED[*]}"; config_set mise on')
chk "mise switched off: not used"           bash -c '! grep -q "zz-o" "$1/mise.log" && grep -q "F=zz-o" <<< "$2"' _ "$SB" "$out"
nomise

echo "== 3. npm: global installs into your home"
out=$(lib 'npm_home_prefix')
chk "npm's prefix needs root: ~/.npmrc points it at ~/.local" grep -qx "prefix=$H/.local" "$H/.npmrc"
chk "said so"                               has "npm install -g now installs into ~/.local" "$out"
chk "what it was is remembered"             grep -qx "$NPM_SYS" "$H/.local/state/olecharms/npm-prefix"
out=$(lib 'npm_home_prefix'); chk "second run: nothing to do" test -z "$out"
out=$(lib 'npm_install_global tldr; tool_available tldr && echo AVAILABLE')
chk "npm install -g lands in ~/.local/bin"  bash -c '[ "$("$1/tldr")" = tldr-from-npm ] && grep -q AVAILABLE <<< "$2"' _ "$L" "$out"
out=$(lib 'agents_text')
chk "agents are told npm -g needs no sudo"  has "npm install -g <package>\` needs no sudo here" "$out"
out=$(lib 'HOME_TOOLS=("zz-n||zz-n|"); install_home_tools; echo "I=${HOME_INSTALLED[*]}"')
chk "a HOME_TOOLS npm entry"                has "I=zz-n (npm)" "$out"
rm -f "$H/.npmrc" "$H/.local/state/olecharms/npm-prefix"
printf 'fund=false\n' > "$H/.npmrc"
lib 'npm_home_prefix' >/dev/null
chk "your other npm settings kept, a backup made" bash -c 'grep -qx fund=false "$1/.npmrc" && grep -qx "prefix=$1/.local" "$1/.npmrc" && ls "$1"/.npmrc.backup.* >/dev/null 2>&1' _ "$H"
rm -f "$H"/.npmrc*
printf 'prefix=%s\n' "$NPM_SYS" > "$H/.npmrc"
out=$(lib 'npm_home_prefix; echo "rc=$?"')
chk "a prefix of yours is left alone"       bash -c 'grep -qx "prefix=$2" "$3/.npmrc" && grep -q "sets a prefix of its own" <<< "$1" && grep -q "rc=1" <<< "$1"' _ "$out" "$NPM_SYS" "$H"
rm -f "$H/.npmrc"; mkdir -p "$H/.nvm"; touch "$H/.nvm/nvm.sh"; echo x > "$H/.nvm/nvm.sh"
out=$(lib 'npm_home_prefix')
chk "nvm installed: no prefix (nvm refuses one)" bash -c '[ ! -e "$1/.npmrc" ] && grep -q "nvm is installed" <<< "$2"' _ "$H" "$out"
out=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; HOME_TOOLS=(); doctor_check_tools')
chk "doctor: npm -g needs root, and why it is left" bash -c 'grep -q "npm install -g needs root" <<< "$1" && grep -q "olecharms leaves it: nvm" <<< "$1"' _ "$out"
rm -rf "$H/.nvm"
out=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; HOME_TOOLS=(); doctor_check_tools; echo "OFFERS=${#DOC_OFFER_Q[@]}"')
chk "doctor: offers to fix it"              bash -c 'grep -q "doctor --fix (points it at ~/.local" <<< "$1" && grep -q "OFFERS=1" <<< "$1"' _ "$out"
lib 'npm_home_prefix' >/dev/null
out=$(lib 'DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; HOME_TOOLS=(); doctor_check_tools')
chk "doctor: npm -g into ~/.local, no sudo" has "npm install -g: into ~/.local, no sudo needed" "$out"
out=$(lib 'npm_home_prefix; npm_install_global tldr' 2>&1)
chk "npm on PATH is the sandbox's refusing one otherwise" bash -c 'PATH="$1/bin:/usr/bin:/bin" npm prefix -g 2>&1 | grep -q "disabled in the olecharms tests"' _ "$SB"
rm -f "$H/.npmrc" "$L/tldr" "$L/zz-n" "$H/.local/state/olecharms/npm-prefix"

echo "== 4. install scripts: downloaded to a file, then run, without root"
mkdir -p "$SB/scripts"
cat > "$SB/scripts/zz-s.sh" <<'EOF'
#!/bin/sh
echo "ran:$0" > "$SB/script.log"
if sudo true 2>> "$SB/script.log"; then echo SUDO-WORKED; else echo SUDO-REFUSED; fi >> "$SB/script.log"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho zz-s-from-script\n' > "$HOME/.local/bin/zz-s"; chmod +x "$HOME/.local/bin/zz-s"
EOF
out=$(lib "HOME_TOOLS=(\"zz-s|||file://$SB/scripts/zz-s.sh\"); install_home_tools; echo \"I=\${HOME_INSTALLED[*]}\"")
chk "installed by its script"               bash -c '[ "$("$1/zz-s")" = zz-s-from-script ] && grep -q "I=zz-s (install script)" <<< "$2"' _ "$L" "$out"
chk "run from a saved file, not a pipe"     grep -qx "ran:./install.sh" "$SB/script.log"
chk "its sudo refused: no root"             bash -c 'grep -q "without root" "$1" && grep -qx SUDO-REFUSED "$1"' _ "$SB/script.log"
chk "where it came from is said"            has "Running zz-s's install script (downloaded from file://" "$out"
printf '#!/bin/sh\necho "need a compiler" >&2\nexit 3\n' > "$SB/scripts/bad.sh"
out=$(lib "HOME_TOOLS=(\"zz-b|||file://$SB/scripts/bad.sh\"); install_home_tools; echo \"F=\${HOME_FAILED[*]} EC=\$ERROR_COUNT\"")
chk "a failing script: its words shown, no error" bash -c 'grep -q "its install script failed" <<< "$1" && grep -q "need a compiler" <<< "$1" && grep -q "F=zz-b EC=0" <<< "$1"' _ "$out"
out=$(lib 'run_install_script zz-h http://example.invalid/install.sh; echo "rc=$?"')
chk "plain http refused, nothing downloaded" bash -c 'grep -q "does not come over https" <<< "$1" && grep -q "rc=1" <<< "$1"' _ "$out"
out=$(lib "run_install_script zz-m file://$SB/scripts/none.sh; echo \"rc=\$?\"")
chk "a download that fails: nothing runs"   bash -c 'grep -q "could not download its install script" <<< "$1" && grep -q "rc=1" <<< "$1"' _ "$out"
chk "no pipe into a shell anywhere"         bash -c '! grep -nE "curl[^|#]*\|[[:space:]]*(ba)?sh\b" "$1/olecharms.sh" | grep -vE "^[0-9]+:[[:space:]]*#"' _ "$R"
rm -f "$L/zz-s"

echo "== 5. what could not be installed is reported, not an error"
out=$(lib 'SYS_MISSING=(git zz-x ripgrep-zz); HOME_FAILED=(zz-y); packages_summary; echo "EC=$ERROR_COUNT"')
chk "missing ones listed, present ones not" bash -c 'grep -q "Not installed: zz-x ripgrep-zz zz-y" <<< "$1" && ! grep -q "Not installed:.*git" <<< "$1"' _ "$out"
chk "a warning only"                        has "EC=0" "$out"
out=$(lib 'SYS_MISSING=(); HOME_FAILED=(); packages_summary')
chk "nothing missing: nothing said"         test -z "$out"
withmise
: > "$SB/apt.log"; rm -f "$SB/apt.log"
out=$(INSTALLED="git" lib 'APT_PACKAGES=(git zz-full); HOME_TOOLS=("zz-full|aqua:test/zz-full||"); install_packages </dev/null; install_home_tools; packages_summary; echo "EC=$ERROR_COUNT"')
chk "no sudo: the home install fills the gap" bash -c '[ -x "$1/zz-full" ] && ! grep -q "Not installed" <<< "$2" && grep -q "EC=0" <<< "$2"' _ "$L" "$out"
nomise

echo "== 6. mise on a Mac without Homebrew, and without GitHub"
arch=x64; case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; esac
REL=$SB/rel/v2026.3.0; mkdir -p "$REL"
printf '#!/bin/sh\necho "2026.3.0 macos-%s"\n' "$arch" > "$REL/mise-v2026.3.0-macos-$arch"
( cd "$REL" && sha256sum "mise-v2026.3.0-macos-$arch" > SHASUMS256.txt )
out=$(OLECHARMS_MISE_TAG=v2026.3.0 OLECHARMS_MISE_BASE="file://$SB/rel" lib 'OS=macos; install_mise')
chk "Mac without brew: the macOS release, checksum checked" bash -c '"$1/mise" --version | grep -q "macos" && grep -q "checksum verified" <<< "$2"' _ "$L" "$out"
rm -f "$L/mise" "$H/.local/state/olecharms/mise-version"
printf '#!/bin/sh\necho "brew $*" >> "%s/brew.log"\n' "$SB" > "$F/brew"; chmod +x "$F/brew"
out=$(OLECHARMS_MISE_TAG=v2026.3.0 OLECHARMS_MISE_BASE="file://$SB/rel" lib 'OS=macos; install_mise')
chk "Mac with brew: left to Homebrew"       test ! -e "$L/mise" -a -z "$out"
rm -f "$F/brew"
out=$(OLECHARMS_MISE_TAG=v2026.3.0 OLECHARMS_MISE_BASE="file://$SB/gone" lib 'install_mise')
chk "no GitHub: mise from npm's official package, into ~/.local" bash -c '[ "$("$1/mise")" = mise-from-npm ] && grep -q "install -g --no-fund --no-audit @jdxcode/mise" "$2/npm.log" && grep -q "mise installed with npm" <<< "$3"' _ "$L" "$SB" "$out"
rm -f "$L/mise" "$H/.npmrc" "$H/.local/state/olecharms/npm-prefix"
printf '#!/bin/sh\nmkdir -p "$HOME/.local/bin"\nprintf "#!/bin/sh\\necho script-mise\\n" > "$HOME/.local/bin/mise"\nchmod +x "$HOME/.local/bin/mise"\n' > "$SB/scripts/mise-run.sh"
mv "$F/npm" "$F/npm.off"
out=$(OLECHARMS_MISE_TAG=v2026.3.0 OLECHARMS_MISE_BASE="file://$SB/gone" OLECHARMS_MISE_SCRIPT="file://$SB/scripts/mise-run.sh" lib 'install_mise')
chk "no GitHub, no npm: mise's install script" bash -c '[ "$("$1/mise")" = script-mise ] && grep -q "by its install script" <<< "$2"' _ "$L" "$out"
: > "$SB/mise.log"
out=$(OLECHARMS_MISE_TAG=v2026.4.0 OLECHARMS_MISE_BASE="file://$SB/gone" lib 'install_mise')
chk "a mise installed that way is left alone" bash -c '[ "$("$1/mise")" = script-mise ] && [ -z "$2" ]' _ "$L" "$out"
rm -f "$L/mise"
mv "$F/npm.off" "$F/npm"

echo "== 7. MacVim"
out=$(lib 'OS=macos; sync_macvim_side; DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_macvim')
chk "not installed: skipped, doctor says how" bash -c 'grep -q "MacVim not found — skipping (install it with: olecharms macvim)" <<< "$1" && grep -q "MacVim is not installed" <<< "$1" && grep -q "olecharms macvim   (installs it in ~/Applications" <<< "$1"' _ "$out"
mkapp() {
    mkdir -p "$1/MacVim.app/Contents/MacOS" "$1/MacVim.app/Contents/bin"
    printf '#!/bin/sh\necho mvim "$@"\n' > "$1/MacVim.app/Contents/bin/mvim"; chmod +x "$1/MacVim.app/Contents/bin/mvim"
    printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>%s</string>\n</dict></plist>\n' "$2" > "$1/MacVim.app/Contents/Info.plist"
}
mkapp "$SB/dmg" 9.1.1234
cat > "$F/hdiutil" <<'EOF'
#!/bin/bash
echo "$*" >> "$SB/hdiutil.log"
case "$1" in
    attach) while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && mp=$2; shift; done; cp -R "$SB/dmg/MacVim.app" "$mp/" ;;
    detach) rm -rf "$2/MacVim.app" ;;
esac
EOF
printf '#!/bin/sh\nexit ${CODESIGN_RC:-0}\n' > "$F/codesign"
printf '#!/bin/sh\nexit ${SPCTL_RC:-0}\n' > "$F/spctl"
chmod +x "$F/hdiutil" "$F/codesign" "$F/spctl"
echo fake-image > "$SB/MacVim.dmg"
out=$(SPCTL_RC=1 OLECHARMS_MACVIM_URL="file://$SB/MacVim.dmg" lib 'OS=macos; cmd_macvim; echo "rc=$?"')
chk "not notarized: nothing installed"     bash -c '[ ! -e "$1/Applications/MacVim.app" ] && grep -q "not signed and notarized" <<< "$2" && grep -q "rc=1" <<< "$2"' _ "$H" "$out"
chk "the image was detached again"          grep -q "^detach" "$SB/hdiutil.log"
out=$(OLECHARMS_MACVIM_URL="file://$SB/MacVim.dmg" lib 'OS=macos; cmd_macvim; echo "rc=$?"')
chk "installed into ~/Applications, no admin" bash -c '[ -d "$1/Applications/MacVim.app/Contents/MacOS" ] && grep -q "MacVim 9.1.1234 installed in ~/Applications" <<< "$2" && grep -q "rc=0" <<< "$2"' _ "$H" "$out"
chk "mvim linked into ~/.local/bin"         test "$(readlink "$L/mvim")" = "$H/Applications/MacVim.app/Contents/bin/mvim"
out=$(lib 'OS=macos; cmd_macvim')
chk "second run: already installed"         has "MacVim 9.1.1234 is already installed (~/Applications/MacVim.app)" "$out"
out=$(lib 'OS=macos; DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_macvim; echo "W=$DOC_WARN F=$DOC_FAIL"')
chk "doctor: version, place, mvim"          bash -c 'grep -q "MacVim 9.1.1234 at ~/Applications/MacVim.app" <<< "$1" && grep -q "mvim opens files" <<< "$1" && grep -q "W=0 F=0" <<< "$1"' _ "$out"
rm -f "$L/mvim"
out=$(lib 'OS=macos; DOC_OK=0 DOC_WARN=0 DOC_FAIL=0; doctor_check_macvim')
chk "doctor: mvim missing, --fix links it"  has "mvim is not linked" "$out"
lib 'OS=macos; run_local_steps' >/dev/null
chk "doctor --fix's local steps link mvim"  test -L "$L/mvim"
rm -f "$L/mvim"; printf '#!/bin/sh\n' > "$F/mvim"; chmod +x "$F/mvim"
lib 'OS=macos; sync_macvim_side' >/dev/null
chk "another mvim on PATH: not shadowed"    test ! -e "$L/mvim"
rm -f "$F/mvim"
lib 'OS=macos; sync_macvim_side' >/dev/null
rm -rf "$H/Applications/MacVim.app"
lib 'install_bin_links' >/dev/null
chk "MacVim removed: its mvim link goes"    test ! -L "$L/mvim"
out=$(lib 'cmd_macvim; echo "rc=$?"')
chk "elsewhere than macOS: refused"         bash -c 'grep -q "only works on macOS" <<< "$1" && grep -q "rc=1" <<< "$1"' _ "$out"
out=$(lib 'OS=macos; cmd_help')
chk "help lists macvim on macOS"            has "macvim    Install MacVim" "$out"
out=$(lib 'cmd_help')
chk "and not elsewhere"                     bash -c '! grep -q "macvim  " <<< "$1"' _ "$out"
lib 'enable_paranoid_mode hook' >/dev/null
chk "paranoid mode counts MacVim as a running vim" grep -q "mvim|MacVim|Vim'" "$R/scripts/paranoid-cleanup.sh"
lib 'disable_paranoid_mode' >/dev/null
out=$(lib 'OS=macos; paranoid_print_targets')
chk "paranoid mode says MacVim's history goes too" has "~/.viminfo, MacVim too" "$out"

chmod -R u+w "$NPM_SYS"     # read-only like /usr: let the sandbox go
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
