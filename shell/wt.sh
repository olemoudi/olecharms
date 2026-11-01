# wt — git worktrees, one per task or agent (wt help)
# Worktrees live next to the repository, in <repo>.worktrees/<task>, each on
# its own branch. Removing never forces: uncommitted work keeps the worktree,
# ignored files (.env...) go to the trash with it, and a branch that is not
# merged is kept.
wt() {
    local _wt_main _wt_base _wt_name _wt_dir _wt_br _wt_line _wt_pick
    _wt_main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    if [ -z "$_wt_main" ]; then
        echo "wt: not inside a git repository" >&2
        return 1
    fi
    _wt_base="$_wt_main.worktrees"
    case "${1:-list}" in
        -h|--help|help)
            echo "Usage: wt <task>     go to the worktree of <task>, creating it (branch <task>) if needed"
            echo "       wt rm <task>  remove it (refuses with uncommitted work; keeps an unmerged branch)"
            echo "       wt list       the worktrees of this repository (wt alone: pick one with fzf)"
            echo "       wt root       back to the main checkout"
            echo "       wt prune      forget worktrees whose folder was deleted"
            ;;
        list)
            if [ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ] && command -v fzf >/dev/null 2>&1; then
                _wt_pick=$(git worktree list | fzf --height=40% --reverse --prompt='worktree> ' | awk '{ print $1 }')
                [ -n "$_wt_pick" ] && cd "$_wt_pick"
            else
                git worktree list
            fi
            ;;
        root)
            cd "$_wt_main"
            ;;
        prune)
            git worktree prune -v
            ;;
        rm|remove)
            _wt_name="${2:-}"
            [ -n "$_wt_name" ] || { echo "Usage: wt rm <task>" >&2; return 2; }
            _wt_dir="$_wt_base/$(printf '%s' "$_wt_name" | tr '/' '-')"
            if ! git worktree list --porcelain | grep -qxF "worktree $_wt_dir"; then
                echo "wt: no worktree for '$_wt_name' (wt list)" >&2
                return 1
            fi
            case "$PWD/" in "$_wt_dir"/*) cd "$_wt_main" || return 1 ;; esac
            _wt_br=$(git -C "$_wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null)
            if [ -n "$(git -C "$_wt_dir" status --porcelain --ignored 2>/dev/null | grep '^!! ')" ]; then
                # git worktree remove deletes ignored files (.env, local
                # settings, builds) for good: the folder goes to the trash
                # instead, after the same check git makes for uncommitted work
                if [ -n "$(git -C "$_wt_dir" status --porcelain 2>/dev/null)" ]; then
                    git -C "$_wt_dir" status --short >&2
                    echo "wt: kept $_wt_dir (commit, stash or remove its changes first)" >&2
                    return 1
                fi
                if [ -n "${_olecharms_bin:-}" ] && [ -f "$_olecharms_bin" ]; then
                    bash "$_olecharms_bin" trash "$_wt_dir" >/dev/null
                elif command -v trash >/dev/null 2>&1; then
                    trash "$_wt_dir" >/dev/null
                else
                    false
                fi || {
                    echo "wt: kept $_wt_dir: its ignored files (such as .env) would be lost, and there is no trash to put them in" >&2
                    return 1
                }
                if [ -e "$_wt_dir" ]; then
                    echo "wt: kept $_wt_dir (the trash did not take it)" >&2
                    return 1
                fi
                git worktree prune
                echo "Moved worktree $_wt_dir to the trash, with its ignored files (trash --restore puts it back)"
            else
                # No --force: git refuses with modified or untracked files
                if ! git worktree remove "$_wt_dir"; then
                    echo "wt: kept $_wt_dir (commit, stash or remove its changes first)" >&2
                    return 1
                fi
                echo "Removed worktree $_wt_dir"
            fi
            rmdir "$_wt_base" 2>/dev/null
            if [ -n "$_wt_br" ]; then
                # -d, never -D: an unmerged branch stays
                if git branch -d "$_wt_br" >/dev/null 2>&1; then
                    echo "Deleted branch $_wt_br (it was merged)"
                else
                    echo "Kept branch $_wt_br (not merged; delete it with: git branch -D $_wt_br)"
                fi
            fi
            ;;
        *)
            _wt_name="$1"
            case "$_wt_name" in
                -*|*..*|*' '*) echo "wt: invalid task name: $_wt_name" >&2; return 2 ;;
            esac
            git check-ref-format --branch "$_wt_name" >/dev/null 2>&1 || { echo "wt: invalid branch name: $_wt_name" >&2; return 2; }
            _wt_dir="$_wt_base/$(printf '%s' "$_wt_name" | tr '/' '-')"
            if ! git worktree list --porcelain | grep -qxF "worktree $_wt_dir"; then
                mkdir -p "$_wt_base" || return 1
                if git show-ref --verify --quiet "refs/heads/$_wt_name"; then
                    git worktree add "$_wt_dir" "$_wt_name" || return 1
                elif git show-ref --verify --quiet "refs/remotes/origin/$_wt_name"; then
                    git worktree add --track -b "$_wt_name" "$_wt_dir" "origin/$_wt_name" || return 1
                else
                    git worktree add -b "$_wt_name" "$_wt_dir" HEAD || return 1
                fi
            fi
            cd "$_wt_dir"
            ;;
    esac
}
