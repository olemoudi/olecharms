# mkcd — create directory and cd into it
mkcd() {
    if [ $# -eq 0 ]; then
        echo "Usage: mkcd <dirname>" >&2
        return 1
    fi
    mkdir -p "$@" || return
    cd "${@: -1}" || return
}
