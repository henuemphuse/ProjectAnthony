# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# Public crash screen: names what died and asks whether to open recovery.
# No password here. n returns to the desktop. y continues to TTY3 unlock
# (kernel VT) and then the rescue menu. Timeshift is menu option 3.

# State file (written by anthony-monitor): line 1 = CRASH_TRIGGERED,
# line 2 = one-line summary, remaining lines = short evidence snippet.
# Kept until the user declines (desktop) or unlocks into the rescue
# menu so the watchdog will not restart TTY3.
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

# No idle relock: this screen is shown before unlock, and the kernel
# snippet needs to stay readable. Empty / EOF re-prompts.
crash_notice_read() {
    local dest="$1" prompt="$2"
    IFS= read -r -p "$prompt" "$dest" </dev/tty || true
}

crash_recovery_prompt() {
    local summary="" details="" view_choice=""
    if [ -f "$STATE_FILE" ]; then
        summary=$(sed -n '2p' "$STATE_FILE" 2>/dev/null | sanitize_crash_text | head -n 1)
        details=$(tail -n +3 "$STATE_FILE" 2>/dev/null | sanitize_crash_text)
        # Leave STATE_FILE in place until this prompt is finished. The
        # watchdog treats that file as "TTY3 is already on a crash
        # screen" and must not restart the TUI with a second message.
    fi
    if [ -z "$summary" ]; then
        if [ "$1" = "--crash-prompt" ]; then
            summary="Test crash prompt (no live watchdog event)"
        else
            summary="a system crash"
        fi
    fi

    while true; do
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
        echo "Would you like to view recovery options?"
        echo " y  unlock and open the rescue menu."
        echo " n  return to the desktop."
        echo "---------------------------------------------------------"
        echo ""
        view_choice=""
        crash_notice_read view_choice "Enter choice [y/n]: "
        echo ""

        case "$view_choice" in
            y|Y|yes|YES)
                return 0
                ;;
            n|N|no|NO)
                rm -f "$STATE_FILE"
                escape_to_desktop
                exit 0
                ;;
            *)
                echo " Type y to view recovery options, or n to return to the desktop."
                sleep 1
                ;;
        esac
    done
}
