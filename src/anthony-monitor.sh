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

kernel_fault() {
    local since
    since=$(cat "$CURSOR_FILE" 2>/dev/null || echo "@0")
    journalctl -k -q --since "$since" 2>/dev/null \
        | grep -Ei 'Oops:|kernel panic|BUG: |hung_task|soft lockup|hard LOCKUP|segfault at' \
        | grep -q .
}

display_manager_failed() {
    systemctl is-failed --quiet display-manager 2>/dev/null
}

crash_detected() {
    kernel_fault || display_manager_failed || compositor_dead
}

trigger_rescue() {
    if [ -f "$STATE_FILE" ]; then
        chvt 3 2>/dev/null || true
        return 0
    fi
    echo "CRASH_TRIGGERED" > "$STATE_FILE"
    chmod 644 "$STATE_FILE" 2>/dev/null || true
    logger -t project-anthony-monitor "Crash detected — switching to TTY3 Timeshift rescue prompt"
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
