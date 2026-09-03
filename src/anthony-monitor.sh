#!/bin/bash
# =========================================================================
#   PROJECT ANTHONY: LIGHTWEIGHT CRASH WATCHDOG
# =========================================================================
# Polls cheap kernel/session signals.
#
# Real desktop/kernel deaths still switch to TTY3 for the Timeshift prompt.
# Faults in this watchdog (or its own truncated kernel comm) are logged
# instead, and the TUI "System logs" row shows error until they are read.
# =========================================================================

STATE_FILE="/run/project-anthony-state"
CURSOR_FILE="/run/project-anthony-monitor.cursor"
ALERT_FILE="/run/project-anthony-log-alert"
RATE_FILE="/run/project-anthony-log-ratelimit"
LOG_DIR="/var/log/project-anthony"
LOG_FILE="$LOG_DIR/system.log"
POLL_SEC=4
BOOT_GRACE_SEC=45
STARTED_AT="$(date +%s)"
# State/cursor/log files are root-only. The alert flag is world-readable on
# purpose: it is only the token "ERROR", never crash evidence.
umask 077

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

# Kernel faults only. Userspace "segfault at" lines are omitted so a crashing
# app cannot steal the physical console onto the TTY3 TUI.
KERNEL_FAULT_RE='Oops:|kernel panic|BUG: unable to handle|hung_task|soft lockup|hard LOCKUP'

# TASK_COMM_LEN is 15 chars. project-anthony-monitor and -tty both become
# "project-anthony". Never treat those as a reason to hijack the console.
is_our_comm() {
    case "$1" in
        project-anthony*) return 0 ;;
    esac
    return 1
}

# TTY-safe, short evidence block (8 x 76). Control chars stripped.
sanitize_report() {
    tr -cd '\11\12\15\40-\176' \
        | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' \
        | cut -c1-76 \
        | grep -v '^$' \
        | head -n 8
}

# One short record: stamp, kind, a few evidence lines. Not a journal dump.
MAX_LOG_RECORDS=12
MAX_LOG_RECORD_LINES=7
sanitize_log_record() {
    tr -cd '\11\12\15\40-\176' \
        | cut -c1-76 \
        | head -n "$MAX_LOG_RECORD_LINES"
}

cursor_since() {
    cat "$CURSOR_FILE" 2>/dev/null || echo "@0"
}

bump_cursor() {
    date --iso-8601=seconds > "$CURSOR_FILE" 2>/dev/null || true
    chmod 600 "$CURSOR_FILE" 2>/dev/null || true
}

kernel_snippet() {
    journalctl -k -q --since "$(cursor_since)" --no-pager 2>/dev/null || true
}

# Comm: lines, hung_task "task name:pid", soft-lockup "[name:pid]".
fault_comms_from() {
    printf '%s\n' "$1" | sed -n \
        -e 's/.*Comm: \([^[:space:]]*\).*/\1/p' \
        -e 's/.*[[:space:]]task \([^:[:space:]]*\):[0-9][0-9]*.*/\1/p' \
        -e 's/.*\[\([^][:space:]]*\):[0-9][0-9]*\].*/\1/p' \
        | grep -v '^$' | sort -u
}

comms_all_ours() {
    local line any=0
    [ -n "$1" ] || return 1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        any=1
        is_our_comm "$line" || return 1
    done < <(printf '%s\n' "$1")
    [ "$any" -eq 1 ]
}

kernel_has_fault_line() {
    printf '%s\n' "$1" | grep -Eiq "$KERNEL_FAULT_RE"
}

# Foreign (or unattributed) kernel fault: still a rescue-worthy crash.
kernel_fault() {
    local snippet comms
    snippet=$(kernel_snippet)
    kernel_has_fault_line "$snippet" || return 1
    comms=$(fault_comms_from "$snippet")
    if [ -z "$comms" ]; then
        return 0
    fi
    comms_all_ours "$comms" && return 1
    return 0
}

# Attributed kernel fault whose every comm is this program. Log, do not chvt.
kernel_self_fault() {
    local snippet comms
    snippet=$(kernel_snippet)
    kernel_has_fault_line "$snippet" || return 1
    comms=$(fault_comms_from "$snippet")
    comms_all_ours "$comms"
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

# World-readable flag only. Evidence stays in the 0600 log and state file.
raise_alert() {
    printf 'ERROR\n' > "$ALERT_FILE" 2>/dev/null || true
    chmod 644 "$ALERT_FILE" 2>/dev/null || true
}

rate_limit_ok() {
    local now last
    now=$(date +%s)
    last=$(cat "$RATE_FILE" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ $((now - last)) -lt 120 ]; then
        return 1
    fi
    echo "$now" > "$RATE_FILE" 2>/dev/null || true
    chmod 600 "$RATE_FILE" 2>/dev/null || true
    return 0
}

# Keep only the last MAX_LOG_RECORDS blocks (lines starting with ===).
trim_system_log() {
    local n
    [ -f "$LOG_FILE" ] || return 0
    n=$(grep -c '^===' "$LOG_FILE" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    [ "$n" -gt "$MAX_LOG_RECORDS" ] || return 0
    awk -v max="$MAX_LOG_RECORDS" '
        /^=== / { rec++ }
        { buf[rec] = buf[rec] $0 "\n" }
        END {
            start = rec - max + 1
            if (start < 1) start = 1
            for (i = start; i <= rec; i++) printf "%s", buf[i]
        }
    ' "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null || return 0
    mv -f "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

# kind = CRASH (history only; TTY3 is the notification) or
# WATCHDOG/INTERNAL (raise the TUI error flag, rate-limited).
# Never abort the daemon from a log write failure.
log_event() {
    local kind="$1"
    local summary="$2"
    local detail="$3"
    local stamp

    if [ "$kind" != "CRASH" ]; then
        raise_alert
        if ! rate_limit_ok; then
            return 0
        fi
    fi

    mkdir -p "$LOG_DIR" 2>/dev/null || true
    chmod 700 "$LOG_DIR" 2>/dev/null || true

    stamp=$(date --iso-8601=seconds 2>/dev/null || date)
    {
        echo "=== ${stamp} ==="
        echo "${kind}: ${summary}"
        [ -n "$detail" ] && printf '%s\n' "$detail"
        echo ""
    } | sanitize_log_record >> "$LOG_FILE" 2>/dev/null || {
        logger -t project-anthony-monitor "Failed to write $LOG_FILE"
        return 0
    }
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    trim_system_log
}

# Cheap boolean check first; gather details only when we actually trip.
collect_crash_report() {
    CRASH_SUMMARY=""
    CRASH_DETAIL=""
    if kernel_fault; then
        CRASH_SUMMARY="Kernel oops, panic, or hung task"
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

handle_self_fault() {
    local detail
    detail=$(kernel_fault_report)
    [ -z "$detail" ] && detail="No kernel snippet (watchdog internal error)."
    log_event "WATCHDOG" "Fault in Project Anthony itself — TTY3 was not taken." "$detail"
    logger -t project-anthony-monitor "Self-fault logged; not switching to TTY3"
}

record_systemd_restart_if_any() {
    local n
    n=$(systemctl show project-anthony-monitor.service -p NRestarts --value 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    [ "$n" -gt 0 ] || return 0
    log_event "INTERNAL" "Monitor was restarted by systemd (NRestarts=${n}). Console was not taken."
    logger -t project-anthony-monitor "Monitor restarted by systemd (NRestarts=${n}); logged, not switching to TTY3"
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
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    log_event "CRASH" "$CRASH_SUMMARY" "$CRASH_DETAIL"
    logger -t project-anthony-monitor "Crash detected ($CRASH_SUMMARY) — switching to TTY3 Timeshift rescue prompt"
    if [ -n "$CRASH_DETAIL" ]; then
        logger -t project-anthony-monitor "$(printf '%s' "$CRASH_DETAIL" | tr '\n' '|' )"
    fi
    systemctl restart project-anthony-tty.service >/dev/null 2>&1 || true
    chvt 3 2>/dev/null || true
}

# Ignore kernel messages that already existed before this daemon started.
# chmod after write: overwriting an old 644 file keeps its mode.
bump_cursor
[ -f "$STATE_FILE" ] && chmod 600 "$STATE_FILE" 2>/dev/null || true
record_systemd_restart_if_any
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
            bump_cursor
        fi
    elif kernel_self_fault; then
        handle_self_fault
        bump_cursor
    else
        LATCHED=0
    fi
    sleep "$POLL_SEC"
done
