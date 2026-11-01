# tempe — go to a new empty folder in the temp dir
tempe() {
    local _olecharms_d _olecharms_p="${1:-tempe}"
    case "$_olecharms_p" in
        */*|.*|*[!A-Za-z0-9._-]*) echo "tempe: the name must be letters, digits, . _ -" >&2; return 2 ;;
    esac
    _olecharms_d=$(mktemp -d "${TMPDIR:-/tmp}/$_olecharms_p.XXXXXX") || return 1
    cd "$_olecharms_d" && pwd
}
