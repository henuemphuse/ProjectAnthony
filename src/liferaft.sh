#!/bin/bash

# =========================================================================
#   PROJECT ANTHONY: CORE EMERGENCY TUI RECOVERY ENGINE (LIFERAFT)
# =========================================================================
# Description: Provides an isolated Text User Interface dashboard below
#              standard display servers to manage system freezes, disk
#              cloning, system diagnostics, and automated rollbacks.
# =========================================================================

# Desktop users (uid >= 1000) so CAD bindings survive dpkg installs with no SUDO_USER
desktop_users() {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1}'
}

gsettings_as() {
    local user="$1"
    shift
    local uid
    uid=$(id -u "$user" 2>/dev/null) || return 0
    sudo -u "$user" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" gsettings "$@" 2>/dev/null || true
}

# Numeric VT from a loginctl TTY string ("tty8", "/dev/tty8") or a raw digit.
vt_from_tty_string() {
    local tty="$1"
    if [[ "$tty" == /dev/tty[0-9]* ]]; then
        echo "${tty#/dev/tty}"
    elif [[ "$tty" == tty[0-9]* ]]; then
        echo "${tty#tty}"
    elif [[ "$tty" == [0-9]* ]]; then
        echo "$tty"
    fi
}

# Probe the machine's graphical login (not this process). F3 is a kernel VT and
# the Ctrl+Alt+X launcher often has no XDG_SESSION_TYPE, so $XDG_SESSION_TYPE
# is the wrong signal for "is Cinnamon/X11 up".
#
# LightDM's Cinnamon Wayland session reports Type=wayland, VTNr=8, and an empty
# TTY property. Reading TTY and falling back to VT 7 lands on a blank kernel
# console (black screen, blinking cursor). Prefer VTNr, skip closing sessions,
# and keep the logind session id so we can ActivateSession on the way back.
probe_graphical_session() {
    GRAPHICAL_TYPE=""
    GRAPHICAL_VT=""
    GRAPHICAL_USER=""
    GRAPHICAL_SESSION=""
    GRAPHICAL_DISPLAY="${DISPLAY:-}"
    GRAPHICAL_XAUTHORITY="${XAUTHORITY:-}"

    local sid type class state tty vtnr display name rank best_rank=99
    while read -r sid _; do
        [ -z "$sid" ] && continue
        type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
        class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null)
        state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
        { [ "$type" = "x11" ] || [ "$type" = "wayland" ]; } || continue
        [ "$class" = "user" ] || continue
        [ "$state" = "closing" ] && continue

        rank=1
        [ "$state" = "active" ] && rank=0
        [ "$rank" -ge "$best_rank" ] && continue

        vtnr=$(loginctl show-session "$sid" -p VTNr --value 2>/dev/null)
        tty=$(loginctl show-session "$sid" -p TTY --value 2>/dev/null)
        name=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
        display=$(loginctl show-session "$sid" -p Display --value 2>/dev/null)

        GRAPHICAL_SESSION="$sid"
        GRAPHICAL_TYPE="$type"
        GRAPHICAL_USER="$name"
        [ -n "$display" ] && GRAPHICAL_DISPLAY="$display"
        if [ -n "$vtnr" ] && [ "$vtnr" != "0" ]; then
            GRAPHICAL_VT="$vtnr"
        else
            GRAPHICAL_VT=$(vt_from_tty_string "$tty")
        fi
        best_rank=$rank
        [ "$rank" -eq 0 ] && break
    done < <(loginctl list-sessions --no-legend 2>/dev/null)

    if [ -z "$GRAPHICAL_TYPE" ]; then
        if pgrep -x Xorg >/dev/null; then
            GRAPHICAL_TYPE="x11"
        elif pgrep -x gnome-shell >/dev/null || pgrep -x mutter >/dev/null \
            || pgrep -x muffin >/dev/null || pgrep -x Xwayland >/dev/null; then
            GRAPHICAL_TYPE="wayland"
        elif pgrep -x cinnamon >/dev/null || pgrep -x cinnamon-session >/dev/null; then
            GRAPHICAL_TYPE="x11"
        fi
    fi

    if [ -z "$GRAPHICAL_DISPLAY" ] && [ "$GRAPHICAL_TYPE" = "x11" ]; then
        GRAPHICAL_DISPLAY=":0"
    fi
    if [ -z "$GRAPHICAL_USER" ]; then
        GRAPHICAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1; exit}')
    fi
    if [ -n "$GRAPHICAL_USER" ]; then
        local home uid
        home=$(getent passwd "$GRAPHICAL_USER" | cut -d: -f6)
        uid=$(id -u "$GRAPHICAL_USER" 2>/dev/null)
        if [ -z "$GRAPHICAL_XAUTHORITY" ] && [ -n "$home" ] && [ -f "$home/.Xauthority" ]; then
            GRAPHICAL_XAUTHORITY="$home/.Xauthority"
        fi
        if [ -z "$GRAPHICAL_XAUTHORITY" ] && [ -n "$uid" ]; then
            local f
            for f in "/run/user/${uid}/gdm/Xauthority" "/run/user/${uid}/Xauthority"; do
                if [ -f "$f" ]; then
                    GRAPHICAL_XAUTHORITY="$f"
                    break
                fi
            done
        fi
    fi
}

find_graphical_vt() {
    probe_graphical_session
    if [ -n "$GRAPHICAL_VT" ]; then
        echo "$GRAPHICAL_VT"
        return 0
    fi
    return 1
}

on_kernel_vt() {
    local t
    t=$(tty 2>/dev/null || true)
    [[ "$t" == /dev/tty[0-9]* ]]
}

# Switch back to the compositor's VT. chvt alone is enough for Xorg (VT_PROCESS).
# Wayland compositors reclaim DRM via logind ResumeDevice, so ActivateSession
# has to run first. Blindly chvt 7 is wrong here: LightDM Wayland sits on VT 8
# with an empty TTY property, and VT 7 is an unused kernel console.
escape_to_desktop() {
    probe_graphical_session
    local vt="$GRAPHICAL_VT"
    local sid="$GRAPHICAL_SESSION"

    echo "🖥️ Switching to the graphical desktop${vt:+ (TTY${vt})}..."
    sleep 1

    if [ -n "$sid" ]; then
        loginctl activate "$sid" --no-ask-password 2>/dev/null || true
    fi
    if [ -n "$vt" ] && [ "$vt" != "0" ]; then
        chvt "$vt" 2>/dev/null || true
    fi
    # Kernel VT: drop this unlocked root session so the next F3 re-prompts.
    t=$(tty 2>/dev/null || true)
    if [[ "$t" == /dev/tty[0-9]* ]]; then
        exit 0
    fi
    return 0
}

# Disk names only (sda, nvme0n1). No slashes, no "..".
is_disk_name() {
    [[ "$1" =~ ^[a-zA-Z0-9]+([-_][a-zA-Z0-9]+)*$ ]]
}

# Image-file destinations: realpath must stay under /mnt, /media, /root, or /home.
allowed_clone_dir() {
    local raw="$1" real
    case "$raw" in
        *..*) return 1 ;;
    esac
    [ -d "$raw" ] || return 1
    real=$(realpath "$raw" 2>/dev/null) || return 1
    case "$real" in
        /mnt|/mnt/*|/media|/media/*|/root|/root/*|/home/*)
            return 0
            ;;
    esac
    return 1
}

page_manual() {
    local f="$1"
    [ -f "$f" ] || return 1
    # LESSSECURE disables less's ! shell, pipe, and edit escapes.
    LESSSECURE=1 less -X -- "$f"
}

# Unlock TTY3 / crash-console once per process. Physical console is already
# root; this checks a local account password via PAM before any menu action.
unlock_account_ok() {
    local user="$1" uid
    [[ "$user" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]] || return 1
    uid=$(id -u "$user" 2>/dev/null) || return 1
    [ "$uid" -eq 0 ] || { [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; }
}

default_unlock_user() {
    probe_graphical_session
    if [ -n "$GRAPHICAL_USER" ] && unlock_account_ok "$GRAPHICAL_USER"; then
        echo "$GRAPHICAL_USER"
        return 0
    fi
    desktop_users | head -n1
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

token_file_matches() {
    local got want raw
    [ -f "$1" ] && [ -r "$1" ] || return 1
    raw=$(tr -d ' \t\r\n' < "$1" 2>/dev/null)
    [ "${#raw}" -ge 32 ] || return 1
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

fstype_token_ok() {
    case "$1" in
        vfat|fat|fat32|msdos|exfat|ntfs|ntfs3|ext2|ext3|ext4|btrfs|xfs|udf|iso9660|f2fs) return 0 ;;
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
        if mount -o ro,nosuid,nodev,noexec "$name" "$USB_CHECK_MNT" 2>/dev/null; then
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
    local default_user typed user pass fails
    fails=$(load_auth_fails)
    default_user=$(default_unlock_user)
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
        echo " account password before the menu or crash restore."
        echo ""
        if [ ! -x /usr/local/bin/project-anthony-auth ]; then
            echo " Auth helper is not installed. Reinstall Project Anthony."
            echo ""
        fi
        if [ -n "$default_user" ]; then
            echo " User [$default_user], or 'desktop' to leave:"
        else
            echo " User (or 'desktop' to leave):"
        fi
        typed=""
        if ! IFS= read -r -t "$IDLE_SECS" -p " " typed </dev/tty; then
            continue
        fi
        if [ -z "$typed" ]; then
            user="$default_user"
        else
            user="$typed"
        fi
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

# 🧼 THE INTEGRATED SELF-CLEANUP UNINSTALL ENGINE
execute_system_teardown() {
    echo "=================================================="
    echo "          PROJECT ANTHONY: SELF-CLEANUP           "
    echo "=================================================="
    
    # Verify root execution privileges for system file modification
    if [ "$EUID" -ne 0 ]; then
        echo "❌ Error: System teardown requires elevated root privileges."
        echo "Please re-run using: sudo project-anthony --uninstall"
        exit 1
    fi

    # 0. Stop the crash watchdog so it cannot fire during teardown
    echo "🐕 Stopping crash watchdog..."
    systemctl stop project-anthony-monitor.service 2>/dev/null || true
    systemctl disable project-anthony-monitor.service 2>/dev/null || true
    rm -f /run/project-anthony-state /run/project-anthony-monitor.cursor /run/project-anthony-auth-fails \
        /run/project-anthony-log-alert /run/project-anthony-log-ratelimit
    rm -rf /var/log/project-anthony
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
        rm -f /etc/systemd/system/project-anthony-monitor.service
        rm -f /usr/local/bin/project-anthony-monitor
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 1. Sever the System Update APT Hook
    echo "⚓ Step 1: Dismantling automated update hook..."
    HOOK_CONF="/etc/apt/apt.conf.d/99-liferaft-autosnap"
    if [ -f "$HOOK_CONF" ]; then
        rm -f "$HOOK_CONF"
        echo "✔ Successfully removed APT layer hook."
    fi

    # 2. Wipe Background Executable Components (only when not invoked from dpkg)
    echo "📸 Step 2: Removing rolling snapshot shield..."
    AUTOSNAP_PATH="/usr/local/bin/liferaft-autosnap.sh"
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ] && [ -f "$AUTOSNAP_PATH" ]; then
        rm -f "$AUTOSNAP_PATH"
        echo "✔ Successfully removed background snapshot matrix."
    fi

    # 3. Restore systemd Ctrl+Alt+Del to the stock reboot target
    echo "⚓ Step 3: Restoring systemd Ctrl+Alt+Del reboot target..."
    rm -f /etc/systemd/system/ctrl-alt-del.target
    rm -f /etc/systemd/system/project-anthony-cad.service
    systemctl daemon-reload
    echo "✔ systemd Ctrl+Alt+Del restored to default reboot behavior."

    # 4. Remove TTY3 rescue service and restore stock getty
    echo "⚓ Step 4: Removing TTY3 rescue console..."
    systemctl disable --now project-anthony-tty.service >/dev/null 2>&1 || true
    rm -rf /etc/systemd/system/getty@tty3.service.d
    rm -f /etc/xdg/autostart/project-anthony-hotkeys.desktop
    rm -f /etc/xdg/autostart/project-anthony-first-run.desktop
    rm -rf /etc/project-anthony
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
        rm -f /etc/systemd/system/project-anthony-tty.service
        rm -f /usr/local/bin/project-anthony-tty
        rm -f /usr/local/bin/project-anthony-bind-hotkeys
        rm -f /usr/local/bin/project-anthony-show-manual
        rm -f /usr/local/bin/project-anthony-auth
        rm -f /usr/local/bin/project-anthony-mk-token
        rm -f /etc/pam.d/project-anthony
        rm -f /etc/pam.d/project-anthony-u2f
        rm -f /usr/share/applications/project-anthony.desktop
        rm -f /usr/share/applications/project-anthony-manual.desktop
        rm -f /usr/share/doc/project-anthony/README.txt
        rm -f /usr/share/doc/project-anthony/LICENSE
        rm -f /usr/share/doc/project-anthony/copyright
        rmdir /usr/share/doc/project-anthony 2>/dev/null || true
    fi
    for u in $(desktop_users); do
        local_home=$(getent passwd "$u" | cut -d: -f6)
        [ -n "$local_home" ] || continue
        rm -f "${local_home}/Desktop/project-anthony.desktop"
        rm -f "${local_home}/Desktop/project-anthony-manual.desktop"
        rm -f "${local_home}/desktop/project-anthony.desktop"
        rm -f "${local_home}/desktop/project-anthony-manual.desktop"
        rm -f "${local_home}/.config/project-anthony/manual-seen"
    done
    systemctl unmask getty@tty3.service >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl reset-failed getty@tty3.service >/dev/null 2>&1 || true
    systemctl start getty@tty3.service >/dev/null 2>&1 || true
    echo "✔ TTY3 restored to a normal login getty."

    # 5. Disable Magic SysRq drop-in
    echo "⌨️  Step 5: Removing Magic SysRq sysctl drop-in..."
    rm -f /etc/sysctl.d/99-project-anthony-sysrq.conf
    sysctl --system >/dev/null 2>&1 || true

    # 6. Restore Cinnamon Ctrl+Alt+Del logout mapping for every desktop user
    echo "⌨️  Step 6: Restoring desktop Ctrl+Alt+Del logout shortcut..."
    if [ -x /usr/local/bin/project-anthony-bind-hotkeys ]; then
        /usr/local/bin/project-anthony-bind-hotkeys --unbind || true
    else
        for u in $(desktop_users); do
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.media-keys logout "['<Control><Alt>Delete']"
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/ binding "[]"
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/ command "''"
        done
    fi
    echo "✔ Desktop logout hotkey restored."

    # 7. Scrub the TTY3 Shell Trap from root's .bashrc
    echo "🧹 Step 7: Scrubbing shell trap blocks from /root/.bashrc..."
    if [ -f /root/.bashrc ]; then
        sed -i '/# Project Anthony TTY3 Shell Trap Module/,/fi/d' /root/.bashrc
        echo "✔ Finished scanning and cleaning /root/.bashrc lines."
    fi

    # 8. Purge the Core Menu Launcher Last (never steal files from a live dpkg remove)
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
        echo "🚀 Step 8: Deleting core UI launcher binary..."
        LAUNCHER_PATH="/usr/local/bin/project-anthony"
        if [ -f "$LAUNCHER_PATH" ]; then
            rm -f "$LAUNCHER_PATH"
            echo "✔ Core binary flagged for deletion."
        fi
        (
            sleep 1
            dpkg --purge project-anthony &>/dev/null
        ) &
    fi

    echo "=================================================="
    echo "🧹 PROJECT ANTHONY WIPE COMPLETE!        "
    echo "=================================================="

    # Adaptive session type check for a clean graphical exit
    CURRENT_SESSION_TYPE="$XDG_SESSION_TYPE"
    if [ -z "$CURRENT_SESSION_TYPE" ]; then
        CURRENT_SESSION_TYPE=$(loginctl show-session $(loginctl | grep "$USER" | awk '{print $1}') -p Type | cut -d= -f2)
    fi

    if [ "$CURRENT_SESSION_TYPE" == "x11" ]; then
        escape_to_desktop
    else
        echo "🚪 Wayland context detected. Closing environment window safely..."
        sleep 1
        exit 0
    fi
}

# Prompt used when the background watchdog detects a crash.
# Y restores from Timeshift. N asks whether to return to the desktop.
# State file (written by anthony-monitor): line 1 = CRASH_TRIGGERED,
# line 2 = one-line summary, remaining lines = short evidence snippet.
STATE_FILE="/run/project-anthony-state"
LOG_FILE="/var/log/project-anthony/system.log"
ALERT_FILE="/run/project-anthony-log-alert"
# Match anthony-monitor.sh: printable ASCII, 8 x 76. Re-apply on read so a
# stale or tampered state file cannot inject control chars into the TTY.
sanitize_crash_text() {
    tr -cd '\11\12\15\40-\176' \
        | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' \
        | cut -c1-76 \
        | grep -v '^$' \
        | head -n 8
}

# Flag is world-readable on purpose (token ERROR only). Evidence is 0600.
system_log_status() {
    if [ -f "$ALERT_FILE" ]; then
        echo "error"
    else
        echo "OK"
    fi
}

# Static snapshot only: last 12 records, never journalctl/dmesg --follow.
MAX_LOG_RECORDS=12
MAX_LOG_RECORD_LINES=7
LOG_READ_BYTES=16384

sanitize_system_log_line() {
    tr -cd '\11\12\15\40-\176' | cut -c1-76
}

# Keep the newest MAX_LOG_RECORDS blocks (=== stamped records).
last_log_records() {
    awk -v max="$MAX_LOG_RECORDS" -v per="$MAX_LOG_RECORD_LINES" '
        /^=== / {
            rec++
            nlines[rec] = 0
        }
        {
            if (rec < 1) next
            if (nlines[rec] >= per) next
            nlines[rec]++
            buf[rec] = buf[rec] $0 "\n"
        }
        END {
            start = rec - max + 1
            if (start < 1) start = 1
            for (i = start; i <= rec; i++) printf "%s", buf[i]
        }
    '
}

# Bounded snapshot of the on-disk log. Not a live kernel feed.
read_system_log_raw() {
    if [ "$(id -u)" -eq 0 ]; then
        tail -c "$LOG_READ_BYTES" "$LOG_FILE" 2>/dev/null || true
        rm -f "$ALERT_FILE"
        return 0
    fi
    sudo /bin/sh -c 'tail -c 16384 /var/log/project-anthony/system.log 2>/dev/null || true; rm -f /run/project-anthony-log-alert'
}

clear_system_log() {
    if [ "$(id -u)" -eq 0 ]; then
        rm -f "$LOG_FILE" "$ALERT_FILE"
        return 0
    fi
    sudo /bin/sh -c 'rm -f /var/log/project-anthony/system.log /run/project-anthony-log-alert' 2>/dev/null || true
}

show_system_logs() {
    local raw="" status rc=0
    clear
    echo "========================================================="
    echo "  PROJECT ANTHONY: SYSTEM LOGS"
    echo "========================================================="
    status=$(system_log_status)
    echo "  status: $status"
    echo "  Last ${MAX_LOG_RECORDS} recorded events (snapshot, not a live feed)"
    echo "---------------------------------------------------------"
    echo ""

    raw=$(read_system_log_raw)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  Cannot read the system log (administrator privileges required)."
        echo "  Evidence stays root-only; the status flag is not cleared."
        echo ""
        echo "---------------------------------------------------------"
        tui_read fakeKey "Press [Enter] to return..."
        return
    fi

    raw=$(printf '%s\n' "$raw" | sanitize_system_log_line | last_log_records)
    if [ -z "$raw" ]; then
        echo "  No Project Anthony errors recorded."
        echo "  Self-faults and rescue trips show a short snapshot here."
    else
        printf '%s\n' "$raw"
    fi

    echo ""
    echo "---------------------------------------------------------"
    echo "  [Enter] return to menu    [c] clear log"
    echo "---------------------------------------------------------"
    tui_read log_choice "Enter command: "
    if [[ "$log_choice" == "c" || "$log_choice" == "C" ]]; then
        clear_system_log
        echo ""
        echo "✔ System log cleared."
        sleep 1
    fi
}

rolling_snapshot_id() {
    local id
    id=$(sudo timeshift --list 2>/dev/null | grep "SYSTEM_LIFERAFT_ROLLING" | awk '{print $3}')
    [[ "$id" =~ ^[0-9A-Za-z._-]+$ ]] || return 1
    printf '%s\n' "$id"
}

crash_recovery_prompt() {
    local summary="" details=""
    if [ -f "$STATE_FILE" ]; then
        summary=$(sed -n '2p' "$STATE_FILE" 2>/dev/null | sanitize_crash_text | head -n 1)
        details=$(tail -n +3 "$STATE_FILE" 2>/dev/null | sanitize_crash_text)
        rm -f "$STATE_FILE"
    fi
    if [ -z "$summary" ]; then
        if [ "$1" = "--crash-prompt" ]; then
            summary="Test crash prompt (no live watchdog event)"
        else
            summary="a system crash"
        fi
    fi

    clear
    echo "========================================================="
    echo "⚠️  PROJECT ANTHONY: CRASH RECOVERY SHIELD"
    echo "========================================================="
    echo "Anthony monitor has detected:"
    echo ""
    echo "  $summary"
    if [ -n "$details" ]; then
        echo ""
        printf '%s\n' "$details" | sed 's/^/  /'
    fi
    echo ""
    echo "Would you like to restore from backup? [y/n]"
    echo "---------------------------------------------------------"
    echo ""
    tui_read crash_choice "Enter choice [y/n]: "
    echo ""

    if [[ "$crash_choice" == "y" || "$crash_choice" == "Y" ]]; then
        echo "🚀 Opening Timeshift restore..."
        SYSTEM_SNAP_ID=$(rolling_snapshot_id || true)
        if [ -n "$SYSTEM_SNAP_ID" ]; then
            sudo timeshift --restore --snapshot "$SYSTEM_SNAP_ID"
        else
            echo "❌ SYSTEM_LIFERAFT_ROLLING recovery point not found."
            echo "Opening the full Timeshift restore wizard instead..."
            sudo timeshift --restore
        fi
        tui_read fakeKey "Press [Enter] to continue..."
        return 0
    fi

    tui_read desk_choice "Would you like to return to the desktop? [y/n]: "
    echo ""
    if [[ "$desk_choice" == "y" || "$desk_choice" == "Y" ]]; then
        escape_to_desktop
        exit 0
    fi
}

# 📑 ARGUMENT PARSER & DYNAMIC RESOLUTION INTERCEPT MATRIX
# Intercepts flags right at execution before painting the terminal view frame
if [ "$1" == "--uninstall" ]; then
    execute_system_teardown
    exit 0
fi

if [ "$1" == "--manual" ] || [ "$1" == "--help" ]; then
    exec /usr/local/bin/project-anthony-show-manual
fi

# Kernel VTs (Ctrl+Alt+F3) have no DISPLAY. Run the TUI in-place so a
# frozen compositor cannot block the escape hatch.
CURRENT_TTY=$(tty 2>/dev/null || true)
ON_KERNEL_VT=0
if [[ "$CURRENT_TTY" == /dev/tty[0-9]* ]]; then
    ON_KERNEL_VT=1
fi

# This wrapper checks the display hardware grid and forces a perfectly upscaled
# full-screen terminal layout profile if launched from a living desktop session.
if [ "$1" != "--run-core-menu" ] && [ "$1" != "--crash-prompt" ] && [ "$1" != "--manual" ] && [ "$1" != "--help" ] && [ "$ON_KERNEL_VT" -eq 0 ] && { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; }; then
    if command -v xrandr &>/dev/null && [ "$XDG_SESSION_TYPE" == "x11" ]; then
        # X11 Layer Check: Grab the vertical resolution pixel metric
        V_RES=$(xrandr --current | grep -w connected | grep -oE '[0-9]+x[0-9]+' | head -n1 | cut -d'x' -f2)
    else
        # Wayland / Fallback Layer Check: Query DRM graphics nodes directly
        V_RES=$(cat /sys/class/drm/*/modes 2>/dev/null | grep -E '^[0-9]+x[0-9]+' | head -n1 | cut -d'x' -f2)
    fi

    # Baseline safe tracking fallback if display metrics fail to report completely
    [ -z "$V_RES" ] && V_RES=1080

    # Evaluate Resolution Profiles
    if [ "$V_RES" -ge 1440 ]; then
        # 1440p High-Density Display Scale Profile (Perfect for your 1440p display!)
        ZOOM_SCALE="1.5"
    elif [ "$V_RES" -ge 1080 ]; then
        # 1080p Standard Desktop Scale Profile
        ZOOM_SCALE="1.0"
    else
        # 720p / Low-Resolution Scale Profile
        ZOOM_SCALE="0.85"
    fi

    # Relaunch ourselves inside a clean, perfectly scaled full-screen terminal window
    # The '--run-core-menu' flag lets the script know it can skip the check on the next loop
    exec gnome-terminal --full-screen --zoom="$ZOOM_SCALE" -- "$0" --run-core-menu
fi

# TTY3 / crash console is already root. Unlock with a local password before
# the crash restore prompt or the rescue menu. Desktop Ctrl+Alt+X is unchanged.
if [ "$ON_KERNEL_VT" -eq 1 ]; then
    require_console_auth || exit 1
fi

# 🚨 Watchdog intercept: crash flag from the monitor, or an explicit test flag
if [ "$1" == "--crash-prompt" ] || { [ -f "$STATE_FILE" ] && [ "$(head -n1 "$STATE_FILE" 2>/dev/null)" = "CRASH_TRIGGERED" ]; }; then
    crash_recovery_prompt "$1"
fi


# =========================================================================
# 📋 MAIN INTERACTIVE CORE LOOP 
# =========================================================================
while true
do
	clear
	echo "=========================================="
	echo "          PROJECT ANTHONY: RESCUE         "
	echo "=========================================="
	echo " 1. Desktop Client Reinitialization (X11/Wayland)"
	echo " 2. Create Disk Image & Drive Migration (ddrescue)"
	echo " 3. Timeshift Restore (System)"
	echo " 4. Hardware & Kernel Diagnostics (Voltages/Logs)"
	
		# 🖥️ DYNAMIC SESSION & TTY EVALUATION MATRIX
	probe_graphical_session
	CURRENT_TTY=$(tty)
	GRAPHICAL_VT="$GRAPHICAL_VT"
	ON_RESCUE_VT=0
	if [[ "$CURRENT_TTY" == /dev/tty[0-9]* ]]; then
		ON_RESCUE_VT=1
		CURRENT_SESSION_TYPE="tty"
	else
		CURRENT_SESSION_TYPE="${XDG_SESSION_TYPE:-$GRAPHICAL_TYPE}"
	fi

	# Rescue console still has a desktop to jump back to — that is the whole point of F3.
	if [ "$ON_RESCUE_VT" -eq 1 ]; then
		if [ -n "$GRAPHICAL_VT" ]; then
			echo " 5. Return to Graphical Desktop (TTY${GRAPHICAL_VT})"
		else
			echo " 5. Return to Graphical Desktop"
		fi
	else
		echo " 5. Exit to Graphical Desktop"
	fi
	echo " 6. System logs (status: $(system_log_status))"
	echo " h. View Manual (hotkeys, what it does, how to open it)"
	echo "=========================================="
	echo " Access: Ctrl+Alt+X (desktop)  |  Ctrl+Alt+F3 (frozen)  |  Alt+SysRq+R then F3 (stuck keyboard)"
	echo "=========================================="
	tui_read choice "Enter choice: "

	case $choice in
		1)
			while true; do
			clear
			echo "🔄 Desktop Client Reinitialization"
			echo "==========================================="
			
			# Use the machine's graphical session, not this process's TTY/env.
			probe_graphical_session
			CURRENT_SESSION_TYPE="${GRAPHICAL_TYPE:-unknown}"

			echo "📊 Active Graphics Environment Layer: ${CURRENT_SESSION_TYPE^^}"
			if [ -n "$GRAPHICAL_USER" ]; then
				echo "   Session user: ${GRAPHICAL_USER}   display: ${GRAPHICAL_DISPLAY:-n/a}"
			fi
			echo "-------------------------------------------"
			echo "Select which display action to execute:"
			
			if [ "$CURRENT_SESSION_TYPE" == "x11" ]; then
				echo " a) Restart Cinnamon Desktop (Keep open applications)"
			else
				echo " a) [DISABLED] Soft restart is unsupported on Wayland architecture"
			fi
			echo " b) Force Reset Display Manager (Reload LightDM Login Interface)"
			echo " c) Return to Main Menu"
			echo " x) EMERGENCY: Exit straight to desktop"
			echo "-------------------------------------------"
			tui_read desktop_choice "Enter choice [a-x]: "
			echo ""

			case $desktop_choice in
				a)
					if [ "$CURRENT_SESSION_TYPE" == "x11" ]; then
						echo "⚡ Attempting an in-place soft restart of Cinnamon..."
						probe_graphical_session
						local_display="${GRAPHICAL_DISPLAY:-:0}"
						local_user="${GRAPHICAL_USER:-}"
						local_auth="${GRAPHICAL_XAUTHORITY:-}"
						local_uid=""
						[ -n "$local_user" ] && local_uid=$(id -u "$local_user" 2>/dev/null)
						local_dbus=""
						[ -n "$local_uid" ] && [ -S "/run/user/${local_uid}/bus" ] && local_dbus="unix:path=/run/user/${local_uid}/bus"
						# stdin MUST be /dev/null or cinnamon inherits this TTY and eats Enter.
						if [ "$(id -u)" -eq 0 ] && [ -n "$local_user" ] && [ "$local_user" != "root" ]; then
							sudo -u "$local_user" env \
								DISPLAY="$local_display" \
								${local_auth:+XAUTHORITY="$local_auth"} \
								${local_dbus:+DBUS_SESSION_BUS_ADDRESS="$local_dbus"} \
								${local_uid:+XDG_RUNTIME_DIR="/run/user/${local_uid}"} \
								cinnamon --replace </dev/null >/dev/null 2>&1 &
						else
							env DISPLAY="$local_display" \
								${local_auth:+XAUTHORITY="$local_auth"} \
								cinnamon --replace </dev/null >/dev/null 2>&1 &
						fi
						disown >/dev/null 2>&1 || true
						echo "✔ Refresh signal transmitted to the active desktop environment."
					else
						echo "⛔ Action blocked! Soft-replacing a compositor on Wayland will crash your session."
					fi
					tui_read fakeKey "Press [Enter] key to continue..."
					;;
				b)
					echo "⚠️ WARNING: This action will instantly force-close all open applications!"
					tui_read confirm_reset "Are you sure you want to completely reload LightDM? [y/n]: "
					if [ "$confirm_reset" == "y" ] || [ "$confirm_reset" == "Y" ]; then
						echo "🚀 Restarting LightDM Display Manager..."
						sudo systemctl restart display-manager
					else
						echo "❌ Reset sequence aborted."
						tui_read fakeKey "Press [Enter] key to continue..."
					fi
					;;
				c|"")
					break
					;;
				x)
					escape_to_desktop
					;;
				*)
					echo "❌ Invalid choice option selected."
					tui_read fakeKey "Press [Enter] key to continue..."
					;;
			esac
			done
			;;
		2)
			echo "💾 Project Anthony: Enhanced Capacity & Storage Matrix"
			echo "========================================================================="
			printf "%-12s | %-20s | %-8s | %-8s | %-12s\n" "DEVICE" "MODEL / NAME" "TOTAL" "FREE" "SMART HEALTH"
			echo "------------------------------------------------------------------------="
			
			if ! command -v smartctl &>/dev/null; then
				echo "⚠️  smartctl is not installed. SMART health will show as unknown."
				echo "    Install smartmontools from a normal session if you need it."
			fi

			for disk in $(lsblk -dno NAME,TYPE | grep "disk" | awk '{print $1}'); do
				MODEL=$(lsblk -dno MODEL "/dev/$disk" | sed 's/^[ \t]*//;s/[ \t]*$//')
				[ -z "$MODEL" ] && MODEL="Generic Disk"
				SIZE=$(lsblk -dno SIZE "/dev/$disk" | sed 's/^[ \t]*//;s/[ \t]*$//')
				
				# 📊 FREE SPACE CALCULATOR BLOCK
				FIRST_PART=$(lsblk -no NAME,TYPE "/dev/$disk" | grep "part" | head -n1 | awk '{print $1}')
				FREE_SPACE="--"
				
				if [ ! -z "$FIRST_PART" ]; then
					MOUNT_POINT=$(lsblk -no MOUNTPOINTS "/dev/$FIRST_PART" | head -n1)
					if [ ! -z "$MOUNT_POINT" ]; then
						FREE_SPACE=$(df -h "$MOUNT_POINT" | tail -n1 | awk '{print $4}')
					else
						FREE_SPACE="Unmounted"
					fi
				fi
				
				SMART_RAW=$(sudo smartctl -H "/dev/$disk" 2>/dev/null)
				if echo "$SMART_RAW" | grep -q "PASSED"; then HEALTH="🟢 PASSED"
				elif echo "$SMART_RAW" | grep -q "FAILED"; then HEALTH="🔴 FAILED!"
				elif echo "$SMART_RAW" | grep -q "OK"; then HEALTH="🟢 OK"
				else HEALTH="⚪ UNKNOWN"; fi

				printf "%-12s | %-20.20s | %-8s | %-8s | %-12s\n" "/dev/$disk" "$MODEL" "$SIZE" "$FREE_SPACE" "$HEALTH"
			done
			echo "========================================================================="
			echo "👉 Press [Enter] to return or [x] to exit straight to desktop"
			echo ""
			
			tui_read drive_choice "Select drive to image (e.g., sda): "
			if [ "$drive_choice" == "x" ] || [ "$drive_choice" == "X" ]; then escape_to_desktop; continue; fi
			if [ -z "$drive_choice" ]; then continue; fi
			
			if ! is_disk_name "$drive_choice" || [ ! -b "/dev/$drive_choice" ]; then
				echo "❌ Error: Device '/dev/$drive_choice' is not a valid block device."
				tui_read fakeKey "Press [Enter] key to continue..."
				continue
			fi

			SRC_PATH="/dev/$drive_choice"
			SRC_SIZE_BYTES=$(blockdev --getsize64 "$SRC_PATH")
			SRC_SIZE_GB=$(echo "scale=2; $SRC_SIZE_BYTES / 1024 / 1024 / 1024" | bc)

			tui_read dest_choice "Enter DESTINATION drive or path (or [x] to exit straight to desktop): "
			if [ "$dest_choice" == "x" ] || [ "$dest_choice" == "X" ]; then escape_to_desktop; continue; fi
			if [ -z "$dest_choice" ]; then continue; fi
			
			if [[ "$dest_choice" == *"$drive_choice"* ]]; then
				echo "⛔ CRITICAL ERROR: Destination cannot match or reside on source hardware!"
				tui_read fakeKey "Press [Enter] key to continue..."
				continue
			fi

			if is_disk_name "$dest_choice" && [ -b "/dev/$dest_choice" ]; then
				DEST_PATH="/dev/$dest_choice"
				DEST_SIZE_BYTES=$(blockdev --getsize64 "$DEST_PATH")
				DEST_SIZE_GB=$(echo "scale=2; $DEST_SIZE_BYTES / 1024 / 1024 / 1024" | bc)

				echo "📊 Sizing Analysis:"
				echo "   Source size:      $SRC_SIZE_GB GB"
				echo "   Destination size: $DEST_SIZE_GB GB"

				if (( $(echo "$DEST_SIZE_BYTES < $SRC_SIZE_BYTES" | bc -l) )); then
					echo "⚠️ WARNING: Target drive is SMALLER than source hardware."
					tui_read force_choice "Force proceed anyway? [y/n]: "
					if [[ "$force_choice" != "y" && "$force_choice" != "Y" ]]; then continue; fi
				fi
			elif allowed_clone_dir "$dest_choice"; then
				DEST_PATH="$dest_choice/${drive_choice}_backup.img"
			else
				echo "❌ Error: Destination must be another disk (e.g. sdb) or a folder"
				echo "   under /mnt, /media, /root, or /home."
				tui_read fakeKey "Press [Enter] key to continue..."
				continue
			fi

			echo "--------------------------------------------------"
			echo "🚨 PROPOSED DISK DEPLOYMENT TARGET:"
			echo "   SOURCE:      $SRC_PATH ($SRC_SIZE_GB GB)"
			echo "   DESTINATION: $DEST_PATH"
			echo "--------------------------------------------------"
			tui_read final_lock "Commit to hardware migration? [y/n]: "

			if [[ "$final_lock" == "y" || "$final_lock" == "Y" ]]; then
				echo "🚀 Deploying cloning stream via ddrescue..."
				if [ "$(id -u)" -eq 0 ]; then
					RESCUE_LOG="/root/${drive_choice}_rescue.log"
				else
					RESCUE_LOG="${HOME:-/tmp}/${drive_choice}_rescue.log"
				fi
				sudo ddrescue -v -b 4096 "$SRC_PATH" "$DEST_PATH" "$RESCUE_LOG"
				echo "✔ Sector streaming complete."
			else
				echo "❌ Migration execution cancelled."
			fi
			tui_read fakeKey "Press [Enter] key to continue..."
			;;
		3)
			echo "🚨 Timeshift System Restoration"
			echo "------------------------------------------"
			SYSTEM_SNAP_ID=$(rolling_snapshot_id || true)

			if [ ! -z "$SYSTEM_SNAP_ID" ]; then
				tui_read quick_choice "Restore from automated system backup ($SYSTEM_SNAP_ID)? [y/n] (or [x] to exit to desktop): "
				if [ "$quick_choice" == "x" ] || [ "$quick_choice" == "X" ]; then escape_to_desktop; continue; fi
				if [ "$quick_choice" == "y" ] || [ "$quick_choice" == "Y" ]; then
					echo "🚀 Initiating instant rollback to snapshot $SYSTEM_SNAP_ID..."
					sudo timeshift --restore --snapshot "$SYSTEM_SNAP_ID"
					tui_read fakeKey "Press [Enter] key to continue..."
					continue
				fi
			fi

			echo "📋 Opening full snapshot selection wizard..."
			sudo timeshift --restore
			tui_read fakeKey "Press [Enter] key to continue..."
			;;
		4)
			clear
			echo "📊 Project Anthony: Hardware & Kernel Diagnostics"
			echo "========================================================================="
			
			if ! command -v sensors &>/dev/null; then
				echo "⚠️  sensors is not installed. Voltage/fan data will be skipped."
				echo "    Install lm-sensors from a normal session if you need it."
			fi

			echo "⚡ Motherboard Voltages, Thermals & Fan Controllers:"
			echo "-------------------------------------------------------------------------"
			sensors 2>/dev/null | grep -E "Vcore|12V|5V|3.3V|in|fan|temp|Crit|Core" || echo "⚠️  No compatible monitoring sensors exposed."
			echo "-------------------------------------------------------------------------"
			echo ""
			echo "🧠 Core Kernel Alerts & Hardware Allocations (Last 5 Alerts):"
			echo "-------------------------------------------------------------------------"
			sudo dmesg -T | grep -Ei "error|fail|panic|corrupt|kill|hardware" | tail -n 5 || echo "✔ Kernel reports clean hardware allocations."
			echo "-------------------------------------------------------------------------"
			echo ""
			echo "👉 Press [Enter] to return or [x] to exit straight to desktop"
			tui_read diagnostic_exit "Enter command: "
			if [[ "$diagnostic_exit" == "x" || "$diagnostic_exit" == "X" ]]; then
				escape_to_desktop
			fi
			;;
		5)
			if [ "$ON_RESCUE_VT" -eq 1 ]; then
				escape_to_desktop
				# Exit so systemd restarts a locked TUI. Next F3 asks again.
				exit 0
			else
				# Already inside a desktop terminal window — just close the TUI.
				exit 0
			fi
			;;
		6)
			show_system_logs
			;;
		h|H|help|manual|m|M)
			MANUAL="/usr/share/doc/project-anthony/README.txt"
			[ -f "$MANUAL" ] || MANUAL="/usr/share/doc/project-anthony/README"
			if [ "$ON_RESCUE_VT" -eq 1 ] || [ ! -x /usr/local/bin/project-anthony-show-manual ]; then
				page_manual "$MANUAL"
			else
				/usr/local/bin/project-anthony-show-manual || page_manual "$MANUAL"
			fi
			;;
		u|uninstall|U|UNINSTALL)
			echo "⚠️  Initiating built-in system uninstallation sequence..."
			tui_read confirm_ui_wipe "Are you absolutely sure you want to delete Project Anthony? [y/n]: "
			if [[ "$confirm_ui_wipe" == "y" || "$confirm_ui_wipe" == "Y" ]]; then
				execute_system_teardown
			else
				echo "❌ Action cancelled. Returning to dashboard..."
				sleep 1
			fi
			;;
		*)
			echo "❌ Invalid option or utility command. Please try again."
			tui_read fakeKey "Press [Enter] key to continue..."
			;;
	esac
done