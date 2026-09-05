# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# TTY3 console unlock: PAM password, optional U2F, idle relock, fail
# backoff, and USB rescue-token lockout. Keep this file together.

# Unlock TTY3 / crash-console once per process. Physical console is already
# root; this checks a local account password via PAM before any menu action.
unlock_account_ok() {
    local user="$1" uid
    [[ "$user" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]] || return 1
    uid=$(id -u "$user" 2>/dev/null) || return 1
    [ "$uid" -eq 0 ] || { [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; }
}

verify_local_password() {
    local user="$1" pass="$2" helper
    helper="/usr/local/bin/project-anthony-auth"
    [ -x "$helper" ] || helper="$(command -v project-anthony-auth 2>/dev/null || true)"
    [ -n "$helper" ] && [ -x "$helper" ] || return 1
    printf '%s\n' "$pass" | "$helper" "$user" >/dev/null 2>&1
}

U2F_MAP_FILE="/etc/project-anthony/u2f_mappings"

pam_u2f_available() {
    ls /lib/*/security/pam_u2f.so /usr/lib/*/security/pam_u2f.so >/dev/null 2>&1
}

user_has_u2f() {
    local u="$1"
    [ -s "$U2F_MAP_FILE" ] || return 1
    awk -F: -v u="$u" 'NF && $1==u {found=1} END{exit !found}' "$U2F_MAP_FILE"
}

# Optional second factor. No-op unless this account was enrolled independently.
verify_security_key() {
    local user="$1" helper rc
    user_has_u2f "$user" || return 0
    if ! pam_u2f_available; then
        echo ""
        echo " This account requires a security key, but libpam-u2f is not installed."
        return 1
    fi
    helper="/usr/local/bin/project-anthony-auth"
    [ -x "$helper" ] || helper="$(command -v project-anthony-auth 2>/dev/null || true)"
    [ -n "$helper" ] && [ -x "$helper" ] || return 1
    echo ""
    echo " Touch your security key..."
    if command -v timeout >/dev/null; then
        timeout 45 "$helper" --u2f "$user"
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        [ "$rc" -eq 124 ] && echo " Security key timed out."
        return 1
    fi
    "$helper" --u2f "$user"
}

IDLE_SECS=60
FAIL_FILE="/run/project-anthony-auth-fails"

session_idle_lock() {
    echo ""
    echo " Session timed out after ${IDLE_SECS}s idle. Unlock again."
    sleep 2
    exit 0
}

# TTY3 menu/crash prompts. Idle timeout relocks (systemd restarts a locked TUI).
# Long jobs (ddrescue, timeshift, less) are not wrapped.
tui_read() {
    local silent=0 dest prompt
    [ "${1:-}" = "-s" ] && { silent=1; shift; }
    dest="$1"
    prompt="${2-}"
    if [ "${ON_KERNEL_VT:-0}" -ne 1 ]; then
        if [ "$silent" -eq 1 ]; then
            IFS= read -r -s -p "$prompt" "$dest" </dev/tty || true
        else
            IFS= read -r -p "$prompt" "$dest" </dev/tty || true
        fi
        return 0
    fi
    if [ "$silent" -eq 1 ]; then
        IFS= read -r -s -t "$IDLE_SECS" -p "$prompt" "$dest" </dev/tty || session_idle_lock
    else
        IFS= read -r -t "$IDLE_SECS" -p "$prompt" "$dest" </dev/tty || session_idle_lock
    fi
}

load_auth_fails() {
    local n=""
    [ -f "$FAIL_FILE" ] && n=$(tr -cd '0-9' < "$FAIL_FILE" | head -c 8)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    [ "$n" -gt 15 ] && n=15
    printf '%s\n' "$n"
}

save_auth_fails() {
    umask 077
    printf '%s\n' "$1" > "$FAIL_FILE"
    chmod 600 "$FAIL_FILE" 2>/dev/null || true
}

clear_auth_fails() {
    rm -f "$FAIL_FILE"
}

AUTH_LOCKOUT=5
AUTH_TOKEN_BYPASS=0
TOKEN_NAME="project-anthony.rescue"
TOKEN_HASH_FILE="/etc/project-anthony/rescue-token.sha256"
USB_CHECK_MNT="/run/project-anthony-usbcheck"

rescue_token_registered() {
    [ -s "$TOKEN_HASH_FILE" ]
}

expected_token_hash() {
    tr -d ' \t\r\n' < "$TOKEN_HASH_FILE" 2>/dev/null | tr 'A-F' 'a-f'
}

# mk-token writes 64 hex chars plus a newline (~65 bytes). Bound the read so a
# huge or non-regular file on a stick cannot OOM the root TUI.
TOKEN_FILE_MAX_BYTES=256

token_file_matches() {
    local got want raw sz
    [ -e "$1" ] || return 1
    [ -L "$1" ] && return 1
    [ -f "$1" ] && [ -r "$1" ] || return 1
    sz=$(stat -c '%s' "$1" 2>/dev/null) || return 1
    [[ "$sz" =~ ^[0-9]+$ ]] || return 1
    [ "$sz" -ge 32 ] && [ "$sz" -le "$TOKEN_FILE_MAX_BYTES" ] || return 1
    raw=$(head -c "$TOKEN_FILE_MAX_BYTES" "$1" 2>/dev/null | tr -d ' \t\r\n')
    [ "${#raw}" -ge 32 ] && [ "${#raw}" -le "$TOKEN_FILE_MAX_BYTES" ] || return 1
    got=$(printf '%s' "$raw" | sha256sum | awk '{print $1}')
    want=$(expected_token_hash)
    [ -n "$got" ] && [ -n "$want" ] && [ "$got" = "$want" ]
}

block_usb_or_removable() {
    local dev="$1" rm="" tran="" pk=""
    [ -b "$dev" ] || return 1
    rm=$(lsblk -dn -o RM "$dev" 2>/dev/null | head -n1 | tr -d ' ')
    tran=$(lsblk -dn -o TRAN "$dev" 2>/dev/null | head -n1 | tr -d ' ')
    if [ -z "$tran" ]; then
        pk=$(lsblk -dn -o PKNAME "$dev" 2>/dev/null | head -n1 | tr -d ' ')
        if [ -n "$pk" ]; then
            tran=$(lsblk -dn -o TRAN "/dev/$pk" 2>/dev/null | head -n1 | tr -d ' ')
            [ -n "$rm" ] || rm=$(lsblk -dn -o RM "/dev/$pk" 2>/dev/null | head -n1 | tr -d ' ')
        fi
    fi
    [ "$rm" = "1" ] || [ "$tran" = "usb" ]
}

# USB sticks people actually pass to mk-token. Skip iso9660/udf/btrfs/xfs so
# the lockout scanner does not mount CD/UDF/btrfs gadgets as root.
fstype_token_ok() {
    case "$1" in
        vfat|fat|fat32|msdos|exfat|ntfs|ntfs3|ext2|ext3|ext4|f2fs) return 0 ;;
        *) return 1 ;;
    esac
}

mountpoint_is_removable() {
    local mp="$1" src=""
    src=$(findmnt -nro SOURCE "$mp" 2>/dev/null)
    [ -n "$src" ] || return 1
    block_usb_or_removable "$src"
}

scan_mounted_for_token() {
    local mp
    while IFS= read -r mp; do
        case "$mp" in
            /media/*|/mnt/*|/run/media/*)
                if mountpoint_is_removable "$mp" && token_file_matches "${mp%/}/$TOKEN_NAME"; then
                    return 0
                fi
                ;;
        esac
    done < <(findmnt -rn -o TARGET 2>/dev/null)
    return 1
}

unmount_token_check() {
    findmnt -n "$USB_CHECK_MNT" >/dev/null 2>&1 && umount -l "$USB_CHECK_MNT" 2>/dev/null || true
}

# Short timeout so a wedged USB cannot hang the lockout loop forever.
mount_token_check() {
    local dev="$1" opts
    mkdir -p "$USB_CHECK_MNT"
    for opts in "ro,nosuid,nodev,noexec,nosymfollow" "ro,nosuid,nodev,noexec"; do
        if command -v timeout >/dev/null; then
            timeout 5 mount -o "$opts" "$dev" "$USB_CHECK_MNT" 2>/dev/null && return 0
        else
            mount -o "$opts" "$dev" "$USB_CHECK_MNT" 2>/dev/null && return 0
        fi
    done
    return 1
}

scan_unmounted_usb_for_token() {
    local name typ fs src_root
    src_root=$(findmnt -nro SOURCE / 2>/dev/null)
    unmount_token_check
    mkdir -p "$USB_CHECK_MNT"
    while IFS= read -r name; do
        [ -b "$name" ] || continue
        [ "$name" = "$src_root" ] && continue
        typ=$(lsblk -dn -o TYPE "$name" 2>/dev/null | head -n1 | tr -d ' ')
        fs=$(lsblk -dn -o FSTYPE "$name" 2>/dev/null | head -n1 | tr -d ' ')
        [ "$typ" = "part" ] || { [ "$typ" = "disk" ] && [ -n "$fs" ]; } || continue
        fstype_token_ok "$fs" || continue
        block_usb_or_removable "$name" || continue
        findmnt -n "$name" >/dev/null 2>&1 && continue
        if mount_token_check "$name"; then
            if token_file_matches "$USB_CHECK_MNT/$TOKEN_NAME"; then
                unmount_token_check
                return 0
            fi
            unmount_token_check
        fi
    done < <(lsblk -nr -p -o NAME 2>/dev/null)
    unmount_token_check
    return 1
}

find_rescue_token() {
    rescue_token_registered || return 1
    scan_mounted_for_token && return 0
    scan_unmounted_usb_for_token
}

# Fifth failed password: stop taking passwords. Stay locked until a
# registered rescue USB is inserted. Reboot also clears the fail count.
wait_for_lockout_key() {
    echo ""
    echo " Five failed unlock attempts. Console locked."
    if rescue_token_registered; then
        echo " Insert the rescue USB to unlock. Reboot also starts over."
    else
        echo " No rescue USB is registered. Reboot to try passwords again."
    fi
    while true; do
        if find_rescue_token; then
            echo " Rescue USB accepted."
            clear_auth_fails
            sleep 1
            return 0
        fi
        sleep 2
    done
}

note_auth_failure() {
    AUTH_TOKEN_BYPASS=0
    fails=$((fails + 1))
    [ "$fails" -gt 15 ] && fails=15
    save_auth_fails "$fails"
    echo ""
    echo " Authentication failed. (${fails}/${AUTH_LOCKOUT})"
    if [ "$fails" -ge "$AUTH_LOCKOUT" ]; then
        wait_for_lockout_key
        AUTH_TOKEN_BYPASS=1
        fails=0
        return 0
    fi
    auth_fail_wait "$fails"
}

# 1–2: 10s. 3: 60s. 4: 3min. 5: lock until rescue USB (or reboot). Count lives in /run.
auth_fail_wait() {
    local fails="$1" delay=0
    case "$fails" in
        1|2) delay=10 ;;
        3) delay=60 ;;
        4) delay=180 ;;
        *) return 0 ;;
    esac
    echo " Waiting ${delay}s before next attempt..."
    sleep "$delay"
}

require_console_auth() {
    local typed user pass fails
    fails=$(load_auth_fails)
    if [ "$fails" -ge "$AUTH_LOCKOUT" ]; then
        wait_for_lockout_key
        return 0
    fi
    if [ "$fails" -ge 1 ] && [ "$fails" -lt "$AUTH_LOCKOUT" ]; then
        auth_fail_wait "$fails"
    fi
    while true; do
        clear
        echo "========================================================="
        echo " PROJECT ANTHONY: CONSOLE UNLOCK"
        echo "========================================================="
        echo " This is a root rescue console. Unlock with a local"
        echo " account username and password before the rescue menu."
        echo " Type 'desktop' to leave without unlocking."
        echo ""
        if [ ! -x /usr/local/bin/project-anthony-auth ]; then
            echo " Auth helper is not installed. Reinstall Project Anthony."
            echo ""
        fi
        typed=""
        if ! IFS= read -r -t "$IDLE_SECS" -p " Username: " typed </dev/tty; then
            continue
        fi
        if [ -z "$typed" ]; then
            continue
        fi
        user="$typed"
        if [ "$user" = "desktop" ] || [ "$user" = "d" ] || [ "$user" = "D" ]; then
            escape_to_desktop
            exit 0
        fi
        if ! unlock_account_ok "$user"; then
            note_auth_failure
            [ "$AUTH_TOKEN_BYPASS" = 1 ] && return 0
            continue
        fi
        echo ""
        if user_has_u2f "$user"; then
            echo " This account also requires a security key after the password."
        fi
        echo ""
        pass=""
        if ! IFS= read -r -s -t "$IDLE_SECS" -p " Password: " pass </dev/tty; then
            echo ""
            continue
        fi
        echo ""
        if [ -n "$pass" ] && verify_local_password "$user" "$pass"; then
            pass=""
            unset pass
            if ! verify_security_key "$user"; then
                note_auth_failure
                [ "$AUTH_TOKEN_BYPASS" = 1 ] && return 0
                continue
            fi
            clear_auth_fails
            echo ""
            echo "✔ Console unlocked. Idle lock in ${IDLE_SECS}s."
            sleep 1
            return 0
        fi
        pass=""
        unset pass
        note_auth_failure
        [ "$AUTH_TOKEN_BYPASS" = 1 ] && return 0
    done
}
