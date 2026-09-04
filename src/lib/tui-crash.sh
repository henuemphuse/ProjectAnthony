# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# Crash-restore screen. The dispatcher calls this after TTY3 unlock
# (or on --crash-prompt) and before the main menu. Panic-y is not enough;
# type YES so a forced compositor kill cannot one-key restore.

# State file (written by anthony-monitor): line 1 = CRASH_TRIGGERED,
# line 2 = one-line summary, remaining lines = short evidence snippet.
STATE_FILE="/run/project-anthony-state"

# Match anthony-monitor.sh: printable ASCII, 8 x 76. Re-apply on read so a
# stale or tampered state file cannot inject control chars into the TTY.
sanitize_crash_text() {
    tr -cd '\11\12\15\40-\176' \
        | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' \
        | cut -c1-76 \
        | grep -v '^$' \
        | head -n 8
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
    echo "Would you like to restore from backup?"
    echo " This snapshot is the last pre-apt rolling point, not a"
    echo " verified clean image. Type YES to restore, or n to skip."
    echo "---------------------------------------------------------"
    echo ""
    tui_read crash_choice "Enter choice [YES/n]: "
    echo ""

    if [[ "$crash_choice" == "YES" || "$crash_choice" == "yes" ]]; then
        echo "🚀 Opening Timeshift restore..."
        SYSTEM_SNAP_ID=$(rolling_snapshot_id || true)
        if [ -n "$SYSTEM_SNAP_ID" ]; then
            run_priv timeshift --restore --snapshot "$SYSTEM_SNAP_ID"
        else
            echo "❌ SYSTEM_LIFERAFT_ROLLING recovery point not found."
            echo "Opening the full Timeshift restore wizard instead..."
            run_priv timeshift --restore
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
