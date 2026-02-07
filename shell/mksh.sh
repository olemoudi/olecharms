# mksh — create a new shell script with boilerplate
mksh() {
    if [ $# -eq 0 ]; then
        echo "Usage: mksh <filename>" >&2
        return 1
    fi
    local file="$1"
    if [ -e "$file" ]; then
        echo "mksh: file already exists: $file" >&2
        return 1
    fi
    local dir; dir="$(dirname "$file")"
    [ "$dir" != "." ] && [ ! -d "$dir" ] && { mkdir -p "$dir" || return; }
    cat > "$file" <<'BOILERPLATE' || return
#!/usr/bin/env bash
set -e   # Exit immediately if a command fails
set -u   # Treat unset variables as an error
set -o pipefail  # Fail pipeline if any command in the pipe fails

BOILERPLATE
    chmod u+x "$file" || return
    "${EDITOR:-vim}" "$file"
}
