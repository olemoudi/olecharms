# switchsshkey — same as ssk: SSH keys and git identities (ssk help)
# The work is done by bin/ssk (also on PATH for scripts and agents); these
# functions find it even where ~/.local/bin is not on PATH.
ssk() {
    if [ -n "${_olecharms_bin:-}" ] && [ -x "${_olecharms_bin%/*}/bin/ssk" ]; then
        "${_olecharms_bin%/*}/bin/ssk" "$@"
    else
        command ssk "$@"
    fi
}
switchsshkey() { ssk "$@"; }
