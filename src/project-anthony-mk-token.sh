#!/bin/bash
# =========================================================================
#  Project Anthony: rescue-token tool (not part of the TUI menu)
# =========================================================================
# USB file token (fifth failed password → lock until this stick is inserted):
#   sudo project-anthony-mk-token /media/you/USBSTICK
#   sudo project-anthony-mk-token --revoke
#
# Optional FIDO2/U2F (password then touch; requires libpam-u2f).
# Repeat per person for a shared workstation; repeat per spare key:
#   sudo project-anthony-mk-token --u2f [user]
#   sudo project-anthony-mk-token --u2f-import [user]
#   sudo project-anthony-mk-token --u2f-disable
#
#   sudo project-anthony-mk-token --status
# =========================================================================

TOKEN_NAME="project-anthony.rescue"
HASH_DIR="/etc/project-anthony"
HASH_FILE="$HASH_DIR/rescue-token.sha256"
U2F_FILE="$HASH_DIR/u2f_mappings"

usage() {
    echo "Create or revoke TTY3 rescue tokens."
    echo "Not available from the rescue menu — run this from a normal root shell."
    echo ""
    echo "USB file token (fifth failed unlock waits for this stick):"
    echo "  sudo project-anthony-mk-token <usb-mount-or-directory>"
    echo "  sudo project-anthony-mk-token --revoke"
    echo ""
    echo "FIDO2/U2F security key (optional; password then touch):"
    echo "  sudo apt install libpam-u2f     # once, if you use a key"
    echo "  sudo project-anthony-mk-token --u2f [user]"
    echo "  sudo project-anthony-mk-token --u2f-import [user]   # that username only"
    echo "  sudo project-anthony-mk-token --u2f-disable"
    echo "  Repeat --u2f for each person on a shared machine, or a spare key."
    echo ""
    echo "  sudo project-anthony-mk-token --status"
}

token_hash_of() {
    tr -d ' \t\r\n' < "$1" 2>/dev/null | sha256sum | awk '{print $1}'
}

pick_user() {
    local u="${1:-}"
    if [ -n "$u" ] && [ "$u" != "root" ] && getent passwd "$u" >/dev/null; then
        echo "$u"
        return 0
    fi
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
        return 0
    fi
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1; exit}'
}

pam_u2f_so() {
    ls /lib/*/security/pam_u2f.so /usr/lib/*/security/pam_u2f.so 2>/dev/null | head -n1
}

require_pam_u2f() {
    if [ -z "$(pam_u2f_so)" ]; then
        echo "libpam-u2f is not installed. This is optional."
        echo "  sudo apt install libpam-u2f"
        echo "Then plug the key in and run this command again."
        exit 1
    fi
}

ensure_hash_dir() {
    mkdir -p "$HASH_DIR"
    chmod 700 "$HASH_DIR"
}

append_u2f_line() {
    local line="$1"
    [ -n "$line" ] || return 1
    [[ "$line" == *:* ]] || return 1
    ensure_hash_dir
    touch "$U2F_FILE"
    chmod 600 "$U2F_FILE"
    grep -Fxq -- "$line" "$U2F_FILE" 2>/dev/null && return 0
    printf '%s\n' "$line" >> "$U2F_FILE"
}

# pam_u2f: extra keys for the same user go on the same line after another colon.
# A new username gets its own line, so a shared machine can hold alice + bob.
user_has_u2f_line() {
    local u="$1"
    [ -s "$U2F_FILE" ] || return 1
    awk -F: -v u="$u" 'NF && $1==u {found=1} END{exit !found}' "$U2F_FILE"
}

append_u2f_cred() {
    local user="$1" cred="$2" tmp
    [ -n "$user" ] && [ -n "$cred" ] || return 1
    ensure_hash_dir
    touch "$U2F_FILE"
    chmod 600 "$U2F_FILE"
    if grep -Fq -- ":$cred" "$U2F_FILE" 2>/dev/null; then
        return 0
    fi
    if ! user_has_u2f_line "$user"; then
        printf '%s:%s\n' "$user" "$cred" >> "$U2F_FILE"
        return 0
    fi
    tmp=$(mktemp) || return 1
    awk -F: -v u="$user" -v extra="$cred" '
        $1==u && !done { print $0 ":" extra; done=1; next }
        { print }
    ' "$U2F_FILE" > "$tmp" && mv "$tmp" "$U2F_FILE"
    chmod 600 "$U2F_FILE"
}

u2f_enroll() {
    local user line cred
    require_pam_u2f
    if ! command -v pamu2fcfg >/dev/null; then
        echo "pamu2fcfg is missing. Reinstall libpam-u2f."
        exit 1
    fi
    user=$(pick_user "${1:-}")
    if [ -z "$user" ]; then
        echo "No desktop user to enroll. Pass a username: --u2f alice"
        exit 1
    fi
    echo "Enrolling a FIDO2/U2F key for '$user'."
    echo "Plug that person's key in, then touch it when it blinks."
    echo "Run this again with another username for a shared workstation."
    echo "Run this again with the same username to add a spare key."
    line=$(pamu2fcfg -u "$user") || {
        echo "Enrollment failed. Is the key plugged in?"
        exit 1
    }
    line=$(printf '%s\n' "$line" | tr -d '\r' | grep -v '^$' | head -n1)
    [[ "$line" == *:* ]] || { echo "pamu2fcfg did not return a usable mapping line."; exit 1; }
    cred="${line#*:}"
    if ! append_u2f_cred "$user" "$cred"; then
        echo "Failed to write $U2F_FILE"
        exit 1
    fi
    echo "Registered in $U2F_FILE"
    echo "TTY3 will ask this account to touch a registered key after the password."
    echo "A rescue USB (if you made one) still unlocks after five failures."
}

u2f_import() {
    local user home src line line_user imported=0 skipped=0
    require_pam_u2f
    user=$(pick_user "${1:-}")
    if [ -z "$user" ]; then
        echo "No desktop user to import for. Pass a username: --u2f-import alice"
        exit 1
    fi
    home=$(getent passwd "$user" | cut -d: -f6)
    for src in "${home}/.config/Yubico/u2f_keys" /etc/u2f_mappings; do
        [ -s "$src" ] || continue
        echo "Importing from $src (account '$user' only)"
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(printf '%s' "$line" | tr -d '\r')
            [ -n "$line" ] || continue
            case "$line" in
                \#*) continue ;;
            esac
            if [[ "$line" != *:* ]]; then
                line="${user}:${line}"
            else
                line_user="${line%%:*}"
                if [ "$line_user" != "$user" ]; then
                    skipped=$((skipped + 1))
                    continue
                fi
            fi
            if append_u2f_line "$line"; then
                imported=$((imported + 1))
            fi
        done < "$src"
    done
    if [ "$skipped" -gt 0 ]; then
        echo "Skipped $skipped mapping line(s) that named a different account."
    fi
    if [ "$imported" -eq 0 ]; then
        echo "No existing U2F mappings found for '$user'."
        echo "Enroll a key with: sudo project-anthony-mk-token --u2f $user"
        exit 1
    fi
    echo "Imported $imported mapping line(s) into $U2F_FILE"
    echo "TTY3 will ask this account to touch the key after the password."
}

u2f_disable() {
    rm -f "$U2F_FILE"
    rmdir "$HASH_DIR" 2>/dev/null || true
    echo "FIDO2/U2F requirement removed from TTY3. Passwords work as before."
}

print_status() {
    if [ -s "$HASH_FILE" ]; then
        echo "USB rescue token: registered (fifth failed TTY3 unlock waits for the stick)."
    else
        echo "USB rescue token: none (fifth failed TTY3 unlock stays locked until reboot)."
    fi
    if [ -s "$U2F_FILE" ]; then
        echo "FIDO2/U2F: enabled for $(awk -F: 'NF && $1 !~ /^#/ {print $1}' "$U2F_FILE" | sort -u | tr '\n' ' ')"
        if [ -z "$(pam_u2f_so)" ]; then
            echo "  Warning: libpam-u2f is not installed; TTY3 cannot prompt the key."
        fi
    else
        echo "FIDO2/U2F: off. Optional: sudo apt install libpam-u2f && sudo project-anthony-mk-token --u2f"
    fi
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Must be root. Use: sudo project-anthony-mk-token ..."
    exit 1
fi

case "${1:-}" in
    ""|-h|--help)
        usage
        exit 0
        ;;
    --status)
        print_status
        exit 0
        ;;
    --revoke)
        rm -f "$HASH_FILE"
        rmdir "$HASH_DIR" 2>/dev/null || true
        echo "USB rescue token revoked. Existing USB copies no longer unlock TTY3."
        echo "FIDO2/U2F mappings (if any) were left in place. --u2f-disable drops those."
        exit 0
        ;;
    --u2f)
        u2f_enroll "${2:-}"
        exit 0
        ;;
    --u2f-import)
        u2f_import "${2:-}"
        exit 0
        ;;
    --u2f-disable)
        u2f_disable
        exit 0
        ;;
    -*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
esac

dest="$1"
if [ ! -d "$dest" ]; then
    echo "Not a directory: $dest"
    echo "Mount the USB first, then pass the mount point (e.g. /media/$SUDO_USER/LABEL)."
    exit 1
fi
if [ ! -w "$dest" ]; then
    echo "Directory is not writable: $dest"
    exit 1
fi

umask 077
token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
if [ "${#token}" -ne 64 ]; then
    echo "Failed to read 32 random bytes from /dev/urandom."
    exit 1
fi

out="${dest%/}/$TOKEN_NAME"
printf '%s\n' "$token" > "$out" || exit 1
chmod 400 "$out" 2>/dev/null || true

digest=$(token_hash_of "$out")
if [ "${#digest}" -ne 64 ]; then
    echo "Failed to hash the token file."
    rm -f "$out"
    exit 1
fi

ensure_hash_dir
printf '%s\n' "$digest" > "$HASH_FILE"
chmod 600 "$HASH_FILE"

echo "Wrote $out"
echo "Registered hash at $HASH_FILE"
echo "Copy that file to extra sticks if you want backups. --revoke invalidates all of them."
exit 0
