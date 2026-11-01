# Shell history for bash (olecharms config → Shell history), sourced by the
# olecharms loader in interactive shells. Same rules as history.zsh: kept in
# a private file, without lines that look like they hold a secret and without
# lines starting with a space.
# This is all bash's own HISTIGNORE: a line matching one of its patterns is
# never put in the history list, so bash never writes it to HISTFILE either.
# bash keeps and trims the file itself, as it does by default — nothing here
# unsets HISTFILE, shortens it, or removes an entry; the patterns only decide
# what is not taken down in the first place.
# Where zsh can be asked line by line (history.zsh uses a regexp in its
# zshaddhistory hook), HISTIGNORE takes shell globs that must match the whole
# line, so these are wider: a `?` per character pins the length of a token
# shape, and KEY/TOKEN/… match anywhere before the `=` rather than only as a
# `_`-separated part of the name. Erring wide costs an ordinary history line
# now and then, which is the safe direction.

_olecharms_hd="${_olecharms_history_dir:-${XDG_STATE_HOME:-$HOME/.local/state}/olecharms/history}"
[ -d "$_olecharms_hd" ] || (umask 077; mkdir -p "$_olecharms_hd")
HISTFILE="$_olecharms_hd/bash_history"
[ -f "$HISTFILE" ] || (umask 077; : > "$HISTFILE")
[ "${HISTSIZE:-0}" -ge 50000 ] 2>/dev/null || HISTSIZE=50000
[ "${HISTFILESIZE:-0}" -ge 50000 ] 2>/dev/null || HISTFILESIZE=50000
HISTCONTROL=ignoreboth
shopt -s histappend     # sessions add to the file, none overwrites another
unset _olecharms_hd

# A name like …KEY/TOKEN/SECRET/PASS(WD|WORD)/PAT/CREDENTIAL(S) before an `=`
# (PATH= is not one: the `=` has to follow the word itself), headers and
# sshpass, private key blocks, token shapes pinned by length (ghp_… +20,
# AKIA +16, AIza +30, sk-… +20), user:password@ in a URL. `[ ]*` and `&` are
# HISTCONTROL's ignorespace and ignoredups, which HISTIGNORE subsumes.
# Plain globs only, no extglob `*(…)`/`@(…)`: HISTIGNORE passes those to the
# matcher only while `shopt extglob` is on, so one `shopt -u extglob` would
# quietly stop a pattern needing one from ever matching again. The letters
# are spelled in [Kk] pairs for the same reason: the match is case-sensitive
# and nothing here should depend on a shell option staying as it is.
_olecharms_hist_pats='[ ]*:&'
for _olecharms_w in '[Kk][Ee][Yy]' '[Tt][Oo][Kk][Ee][Nn]' '[Ss][Ee][Cc][Rr][Ee][Tt]' \
                    '[Pp][Aa][Ss][Ss]' '[Pp][Aa][Ss][Ss][Ww][Dd]' \
                    '[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]' '[Pp][Aa][Tt]'; do
    # the word, then `=` with or without a space before it
    _olecharms_hist_pats=$_olecharms_hist_pats":*$_olecharms_w=*:*$_olecharms_w =*"
done
unset _olecharms_w
_olecharms_hist_pats=$_olecharms_hist_pats':*[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]*=*'
_olecharms_hist_pats=$_olecharms_hist_pats':*[Bb][Ee][Aa][Rr][Ee][Rr] *'
_olecharms_hist_pats=$_olecharms_hist_pats':*[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]\:*'
_olecharms_hist_pats=$_olecharms_hist_pats':*[Xx]-[Aa][Pp][Ii]-[Kk][Ee][Yy]*'
_olecharms_hist_pats=$_olecharms_hist_pats':*[Ss][Ss][Hh][Pp][Aa][Ss][Ss]*'
_olecharms_hist_pats=$_olecharms_hist_pats':*-----[Bb][Ee][Gg][Ii][Nn]*'
_olecharms_hist_pats=$_olecharms_hist_pats':*gh[pousr]_????????????????????*'
_olecharms_hist_pats=$_olecharms_hist_pats':*github_pat_*:*glpat-*:*xox[abprs]-*'
_olecharms_hist_pats=$_olecharms_hist_pats':*AKIA????????????????*'
_olecharms_hist_pats=$_olecharms_hist_pats':*AIza??????????????????????????????*'
_olecharms_hist_pats=$_olecharms_hist_pats':*sk-????????????????????*'
_olecharms_hist_pats=$_olecharms_hist_pats':*\://*\:*@*'

# The value of any of your olecharms secrets, kept out whatever the line is
# (the `olecharms secret` wrapper calls this again after a change). The value
# goes into HISTIGNORE, a plain shell variable, as a glob, so a character
# with a meaning there is escaped: `*?[\` for the match, and `:`, which
# HISTIGNORE splits the list on. A value under 8 characters is left to the
# patterns above, being too short to pin a line down.
_olecharms_hist_names() {
    local n v
    HISTIGNORE=$_olecharms_hist_pats
    [ -r "${_olecharms_secrets:-}" ] || return 0
    for n in $(sed -n 's/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$_olecharms_secrets" 2>/dev/null); do
        v=${!n}
        [ ${#v} -ge 8 ] || continue
        v=${v//\\/\\\\}; v=${v//\*/\\*}; v=${v//\?/\\?}
        v=${v//\[/\\[}; v=${v//:/\\:}
        HISTIGNORE=$HISTIGNORE:"*$v*"
    done
}
_olecharms_hist_names
