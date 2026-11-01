# copy — put text on the system clipboard; `paste` prints it back
# The same on Linux, macOS and WSL (over SSH, copies reach the clipboard of
# the machine you sit at).
#   pwd | copy          copy a command's output
#   copy notes.txt      copy a file's contents
#   paste               print the clipboard (paste > file, paste | grep x)
# `paste` with arguments or with piped input is still the classic paste(1)
# that merges lines of files.

_olecharms_clip() {
    local _olecharms_t=""
    [ -n "${_olecharms_bin:-}" ] && _olecharms_t="${_olecharms_bin%/*}/bin/olecharms-clip"
    if [ -z "$_olecharms_t" ] || [ ! -f "$_olecharms_t" ]; then
        _olecharms_t=$(command -v olecharms-clip 2>/dev/null) || {
            echo "olecharms: clipboard helper not found (run: olecharms doctor --fix)" >&2
            return 1
        }
    fi
    sh "$_olecharms_t" "$@"
}

copy() {
    local _olecharms_f
    if [ "$#" -gt 0 ]; then
        for _olecharms_f in "$@"; do
            [ -f "$_olecharms_f" ] && [ -r "$_olecharms_f" ] || {
                echo "copy: cannot read $_olecharms_f" >&2
                return 1
            }
        done
        cat -- "$@" | _olecharms_clip copy
    elif [ -t 0 ]; then
        echo "usage: <command> | copy    or    copy FILE..." >&2
        return 2
    else
        _olecharms_clip copy
    fi
}

paste() {
    if [ "$#" -gt 0 ] || [ ! -t 0 ]; then
        command paste "$@"
    else
        _olecharms_clip paste
    fi
}
