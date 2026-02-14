# switchsshkey — manage and switch between named SSH key pairs
switchsshkey() {
    local cmd="${1:-help}"

    case "$cmd" in
        help)
            echo "Usage:" >&2
            echo "  switchsshkey add <name> <private_key_file> <public_key_file>" >&2
            echo "  switchsshkey <name>" >&2
            echo "  switchsshkey list" >&2
            echo "  switchsshkey help" >&2
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

            cp "$priv_source" ~/.ssh/id_ed25519 || return
            cp "$pub_source" ~/.ssh/id_ed25519.pub || return
            chmod 600 ~/.ssh/id_ed25519 || return
            chmod 644 ~/.ssh/id_ed25519.pub || return
            echo "switchsshkey: switched to '$name'"
            ;;
    esac
}
