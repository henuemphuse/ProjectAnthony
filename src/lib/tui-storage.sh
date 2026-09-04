# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# Main TUI option 2: storage matrix (SMART map) and ddrescue clone.
# Disk names and clone destinations stay validated here.

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

is_skippable_fstype() {
    case "$1" in
        ""|swap|crypto_LUKS|LVM2_member|linux_raid_member)
            return 0
            ;;
    esac
    return 1
}

part_mountpoint() {
    lsblk -nrpo MOUNTPOINT "$1" 2>/dev/null | awk 'NF { print; exit }'
}

# Largest mounted filesystem free space on this disk, or Unmounted.
disk_free_space() {
    local disk="$1" part mp k free best="Unmounted" best_k=-1 has_part=0
    while read -r part; do
        [ -n "$part" ] || continue
        has_part=1
        mp=$(part_mountpoint "/dev/$part")
        [ -n "$mp" ] || continue
        k=$(df -Pk "$mp" 2>/dev/null | awk 'NR==2 { print $4 }')
        [[ "$k" =~ ^[0-9]+$ ]] || continue
        if [ "$k" -gt "$best_k" ]; then
            best_k=$k
            free=$(df -h "$mp" 2>/dev/null | awk 'NR==2 { print $4 }')
            best="${free:---}"
        fi
    done < <(lsblk -nrno NAME,TYPE "/dev/$disk" 2>/dev/null | awk '$2=="part" { print $1 }')
    if [ "$has_part" -eq 0 ]; then
        printf '%s\n' "--"
    else
        printf '%s\n' "$best"
    fi
}

# Unmounted partitions that can be mounted (not swap/LUKS/LVM).
list_unmounted_parts() {
    local disk="$1" part fstype size
    while read -r part; do
        [ -n "$part" ] || continue
        fstype=$(lsblk -nrno FSTYPE "/dev/$part" 2>/dev/null | awk 'NF { print; exit }')
        is_skippable_fstype "$fstype" && continue
        [ -z "$(part_mountpoint "/dev/$part")" ] || continue
        size=$(lsblk -nrno SIZE "/dev/$part" 2>/dev/null | awk 'NF { print; exit }')
        printf '%s %s %s\n' "$part" "$fstype" "$size"
    done < <(lsblk -nrno NAME,TYPE "/dev/$disk" 2>/dev/null | awk '$2=="part" { print $1 }')
}

try_mount_partition() {
    local dev="$1" name mp
    name=$(basename "$dev")
    if command -v udisksctl >/dev/null; then
        if udisksctl mount -b "$dev"; then
            return 0
        fi
    fi
    mp="/mnt/project-anthony/${name}"
    run_priv mkdir -p "$mp" || return 1
    run_priv mount -o nosuid,nodev "$dev" "$mp"
}

mount_unmounted_volumes() {
    local disk="$1" part fstype size mp
    echo ""
    echo "📂 Unmounted volumes on /dev/${disk}:"
    while read -r part fstype size; do
        printf '   %-12s  %-8s  %s\n' "/dev/$part" "$fstype" "$size"
    done < <(list_unmounted_parts "$disk")
    echo ""
    tui_read mount_now "Mount them now so free space can be measured? [y/n]: "
    if [[ "$mount_now" != "y" && "$mount_now" != "Y" ]]; then
        return 1
    fi
    echo ""
    while read -r part fstype size; do
        echo "⚓ Mounting /dev/${part} (${fstype})..."
        if try_mount_partition "/dev/$part"; then
            mp=$(part_mountpoint "/dev/$part")
            echo "✔ Mounted /dev/${part}${mp:+ at $mp}"
        else
            echo "❌ Could not mount /dev/${part}."
        fi
    done < <(list_unmounted_parts "$disk")
    echo ""
    tui_read fakeKey "Press [Enter] to refresh the volume list..."
    return 0
}

draw_storage_matrix() {
    echo "💾 Project Anthony: Enhanced Capacity & Storage Matrix"
    echo "========================================================================="
    printf "%-12s | %-20s | %-8s | %-10s | %-12s\n" "DEVICE" "MODEL / NAME" "TOTAL" "FREE" "SMART HEALTH"
    echo "------------------------------------------------------------------------="

    if ! command -v smartctl &>/dev/null; then
        echo "⚠️  smartctl is not installed. SMART health will show as unknown."
        echo "    Install smartmontools from a normal session if you need it."
    fi

    for disk in $(lsblk -dno NAME,TYPE | grep "disk" | awk '{print $1}'); do
        MODEL=$(lsblk -dno MODEL "/dev/$disk" | sed 's/^[ \t]*//;s/[ \t]*$//')
        [ -z "$MODEL" ] && MODEL="Generic Disk"
        SIZE=$(lsblk -dno SIZE "/dev/$disk" | sed 's/^[ \t]*//;s/[ \t]*$//')
        FREE_SPACE=$(disk_free_space "$disk")

        SMART_RAW=$(run_priv smartctl -H "/dev/$disk" 2>/dev/null)
        if echo "$SMART_RAW" | grep -q "PASSED"; then HEALTH="🟢 PASSED"
        elif echo "$SMART_RAW" | grep -q "FAILED"; then HEALTH="🔴 FAILED!"
        elif echo "$SMART_RAW" | grep -q "OK"; then HEALTH="🟢 OK"
        else HEALTH="⚪ UNKNOWN"; fi

        printf "%-12s | %-20.20s | %-8s | %-10s | %-12s\n" "/dev/$disk" "$MODEL" "$SIZE" "$FREE_SPACE" "$HEALTH"
    done
    echo "========================================================================="
    echo "👉 Select a drive to image. Unmounted volumes can be mounted first."
    echo "   [Enter] return to menu    [x] exit to desktop"
    echo ""
}

clone_selected_drive() {
    local drive_choice="$1"
    local SRC_PATH SRC_SIZE_BYTES SRC_SIZE_GB dest_choice DEST_PATH
    local DEST_SIZE_BYTES DEST_SIZE_GB force_choice final_lock RESCUE_LOG

    SRC_PATH="/dev/$drive_choice"
    SRC_SIZE_BYTES=$(blockdev --getsize64 "$SRC_PATH")
    SRC_SIZE_GB=$(echo "scale=2; $SRC_SIZE_BYTES / 1024 / 1024 / 1024" | bc)

    tui_read dest_choice "Enter DESTINATION drive or path (or [x] to exit straight to desktop): "
    if [ "$dest_choice" == "x" ] || [ "$dest_choice" == "X" ]; then escape_to_desktop; return; fi
    if [ -z "$dest_choice" ]; then return; fi

    if [[ "$dest_choice" == *"$drive_choice"* ]]; then
        echo "⛔ CRITICAL ERROR: Destination cannot match or reside on source hardware!"
        tui_read fakeKey "Press [Enter] key to continue..."
        return
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
            if [[ "$force_choice" != "y" && "$force_choice" != "Y" ]]; then return; fi
        fi
    elif allowed_clone_dir "$dest_choice"; then
        DEST_PATH="$dest_choice/${drive_choice}_backup.img"
    else
        echo "❌ Error: Destination must be another disk (e.g. sdb) or a folder"
        echo "   under /mnt, /media, /root, or /home."
        tui_read fakeKey "Press [Enter] key to continue..."
        return
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
        run_priv ddrescue -v -b 4096 "$SRC_PATH" "$DEST_PATH" "$RESCUE_LOG"
        echo "✔ Sector streaming complete."
    else
        echo "❌ Migration execution cancelled."
    fi
    tui_read fakeKey "Press [Enter] key to continue..."
}

storage_matrix_menu() {
    local drive_choice
    while true; do
        clear
        draw_storage_matrix
        tui_read drive_choice "Select drive to image (e.g., sda): "
        if [ "$drive_choice" == "x" ] || [ "$drive_choice" == "X" ]; then
            escape_to_desktop
            return
        fi
        if [ -z "$drive_choice" ]; then
            return
        fi

        if ! is_disk_name "$drive_choice" || [ ! -b "/dev/$drive_choice" ]; then
            echo "❌ Error: Device '/dev/$drive_choice' is not a valid block device."
            tui_read fakeKey "Press [Enter] key to continue..."
            continue
        fi

        if [ -n "$(list_unmounted_parts "$drive_choice")" ]; then
            if mount_unmounted_volumes "$drive_choice"; then
                continue
            fi
        fi
        clone_selected_drive "$drive_choice"
        return
    done
}
