#!/bin/bash

# =========================================================================
#   PROJECT ANTHONY: BACKGROUND SNAPSHOT MANAGER (AUTOMATED HOOK)
# =========================================================================
# Description: Acts as an automated background cleanup and creation shield.
#              Force-closes any existing Timeshift instances to clear process
#              locks before executing a single-slot rolling snapshot pass.
#
#              APT must call this from DPkg::Pre-Invoke (not Pre-Install-Pkgs).
#              Pre-Install-Pkgs feeds .deb paths on stdin; Timeshift then
#              treats them as y/n answers and the snapshot is skipped.
#              mintUpdate/aptkit also skip Pre-Install-Pkgs.
#
#              --rsync is only passed when Timeshift has no existing setup.
#              Passing it against a live config switches the saved backend
#              (btrfs → rsync), so configured machines must use --create
#              with no mode flag and let Timeshift load timeshift.json.
# =========================================================================

LOG_DIR="/var/log/project-anthony"
LOG_FILE="${LOG_DIR}/autosnap.log"

autosnap_log_setup() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
        touch "$LOG_FILE" 2>/dev/null || true
        chmod 640 "$LOG_FILE" 2>/dev/null || true
        echo "=== $(date -Is 2>/dev/null || date) pid=$$ ===" >> "$LOG_FILE"
        if command -v tee >/dev/null; then
            exec > >(tee -a "$LOG_FILE") 2>&1
        else
            exec >>"$LOG_FILE" 2>&1
        fi
    fi
}

# APT Pre-Install-Pkgs (legacy) sends package filenames on stdin. Never let
# Timeshift read that stream as confirmation answers.
detach_apt_stdin() {
    if [ ! -t 0 ]; then
        cat >/dev/null 2>/dev/null || true
        exec </dev/null
    fi
}

timeshift_config_file() {
    if [ -f /etc/timeshift/timeshift.json ]; then
        echo /etc/timeshift/timeshift.json
    elif [ -f /etc/timeshift.json ]; then
        echo /etc/timeshift.json
    fi
}

timeshift_json_value() {
    local cfg="$1" key="$2"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$cfg" 2>/dev/null \
        | head -1 | cut -d'"' -f4
}

# True when the user (or a previous wizard/snapshot) already picked a backend.
timeshift_is_configured() {
    local cfg uuid first mode
    cfg=$(timeshift_config_file)
    if [ -n "$cfg" ]; then
        uuid=$(timeshift_json_value "$cfg" backup_device_uuid)
        first=$(timeshift_json_value "$cfg" do_first_run)
        mode=$(timeshift_json_value "$cfg" btrfs_mode)
        [ -n "$uuid" ] && return 0
        [ "$mode" = "true" ] && return 0
        [ "$first" = "false" ] && return 0
    fi
    ls /timeshift/snapshots/*/info.json >/dev/null 2>&1 && return 0
    ls /timeshift/snapshots-ondemand/*/info.json >/dev/null 2>&1 && return 0
    ls /timeshift-btrfs/snapshots/*/info.json >/dev/null 2>&1 && return 0
    return 1
}

# postinst / install.sh: initialize rsync only on a blank Timeshift.
bootstrap_timeshift_if_needed() {
    if ! command -v timeshift >/dev/null; then
        return 0
    fi
    if timeshift_is_configured; then
        echo "✔ Timeshift is already configured. Leaving existing backend unchanged."
        return 0
    fi
    echo "🔄 Timeshift has not been set up. Initializing an rsync backend..."
    timeshift --check --rsync --yes --scripted 2>/dev/null || true
}

if [ "${1:-}" = "--bootstrap" ]; then
    bootstrap_timeshift_if_needed
    exit 0
fi

# mintUpdate / apt can set this to skip a one-shot snapshot.
if [ -n "${SKIP_AUTOSNAP:-}" ]; then
    exit 0
fi

autosnap_log_setup
detach_apt_stdin

# Fail-safe condition check: Exit immediately if Timeshift was manually removed
if ! command -v timeshift >/dev/null; then
    echo "⚠️  Timeshift is not installed. Skipping rolling snapshot."
    exit 0
fi

# Never SIGKILL a live restore. Unattended-upgrades would otherwise abort
# an administrator's Timeshift rollback and snapshot a half-restored tree.
timeshift_restore_in_progress() {
    local pid cmd
    for pid in $(pgrep -x timeshift 2>/dev/null) $(pgrep -x timeshift-gtk 2>/dev/null); do
        [ -n "$pid" ] || continue
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *'--restore'*) return 0 ;;
        esac
    done
    return 1
}

if timeshift_restore_in_progress; then
    echo "⚠️  Timeshift restore is running. Skipping rolling snapshot so the restore is not killed."
    exit 0
fi

# 🚨 PROCESS UNLOCK ENGINE
# Check if an instance of Timeshift is already running or hanging in the background
if pgrep -x "timeshift" >/dev/null || pgrep -x "timeshift-gtk" >/dev/null; then
    echo "⚠️  Project Anthony: Existing Timeshift process lock detected! Clearing runtime space..."
    if [ "$(id -u)" -eq 0 ]; then
        killall -9 timeshift timeshift-gtk 2>/dev/null || true
        rm -f /var/run/timeshift.lock
        rm -rf /run/timeshift/app/
    else
        sudo killall -9 timeshift 2>/dev/null || true
        sudo killall -9 timeshift-gtk 2>/dev/null || true
        sudo rm -f /var/run/timeshift.lock
        sudo rm -rf /run/timeshift/app/
    fi
    sleep 1
fi

echo "🚀 Project Anthony: Scanning for old rolling snapshots..."

# Quietly query the system backends for an existing automated signature id string
OLD_SNAPSHOT_ID=$(timeshift --list --scripted 2>/dev/null | grep "SYSTEM_LIFERAFT_ROLLING" | awk '{print $3}' | tail -n1)
[[ "$OLD_SNAPSHOT_ID" =~ ^[0-9A-Za-z._-]+$ ]] || OLD_SNAPSHOT_ID=""

echo "📸 Project Anthony: Generating fresh pre-update rolling snapshot..."

# Create first, then drop the previous rolling slot. Deleting first left a
# window with no recovery point if --create failed (disk full, Timeshift error).
# --yes --scripted is required: without it Timeshift waits on a TTY and APT
# frontends (mintUpdate) skip or abort the snapshot.
if timeshift_is_configured; then
    if ! timeshift --create --comments "SYSTEM_LIFERAFT_ROLLING" --tags O --yes --scripted; then
        echo "❌ Rolling snapshot failed. Keeping the previous slot. APT will continue."
        exit 0
    fi
else
    if ! timeshift --create --rsync --comments "SYSTEM_LIFERAFT_ROLLING" --tags O --yes --scripted; then
        echo "❌ Rolling snapshot failed. Keeping the previous slot. APT will continue."
        exit 0
    fi
fi

if [ -n "$OLD_SNAPSHOT_ID" ]; then
    NEW_SNAPSHOT_ID=$(timeshift --list --scripted 2>/dev/null | grep "SYSTEM_LIFERAFT_ROLLING" | awk '{print $3}' | tail -n1)
    [[ "$NEW_SNAPSHOT_ID" =~ ^[0-9A-Za-z._-]+$ ]] || NEW_SNAPSHOT_ID=""
    if [ -n "$NEW_SNAPSHOT_ID" ] && [ "$NEW_SNAPSHOT_ID" != "$OLD_SNAPSHOT_ID" ]; then
        echo "🗑️ Project Anthony: Purging previous backup ($OLD_SNAPSHOT_ID) to protect storage capacity..."
        timeshift --delete --snapshot "$OLD_SNAPSHOT_ID" --yes --scripted || true
    fi
fi

echo "✔ Rolling snapshot SYSTEM_LIFERAFT_ROLLING is ready."
exit 0
