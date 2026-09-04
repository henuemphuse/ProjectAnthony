# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# Rescue sub-screens (desktop, Timeshift, diagnostics, logs, manual,
# uninstall confirm). Menu draw/input is tui-menu.sh. Crash is tui-crash.sh.

page_manual() {
    local f="$1"
    [ -f "$f" ] || return 1
    # LESSSECURE disables less's ! shell, pipe, and edit escapes.
    LESSSECURE=1 less -X -- "$f"
}

LOG_FILE="/var/log/project-anthony/system.log"
ALERT_FILE="/run/project-anthony-log-alert"

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
    id=$(run_priv timeshift --list 2>/dev/null | grep "SYSTEM_LIFERAFT_ROLLING" | awk '{print $3}' | tail -n1)
    [[ "$id" =~ ^[0-9A-Za-z._-]+$ ]] || return 1
    printf '%s\n' "$id"
}

desktop_reinit_menu() {
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
                    # Never start cinnamon as root: empty GRAPHICAL_USER used to fall
                    # through to a root --replace on :0.
                    if [ "$(id -u)" -eq 0 ]; then
                        if [ -z "$local_user" ] || [ "$local_user" = "root" ]; then
                            echo "❌ No desktop user session found. Cannot soft-restart Cinnamon."
                            echo "   Use option b to restart the display manager instead."
                        else
                            run_as_user "$local_user" env \
                                DISPLAY="$local_display" \
                                ${local_auth:+XAUTHORITY="$local_auth"} \
                                ${local_dbus:+DBUS_SESSION_BUS_ADDRESS="$local_dbus"} \
                                ${local_uid:+XDG_RUNTIME_DIR="/run/user/${local_uid}"} \
                                cinnamon --replace </dev/null >/dev/null 2>&1 &
                            echo "✔ Refresh signal transmitted to the active desktop environment."
                        fi
                    else
                        env DISPLAY="$local_display" \
                            ${local_auth:+XAUTHORITY="$local_auth"} \
                            cinnamon --replace </dev/null >/dev/null 2>&1 &
                        echo "✔ Refresh signal transmitted to the active desktop environment."
                    fi
                    disown >/dev/null 2>&1 || true
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
                    run_priv systemctl restart display-manager
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
}

timeshift_restore_menu() {
    echo "🚨 Timeshift System Restoration"
    echo "------------------------------------------"
    SYSTEM_SNAP_ID=$(rolling_snapshot_id || true)

    if [ ! -z "$SYSTEM_SNAP_ID" ]; then
        tui_read quick_choice "Restore from automated system backup ($SYSTEM_SNAP_ID)? [y/n] (or [x] to exit to desktop): "
        if [ "$quick_choice" == "x" ] || [ "$quick_choice" == "X" ]; then escape_to_desktop; return; fi
        if [ "$quick_choice" == "y" ] || [ "$quick_choice" == "Y" ]; then
            echo "🚀 Initiating instant rollback to snapshot $SYSTEM_SNAP_ID..."
            run_priv timeshift --restore --snapshot "$SYSTEM_SNAP_ID"
            tui_read fakeKey "Press [Enter] key to continue..."
            return
        fi
    fi

    echo "📋 Opening full snapshot selection wizard..."
    run_priv timeshift --restore
    tui_read fakeKey "Press [Enter] key to continue..."
}

hardware_diagnostics() {
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
    # Drop LSM/audit/sandbox noise ("kill" was matching AppArmor signal=kill).
    alerts=$(run_priv dmesg -T 2>/dev/null | grep -Ei "error|fail|panic|oops|bug:|corrupt|oom|out of memory|hardware|mce|i/o error" \
        | grep -Eiv 'audit:|apparmor=|seccomp|ufw block|cursor_sandbox' \
        | tail -n 5)
    if [ -n "$alerts" ]; then
        printf '%s\n' "$alerts"
    else
        echo "✔ Kernel reports clean hardware allocations."
    fi
    echo "-------------------------------------------------------------------------"
    echo ""
    echo "👉 Press [Enter] to return or [x] to exit straight to desktop"
    tui_read diagnostic_exit "Enter command: "
    if [[ "$diagnostic_exit" == "x" || "$diagnostic_exit" == "X" ]]; then
        escape_to_desktop
    fi
}

open_packaged_manual() {
    MANUAL="/usr/share/doc/project-anthony/README.txt"
    [ -f "$MANUAL" ] || MANUAL="/usr/share/doc/project-anthony/README"
    if [ "$ON_RESCUE_VT" -eq 1 ] || [ ! -x /usr/local/bin/project-anthony-show-manual ]; then
        page_manual "$MANUAL"
    else
        /usr/local/bin/project-anthony-show-manual || page_manual "$MANUAL"
    fi
}

# After a successful desktop uninstall, close this window. TTY3 teardown
# already chvt's back to the compositor and exits; if we still get here
# on a kernel VT, do the same instead of offering a root shell.
after_uninstall_prompt() {
    echo ""
    echo "✔ Project Anthony has been removed from this system."
    if on_kernel_vt; then
        escape_to_desktop
    fi
    sleep 1
    exit 0
}

confirm_and_uninstall() {
    echo "⚠️  Initiating built-in system uninstallation sequence..."
    tui_read confirm_ui_wipe "Are you absolutely sure you want to delete Project Anthony? [y/n]: "
    if [[ "$confirm_ui_wipe" == "y" || "$confirm_ui_wipe" == "Y" ]]; then
        # Desktop shortcut / Ctrl+Alt+X run as the logged-in user. Teardown
        # needs root; calling it in-process used to `exit 1` and close the TUI.
        if [ "$(id -u)" -ne 0 ]; then
            echo ""
            echo "Administrator privileges are required to uninstall."
            echo ""
            if ! sudo /usr/local/bin/project-anthony --uninstall; then
                echo ""
                echo "❌ Uninstall cancelled or failed. Returning to dashboard..."
                tui_read fakeKey "Press [Enter] to continue..."
                return
            fi
        else
            pa_source uninstall.sh
            execute_system_teardown
        fi
        after_uninstall_prompt
    else
        echo "❌ Action cancelled. Returning to dashboard..."
        sleep 1
    fi
}
