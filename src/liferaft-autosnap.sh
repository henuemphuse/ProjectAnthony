#!/bin/bash

# =========================================================================
#   PROJECT ANTHONY: BACKGROUND SNAPSHOT MANAGER (AUTOMATED HOOK)
# =========================================================================
# Description: Acts as an automated background cleanup and creation shield.
#              Force-closes any existing Timeshift instances to clear process
#              locks before executing a single-slot rolling snapshot pass.
#
#              --rsync is only passed when Timeshift has no existing setup.
#              Passing it against a live config switches the saved backend
#              (btrfs → rsync), so configured machines must use --create
#              with no mode flag and let Timeshift load timeshift.json.
# =========================================================================

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

# Fail-safe condition check: Exit immediately if Timeshift was manually removed
if ! command -v timeshift >/dev/null; then
    exit 0
fi

# 🚨 PROCESS UNLOCK ENGINE
# Check if an instance of Timeshift is already running or hanging in the background
if pgrep -x "timeshift" >/dev/null || pgrep -x "timeshift-gtk" >/dev/null; then
    echo "⚠️  Project Anthony: Existing Timeshift process lock detected! Clearing runtime space..."
    # Forcefully terminate all running instances to free up the system database lock
    sudo killall -9 timeshift 2>/dev/null
    sudo killall -9 timeshift-gtk 2>/dev/null
    # Wipe the temporary system layout lock files left behind on the drive partition
    sudo rm -f /var/run/timeshift.lock
    sudo rm -rf /run/timeshift/app/
    sleep 1
fi

echo "🚀 Project Anthony: Scanning for old rolling snapshots..."

# Quietly query the system backends for an existing automated signature id string
OLD_SNAPSHOT_ID=$(timeshift --list 2>/dev/null | grep "SYSTEM_LIFERAFT_ROLLING" | awk '{print $3}')
[[ "$OLD_SNAPSHOT_ID" =~ ^[0-9A-Za-z._-]+$ ]] || OLD_SNAPSHOT_ID=""

# Redundancy First-Run Safeguard: Only execute the delete loop if an old id actually exists
if [ ! -z "$OLD_SNAPSHOT_ID" ]; then
    echo "🗑️ Project Anthony: Purging previous backup ($OLD_SNAPSHOT_ID) to protect storage capacity..."
    timeshift --delete --snapshot "$OLD_SNAPSHOT_ID" --yes
else
    echo "✔ No old rolling snapshots found. Proceeding with clean disk configuration layout..."
fi

echo "📸 Project Anthony: Generating fresh pre-update rolling snapshot..."

# Commit the fresh system state restore point with your distinct string tag signature
if timeshift_is_configured; then
    timeshift --create --comments "SYSTEM_LIFERAFT_ROLLING" --tags O
else
    timeshift --create --rsync --comments "SYSTEM_LIFERAFT_ROLLING" --tags O
fi
