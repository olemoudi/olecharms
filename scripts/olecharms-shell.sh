#!/bin/bash
# olecharms-shell.sh — sources shell command files from /mnt/c/Users/olemo/Dropbox/vibedev/olecharms/shell
for _olecharms_f in "/mnt/c/Users/olemo/Dropbox/vibedev/olecharms/shell"/*.sh; do
    [ -f "$_olecharms_f" ] && source "$_olecharms_f"
done
unset _olecharms_f
