# each — run a command for every line of stdin, replacing {} with the line
# Inspired by https://evanhahn.com/scripts-i-wrote-that-i-use-all-the-time/
# Usage: ls | each 'du -h {}'
each() {
    if [ $# -eq 0 ]; then
        echo "Usage: <command> | each '<command> {}'" >&2
        return 1
    fi
    local template="$1"
    local line escaped
    while IFS= read -r line; do
        escaped=$(printf '%q' "$line")
        eval "${template//\{\}/$escaped}"
    done
}
