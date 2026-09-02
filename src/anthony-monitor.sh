#!/bin/bash
# =========================================================================
#   PROJECT ANTHONY: LIGHTWEIGHT CRASH WATCHDOG
# =========================================================================
# Polls cheap kernel/session signals. On a new crash, switches to TTY3
# and lets getty launch the rescue TUI at the Timeshift restore prompt.
# =========================================================================

STATE_FILE="/run/project-anthony-state"
CURSOR_FILE="/run/project-anthony-monitor.cursor"
POLL_SEC=4
BOOT_GRACE_SEC=45
STARTED_AT="$(date +%s)"

wm_running() {
    pgrep -x cinnamon >/dev/null \
        || pgrep -x cinnamon-session >/dev/null \
        || pgrep -x gnome-shell >/dev/null \
        || pgrep -x mutter >/dev/null \
        || pgrep -x marco >/dev/null \
        || pgrep -x xfwm4 >/dev/null \
        || pgrep -x kwin_x11 >/dev/null \
        || pgrep -x kwin_wayland >/dev/null
}

user_graphical_session() {
    local sid type state class
    while read -r sid _ _; do
        [ -z "$sid" ] && continue
        type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
        state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
        class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null)
        if { [ "$type" = "x11" ] || [ "$type" = "wayland" ]; } \
            && { [ "$state" = "active" ] || [ "$state" = "online" ]; } \
            && [ "$class" = "user" ]; then
            return 0
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    return 1
}

# Compositor died under a still-registered graphical login (not the greeter).
compositor_dead() {
    systemctl is-active --quiet display-manager 2>/dev/null || return 1
    user_graphical_session || return 1
    wm_running && return 1
    return 0
}

KERNEL_FAULT_RE='Oops:|kernel panic|BUG: |hung_task|soft lockup|hard LOCKUP|segfault at'

# TTY-safe, short evidence block (8 x 76). Control chars stripped.
sanitize_report() {
    tr -cd '\11\12\15\40-\176' \
        | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' \
        | cut -c1-76 \
        | grep -v '^$' \
        | head -n 8
}

cursor_since() {
    cat "$CURSOR_FILE" 2>/dev/null || echo "@0"
}

kernel_fault() {
    journalctl -k -q --since "$(cursor_since)" --no-pager 2>/dev/null \
        | grep -Ei "$KERNEL_FAULT_RE" \
        | grep -q .
}

display_manager_failed() {
    systemctl is-failed --quiet display-manager 2>/dev/null
}

crash_detected() {
    kernel_fault || display_manager_failed || compositor_dead
}

kernel_fault_report() {
    journalctl -k -q --since "$(cursor_since)" --no-pager -n 80 2>/dev/null \
        | grep -Ei "$KERNEL_FAULT_RE|RIP:|Comm:|INFO: task .* blocked" \
        | sanitize_report
}

display_manager_report() {
    local unit result
    unit=$(systemctl show display-manager -p Id --value 2>/dev/null)
    result=$(systemctl show display-manager -p Result --value 2>/dev/null)
    echo "${unit:-display-manager} failed (result=${result:-unknown})"
    journalctl -u "${unit:-display-manager}" -q --no-pager -p err -n 12 \
        --since "$(cursor_since)" 2>/dev/null | sanitize_report
}

compositor_dead_report() {
    {
        echo "Graphical login is still registered, but no compositor is running."
        while read -r sid _ _; do
            [ -z "$sid" ] && continue
            type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
            state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
            class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null)
            name=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
            if { [ "$type" = "x11" ] || [ "$type" = "wayland" ]; } \
                && { [ "$state" = "active" ] || [ "$state" = "online" ]; } \
                && [ "$class" = "user" ]; then
                echo "Session $sid ($name, $type, $state) has no cinnamon/gnome-shell/kwin process."
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null)
    } | sanitize_report
}

# Cheap boolean check first; gather details only when we actually trip.
collect_crash_report() {
    CRASH_SUMMARY=""
    CRASH_DETAIL=""
    if kernel_fault; then
        CRASH_SUMMARY="Kernel oops, panic, hung task, or segfault"
        CRASH_DETAIL=$(kernel_fault_report)
        return 0
    fi
    if display_manager_failed; then
        CRASH_SUMMARY="Display manager failed"
        CRASH_DETAIL=$(display_manager_report)
        return 0
    fi
    if compositor_dead; then
        CRASH_SUMMARY="Desktop compositor died"
        CRASH_DETAIL=$(compositor_dead_report)
        return 0
    fi
    return 1
}

trigger_rescue() {
    if [ -f "$STATE_FILE" ]; then
        chvt 3 2>/dev/null || true
        return 0
    fi
    collect_crash_report || true
    [ -z "$CRASH_SUMMARY" ] && CRASH_SUMMARY="a system crash"
    {
        echo "CRASH_TRIGGERED"
        echo "$CRASH_SUMMARY"
        printf '%s\n' "$CRASH_DETAIL"
    } > "$STATE_FILE"
    chmod 644 "$STATE_FILE" 2>/dev/null || true
    logger -t project-anthony-monitor "Crash detected ($CRASH_SUMMARY) — switching to TTY3 Timeshift rescue prompt"
    if [ -n "$CRASH_DETAIL" ]; then
        logger -t project-anthony-monitor "$(printf '%s' "$CRASH_DETAIL" | tr '\n' '|' )"
    fi
    systemctl restart project-anthony-tty.service >/dev/null 2>&1 || true
    chvt 3 2>/dev/null || true
}

# Ignore kernel messages that already existed before this daemon started.
date --iso-8601=seconds > "$CURSOR_FILE"
LATCHED=0

while true; do
    now=$(date +%s)
    if [ $((now - STARTED_AT)) -lt "$BOOT_GRACE_SEC" ]; then
        sleep "$POLL_SEC"
        continue
    fi

    if crash_detected; then
        if [ "$LATCHED" -eq 0 ]; then
            trigger_rescue
            LATCHED=1
            date --iso-8601=seconds > "$CURSOR_FILE"
        fi
    else
        LATCHED=0
    fi
    sleep "$POLL_SEC"
done
