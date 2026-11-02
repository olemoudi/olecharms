#!/bin/bash
# Run the olecharms test suites.
#
#   tests/run.sh                  every suite except the full update
#   tests/run.sh --full           also 09-full-update (WSL + network, slow)
#   tests/run.sh 05 07            only the suites whose names start that way
#   tests/run.sh --keep ...       keep the sandbox and logs afterwards
#
# Every suite works on a copy of this checkout with a fake HOME, crontab,
# sudo and npm (see tests/lib/sandbox.sh): your files, crontab, git config
# and packages are never touched. Needs Linux or WSL (GNU coreutils, util-linux
# `script`), plus bash, zsh, vim, git, python3 and rsync.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FULL="" KEEP="" ONLY=()
for a in "$@"; do
    case "$a" in
        --full) FULL=1 ;;
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $a (try --help)" >&2; exit 2 ;;
        *) ONLY+=("$a") ;;
    esac
done

missing=()
for c in bash zsh vim git python3 rsync script timeout; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
[ ${#missing[@]} -eq 0 ] || { echo "Missing: ${missing[*]}" >&2; exit 2; }
if ! touch -d '1 day ago' "${TMPDIR:-/tmp}/.olecharms-touch-check.$$" 2>/dev/null ||
   ! script -qc true /dev/null >/dev/null 2>&1; then
    rm -f "${TMPDIR:-/tmp}/.olecharms-touch-check.$$"
    echo "These tests need GNU coreutils and util-linux (Linux or WSL)." >&2
    exit 2
fi
rm -f "${TMPDIR:-/tmp}/.olecharms-touch-check.$$"

T=$(mktemp -d "${TMPDIR:-/tmp}/olecharms-test.XXXXXX") || exit 1
touch "$T/.olecharms-test"
mkdir -p "$T/logs"
cleanup() {
    if [ -z "$KEEP" ] && [ -f "$T/.olecharms-test" ]; then rm -rf "$T"; fi
}
trap cleanup EXIT

passed=0 failed=0 skipped=0 bad_suites=()
for f in "$TESTS_DIR"/[0-9][0-9]-*.sh; do
    name=$(basename "$f" .sh)
    if [ ${#ONLY[@]} -gt 0 ]; then
        want=""
        for o in "${ONLY[@]}"; do case "$name" in "$o"*) want=1 ;; esac; done
        [ -n "$want" ] || continue
    elif [ "$name" = 09-full-update ] && [ -z "$FULL" ]; then
        continue
    fi
    log=$T/logs/$name.log
    printf '%-32s ' "$name"
    # A suite that hangs (waiting for input it will never get) is stopped
    OLECHARMS_TEST_TMP=$T timeout "${OLECHARMS_TEST_TIMEOUT:-900}" bash "$f" > "$log" 2>&1
    rc=$?
    [ "$rc" -eq 124 ] && echo "TIMEOUT: stopped after ${OLECHARMS_TEST_TIMEOUT:-900}s" >> "$log"
    if [ "$rc" -eq 77 ]; then
        echo "skipped: $(grep -m1 '^SKIP' "$log" | sed 's/^SKIP: //')"
        skipped=$((skipped + 1))
        continue
    fi
    result=$(grep -E '^RESULT: [0-9]+ passed, [0-9]+ failed' "$log" | tail -n 1)
    p=$(sed -n 's/^RESULT: \([0-9]*\) passed.*/\1/p' <<< "$result")
    n=$(sed -n 's/.* \([0-9]*\) failed$/\1/p' <<< "$result")
    passed=$((passed + ${p:-0}))
    if [ -z "$result" ] || [ "$rc" -ne 0 ]; then
        echo "FAILED (${p:-0} passed, ${n:-?} failed)"
        grep -E '^ *FAIL |ABORT|^TIMEOUT' "$log" | sed 's/^ */    /'
        [ -n "$result" ] || tail -n 5 "$log" | sed 's/^/    | /'
        failed=$((failed + ${n:-1}))
        bad_suites+=("$name")
        KEEP=1
    else
        echo "ok ($p)"
    fi
done

echo ""
echo "$passed passed, $failed failed${skipped:+, $skipped skipped}" | sed 's/, 0 skipped//'
[ -z "$FULL" ] && [ ${#ONLY[@]} -eq 0 ] && echo "(09-full-update not run: add --full on WSL with Windows Vim and network)"
if [ ${#bad_suites[@]} -gt 0 ]; then
    echo "Logs: $T/logs"
    exit 1
fi
[ -n "$KEEP" ] && echo "Sandbox and logs kept in $T"
exit 0
