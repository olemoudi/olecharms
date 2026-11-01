# Shell history for zsh (olecharms config → Shell history), sourced by the
# olecharms loader in interactive shells. History is kept across sessions in
# a private file, but a line that looks like it holds a secret never reaches
# it (it stays in this session's memory only):
#   - setting a variable or option named like a secret: GITHUB_TOKEN=…,
#     API_KEY=…, --password=…, DB_PASS=… (KEY, TOKEN, SECRET, PASS, PASSWORD,
#     PASSWD, PAT, CREDENTIAL(S), APIKEY as a _-separated part of the name)
#   - known token shapes (ghp_…, github_pat_…, glpat-…, xoxb-…, AKIA…, AIza…,
#     sk-…), Bearer / Authorization headers, user:password@ in a URL, sshpass,
#     private key blocks
#   - the value of any of your olecharms secrets
# A line starting with a space is not kept either. Paranoid mode wipes the file.

_olecharms_hd="${_olecharms_history_dir:-${XDG_STATE_HOME:-$HOME/.local/state}/olecharms/history}"
[ -d "$_olecharms_hd" ] || (umask 077; mkdir -p "$_olecharms_hd")
HISTFILE="$_olecharms_hd/zsh_history"
[ -f "$HISTFILE" ] || (umask 077; : > "$HISTFILE")
(( ${HISTSIZE:-0} >= 50000 )) || HISTSIZE=50000
(( ${SAVEHIST:-0} >= 50000 )) || SAVEHIST=50000
setopt hist_ignore_space hist_ignore_dups extended_history inc_append_history
unset _olecharms_hd

_olecharms_hist_re='(^|[^a-z0-9_])([a-z0-9]+_)*(key|token|secret|pass|password|passwd|pat|credential|credentials|apikey)(_[a-z0-9]+)*[[:space:]]*='
_olecharms_hist_re2='(bearer[[:space:]]|authorization:|x-api-key|sshpass|-----begin|gh[pousr]_[a-z0-9]{20}|github_pat_|glpat-|xox[abprs]-|akia[a-z0-9]{16}|aiza[a-z0-9_-]{30}|sk-[a-z0-9_-]{20}|://[^/@[:space:]]+:[^/@[:space:]]+@)'

# Names of your olecharms secrets, read once (the `olecharms secret` wrapper
# calls this again after a change)
_olecharms_hist_names() {
    _olecharms_secret_names=()
    [ -r "${_olecharms_secrets:-}" ] || return 0
    _olecharms_secret_names=( ${(f)"$(sed -n 's/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$_olecharms_secrets" 2>/dev/null)"} )
}
_olecharms_hist_names

# True when command line $1 looks like it holds a secret
_olecharms_hist_secret() {
    emulate -L zsh
    local l="${(L)1}" n v
    [[ $l =~ $_olecharms_hist_re ]] && return 0
    [[ $l =~ $_olecharms_hist_re2 ]] && return 0
    for n in $_olecharms_secret_names; do
        v=${(P)n}
        (( ${#v} >= 6 )) && [[ $1 == *${v}* ]] && return 0
    done
    return 1
}

# zsh asks before saving each line: 2 = keep it in memory, not in the file
_olecharms_hist_filter() {
    _olecharms_hist_secret "${1%%$'\n'}" && return 2
    return 0
}
(( ${zshaddhistory_functions[(I)_olecharms_hist_filter]} )) || zshaddhistory_functions+=(_olecharms_hist_filter)
