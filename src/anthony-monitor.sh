#!/bin/bash
# =========================================================================
#   PROJECT ANTHONY: LIGHTWEIGHT CRASH WATCHDOG
# =========================================================================
# Polls cheap kernel/session signals.
#
# Real desktop/kernel deaths still switch to TTY3 for the Timeshift prompt.
# Recoverable hangs are re-checked across several polls so a brief stall
# can clear before the console is taken. Sleep/wake thaw is given a grace
# period so opening the lid does not look like a crash. Faults in this
# watchdog (or its own truncated kernel comm) are logged instead, and the
# TUI "System logs" row shows error until they are read.
# =========================================================================

STATE_FILE="/run/project-anthony-state"
CURSOR_FILE="/run/project-anthony-monitor.cursor"
ALERT_FILE="/run/project-anthony-log-alert"
RATE_FILE="/run/project-anthony-log-ratelimit"
LOG_DIR="/var/log/project-anthony"
LOG_FILE="$LOG_DIR/system.log"
POLL_SEC=2
BOOT_GRACE_SEC=20
# Freeze/thaw looks like hung_task/soft lockup and can stall the compositor
# while the GPU comes back. Ignore crashes for this long after a resume.
RESUME_GRACE_SEC=15
# Wall-clock jump larger than this means we were frozen (sleep), not a slow poll.
RESUME_GAP_SEC=10
LAST_POLL_AT="$(date +%s)"
RESUME_GRACE_UNTIL=0
WAS_ASLEEP=0
# Recoverable faults (hung task, soft lockup, dead compositor, failed
# display-manager) must stay true across CONFIRM_POLLS (~6s) so a brief
# stall can clear. A one-shot hung_task/soft-lockup journal line is held
# for SOFT_HOLD_POLLS (~20s) so a second kernel warning can arrive.
# Oops, panic, BUG, and hard LOCKUP still trip on the first hit.
CONFIRM_POLLS=3
SOFT_HOLD_POLLS=10
HOLD_STREAK=0
HOLD_SOFT=0
SOFT_SEEN=""
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

# Ask PID 1 only. logind can already be gone, and a D-Bus wait during
# teardown is how a watchdog delays reboot.
system_shutting_down() {
    local state
    state=$(systemctl is-system-running 2>/dev/null || true)
    [ "$state" = "stopping" ] && return 0
    systemctl is-active --quiet shutdown.target 2>/dev/null
}

# sleep.target covers suspend/hibernate/hybrid-sleep. Check the specific
# targets too in case we poll mid-transition before sleep.target is up.
system_asleep_or_suspending() {
    systemctl is-active --quiet sleep.target 2>/dev/null \
        || systemctl is-active --quiet suspend.target 2>/dev/null \
        || systemctl is-active --quiet hibernate.target 2>/dev/null \
        || systemctl is-active --quiet hybrid-sleep.target 2>/dev/null \
        || systemctl is-active --quiet suspend-then-hibernate.target 2>/dev/null
}

# Snapshot: compositor gone under a still-registered graphical login.
# Re-check shutdown after probing; reboot can start mid-poll.
compositor_looks_dead() {
    system_shutting_down && return 1
    systemctl is-active --quiet display-manager 2>/dev/null || return 1
    user_graphical_session || return 1
    wm_running && return 1
    system_shutting_down && return 1
    return 0
}

hold_reset() {
    HOLD_STREAK=0
    HOLD_SOFT=0
    SOFT_SEEN=""
}

hold_recover() {
    if [ "$HOLD_SOFT" -eq 1 ]; then
        bump_cursor
        logger -t project-anthony-monitor \
            "Recoverable hang cleared before confirmation; TTY3 not taken"
    fi
    hold_reset
}

enter_resume_grace() {
    local now
    now=$(date +%s)
    if [ "$now" -ge "$RESUME_GRACE_UNTIL" ]; then
        logger -t project-anthony-monitor \
            "Resume/sleep thaw detected; ${RESUME_GRACE_SEC}s grace, TTY3 not taken"
    fi
    RESUME_GRACE_UNTIL=$((now + RESUME_GRACE_SEC))
    hold_reset
    bump_cursor
}

# Kernel faults only. Userspace "segfault at" lines are omitted so a crashing
# app cannot steal the physical console onto the TTY3 TUI.
# Hard faults do not self-heal. Soft faults can be a one-shot warning.
KERNEL_HARD_RE='Oops:|kernel panic|BUG: unable to handle|hard LOCKUP'
KERNEL_SOFT_RE='hung_task|soft lockup'
KERNEL_FAULT_RE="$KERNEL_HARD_RE|$KERNEL_SOFT_RE"

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
    journalctl -k -q --since "$(cursor_since)" --no-pager -n 200 2>/dev/null || true
}

# Comm: lines, hung_task "task name:pid", soft-lockup "[name:pid]".
fault_comms_from() {
    printf '%s\n' "$1" | sed -n \
        -e 's/.*Comm: \([^[:space:]]*\).*/\1/p' \
        -e 's/.*[[:space:]]task \([^:[:space:]]*\):[0-9][0-9]*.*/\1/p' \
        -e 's/.*\[\([^][:space:]]*\):[0-9][0-9]*\].*/\1/p' \
        | grep -v '^$' | sort -u
}

fault_pids_from() {
    printf '%s\n' "$1" | sed -n \
        -e 's/.*[[:space:]]task [^:[:space:]]*:\([0-9][0-9]*\).*/\1/p' \
        -e 's/.*\[[^][:space:]]*:\([0-9][0-9]*\)\].*/\1/p' \
        | grep -E '^[0-9]+$' | sort -u
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

kernel_has_line() {
    printf '%s\n' "$1" | grep -Eiq "$2"
}

kernel_has_fault_line() {
    kernel_has_line "$1" "$KERNEL_FAULT_RE"
}

# Foreign (or unattributed) kernel fault matching the given regex.
kernel_fault_matching() {
    local re="$1"
    local snippet comms
    snippet=$(kernel_snippet)
    kernel_has_line "$snippet" "$re" || return 1
    comms=$(fault_comms_from "$snippet")
    if [ -z "$comms" ]; then
        return 0
    fi
    comms_all_ours "$comms" && return 1
    return 0
}

kernel_hard_fault() {
    kernel_fault_matching "$KERNEL_HARD_RE"
}

kernel_soft_fault() {
    kernel_fault_matching "$KERNEL_SOFT_RE"
}

# Foreign (or unattributed) kernel fault: still a rescue-worthy crash.
kernel_fault() {
    kernel_hard_fault || kernel_soft_fault
}

# Attributed kernel fault whose every comm is this program. Log, do not chvt.
kernel_self_fault() {
    local snippet comms
    snippet=$(kernel_snippet)
    kernel_has_fault_line "$snippet" || return 1
    comms=$(fault_comms_from "$snippet")
    comms_all_ours "$comms"
}

# hung_task PIDs still in uninterruptible sleep (D). A task that woke up
# is treated as recovered even though the original journal line remains.
soft_pids_stuck() {
    local snippet pids pid state
    snippet=$(kernel_snippet)
    kernel_has_line "$snippet" "$KERNEL_SOFT_RE" || return 1
    pids=$(fault_pids_from "$snippet")
    [ -n "$pids" ] || return 1
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        [ -d "/proc/$pid" ] || continue
        state=$(awk '/^State:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null) || continue
        [ "$state" = "D" ] && return 0
    done < <(printf '%s\n' "$pids")
    return 1
}

# Extra hung_task/soft-lockup lines beyond the ones that opened the hold.
soft_kernel_new_lines() {
    local snippet current extra
    [ -n "$SOFT_SEEN" ] || return 1
    snippet=$(kernel_snippet)
    current=$(printf '%s\n' "$snippet" | grep -Ei "$KERNEL_SOFT_RE" || true)
    extra=$(printf '%s\n' "$current" \
        | grep -Fxv -f <(printf '%s\n' "$SOFT_SEEN") \
        | grep -v '^$' || true)
    [ -n "$extra" ]
}

# Live recoverable condition. A stale hung_task journal line is not enough
# once SOFT_SEEN is set: the PID must still be in D, or a new line must
# have arrived, or the desktop itself must still be down.
recoverable_fault_now() {
    display_manager_failed && return 0
    compositor_looks_dead && return 0
    soft_pids_stuck && return 0
    if [ -n "$SOFT_SEEN" ]; then
        soft_kernel_new_lines && return 0
    else
        kernel_soft_fault && return 0
    fi
    return 1
}

display_manager_failed() {
    systemctl is-failed --quiet display-manager 2>/dev/null
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
    if compositor_looks_dead; then
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
    # Never start or restart units after systemd has begun shutting down.
    system_shutting_down && return 0
    if [ -f "$STATE_FILE" ]; then
        chvt 3 2>/dev/null || true
        return 0
    fi
    collect_crash_report || true
    system_shutting_down && return 0
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
    system_shutting_down && return 0
    systemctl restart project-anthony-tty.service >/dev/null 2>&1 || true
    system_shutting_down && return 0
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

    if system_shutting_down; then
        hold_reset
        LAST_POLL_AT=$now
        sleep "$POLL_SEC"
        continue
    fi

    if system_asleep_or_suspending; then
        WAS_ASLEEP=1
        hold_reset
        LAST_POLL_AT=$now
        sleep "$POLL_SEC"
        continue
    fi

    if [ "$WAS_ASLEEP" -eq 1 ] \
        || { [ "$LAST_POLL_AT" -gt 0 ] && [ $((now - LAST_POLL_AT)) -gt "$RESUME_GAP_SEC" ]; }; then
        enter_resume_grace
    fi
    WAS_ASLEEP=0
    LAST_POLL_AT=$now

    if [ "$now" -lt "$RESUME_GRACE_UNTIL" ]; then
        hold_reset
        bump_cursor
        sleep "$POLL_SEC"
        continue
    fi

    if [ $((now - STARTED_AT)) -lt "$BOOT_GRACE_SEC" ]; then
        sleep "$POLL_SEC"
        continue
    fi

    if kernel_hard_fault; then
        if [ "$LATCHED" -eq 0 ]; then
            trigger_rescue
            LATCHED=1
            hold_reset
            bump_cursor
        fi
    elif recoverable_fault_now; then
        if [ "$LATCHED" -eq 0 ]; then
            if [ "$HOLD_STREAK" -eq 0 ]; then
                if kernel_soft_fault; then
                    HOLD_SOFT=1
                    SOFT_SEEN=$(printf '%s\n' "$(kernel_snippet)" \
                        | grep -Ei "$KERNEL_SOFT_RE" || true)
                fi
            fi
            HOLD_STREAK=$((HOLD_STREAK + 1))
            if [ "$HOLD_STREAK" -ge "$CONFIRM_POLLS" ]; then
                trigger_rescue
                LATCHED=1
                hold_reset
                bump_cursor
            fi
        fi
    elif [ "$LATCHED" -eq 0 ] && [ "$HOLD_STREAK" -gt 0 ]; then
        # Quiet poll inside a confirmation window: keep holding a
        # hung_task/soft-lockup warning until SOFT_HOLD_POLLS so a
        # second kernel line can arrive; compositor/DM recover immediately.
        if [ "$HOLD_SOFT" -eq 1 ] && [ "$HOLD_STREAK" -lt "$SOFT_HOLD_POLLS" ]; then
            HOLD_STREAK=$((HOLD_STREAK + 1))
            if [ "$HOLD_STREAK" -ge "$SOFT_HOLD_POLLS" ]; then
                hold_recover
            fi
        else
            hold_recover
        fi
    elif kernel_self_fault; then
        handle_self_fault
        hold_reset
        bump_cursor
    else
        LATCHED=0
    fi
    sleep "$POLL_SEC"
done
