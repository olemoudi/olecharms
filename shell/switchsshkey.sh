# switchsshkey — manage and switch between named SSH key pairs (alias: ssk)
switchsshkey() {
    # zsh aborts on a glob with no matches (~/.ssh/*.pubkey before any key has
    # been added); make it expand to nothing, like the [ -f ] checks expect.
    [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob

    local cmd="${1:-current}"

    case "$cmd" in
        help)
            echo "Usage:" >&2
            echo "  switchsshkey              — show which named key is currently active" >&2
            echo "  switchsshkey add <name> <private_key_file> <public_key_file>" >&2
            echo "  switchsshkey <name>       — switch to named key pair" >&2
            echo "  switchsshkey list         — list available key pairs" >&2
            echo "  switchsshkey help         — show this help" >&2
            echo "  (alias: ssk)" >&2
            ;;
        current)
            if [ ! -f ~/.ssh/id_ed25519.pub ]; then
                echo "switchsshkey: no active key (id_ed25519.pub not found)" >&2
                return 1
            fi
            local f name
            for f in ~/.ssh/*.pubkey; do
                [ -f "$f" ] || continue
                if cmp -s ~/.ssh/id_ed25519.pub "$f"; then
                    name=$(basename "$f" .pubkey)
                    echo "$name"
                    return 0
                fi
            done
            echo "unknown (no matching named key)" >&2
            return 1
            ;;
        list)
            local f
            for f in ~/.ssh/*.pubkey; do
                [ -f "$f" ] || continue
                basename "$f" .pubkey
            done
            ;;
        add)
            if [ $# -ne 4 ]; then
                echo "switchsshkey: add requires exactly 3 arguments" >&2
                echo "Usage: switchsshkey add <name> <private_key_file> <public_key_file>" >&2
                return 1
            fi
            local name="$2" private_key_file="$3" public_key_file="$4"

            # The name becomes a file name in ~/.ssh and must not shadow a subcommand
            case "$name" in
                ""|*/*|.*|-*|help|list|add|current)
                    echo "switchsshkey: invalid key name: '$name'" >&2
                    return 1
                    ;;
            esac

            if [ ! -r "$private_key_file" ]; then
                echo "switchsshkey: cannot read private key file: $private_key_file" >&2
                return 1
            fi
            if [ ! -r "$public_key_file" ]; then
                echo "switchsshkey: cannot read public key file: $public_key_file" >&2
                return 1
            fi

            local priv_first_line pub_first_line
            priv_first_line=$(head -1 "$private_key_file")
            pub_first_line=$(head -1 "$public_key_file")

            if [[ "$priv_first_line" == ssh-* ]] || [[ "$pub_first_line" == -----BEGIN* ]]; then
                echo "switchsshkey: it looks like the private and public key arguments may be swapped" >&2
                echo "Usage: switchsshkey add <name> <private_key_file> <public_key_file>" >&2
                return 1
            fi

            local priv_target="$HOME/.ssh/${name}.privatekey"
            local pub_target="$HOME/.ssh/${name}.pubkey"

            if [ -e "$priv_target" ] || [ -e "$pub_target" ]; then
                echo "switchsshkey: key pair '$name' already exists" >&2
                return 1
            fi

            cp "$private_key_file" "$priv_target" || return
            cp "$public_key_file" "$pub_target" || return
            chmod 600 "$priv_target" || return
            chmod 644 "$pub_target" || return
            echo "switchsshkey: added key pair '$name'"
            ;;
        *)
            local name="$1"
            local priv_source="$HOME/.ssh/${name}.privatekey"
            local pub_source="$HOME/.ssh/${name}.pubkey"

            if [ ! -f "$priv_source" ] || [ ! -f "$pub_source" ]; then
                echo "switchsshkey: key pair '$name' not found" >&2
                echo "Run 'switchsshkey list' to see available keys" >&2
                return 1
            fi

            # Never overwrite a private key that exists nowhere else: if the
            # active pair is not one of the named ones, keep it under a backup
            # name first.
            if [ -f ~/.ssh/id_ed25519 ]; then
                local f saved=""
                for f in ~/.ssh/*.pubkey; do
                    [ -f "$f" ] || continue
                    if cmp -s ~/.ssh/id_ed25519 "${f%.pubkey}.privatekey"; then
                        saved=1
                        break
                    fi
                done
                if [ -z "$saved" ]; then
                    local backup
                    backup="backup-$(date +%Y%m%d-%H%M%S)"
                    cp -p ~/.ssh/id_ed25519 "$HOME/.ssh/$backup.privatekey" || return
                    chmod 600 "$HOME/.ssh/$backup.privatekey" || return
                    if [ -f ~/.ssh/id_ed25519.pub ]; then
                        cp -p ~/.ssh/id_ed25519.pub "$HOME/.ssh/$backup.pubkey" || return
                    fi
                    echo "switchsshkey: the active key was not saved under a name; kept it as '$backup'" >&2
                fi
            fi

            cp "$priv_source" ~/.ssh/id_ed25519 || return
            cp "$pub_source" ~/.ssh/id_ed25519.pub || return
            chmod 600 ~/.ssh/id_ed25519 || return
            chmod 644 ~/.ssh/id_ed25519.pub || return
            echo "switchsshkey: switched to '$name'"
            ;;
    esac
}
ssk() { switchsshkey "$@"; }
