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

storage_matrix_menu() {
    echo "💾 Project Anthony: Enhanced Capacity & Storage Matrix"
    echo "========================================================================="
    printf "%-12s | %-20s | %-8s | %-8s | %-12s\n" "DEVICE" "MODEL / NAME" "TOTAL" "FREE" "SMART HEALTH"
    echo "------------------------------------------------------------------------="

    if ! command -v smartctl &>/dev/null; then
        echo "⚠️  smartctl is not installed. SMART health will show as unknown."
        echo "    Install smartmontools from a normal session if you need it."
    fi

    for disk in $(lsblk -dno NAME,TYPE | grep "disk" | awk '{print $1}'); do
        MODEL=$(lsblk -dno MODEL "/dev/$disk" | sed 's/^[ \t]*//;s/[ \t]*$//')
        [ -z "$MODEL" ] && MODEL="Generic Disk"
        SIZE=$(lsblk -dno SIZE "/dev/$disk" | sed 's/^[ \t]*//;s/[ \t]*$//')

        # 📊 FREE SPACE CALCULATOR BLOCK
        FIRST_PART=$(lsblk -no NAME,TYPE "/dev/$disk" | grep "part" | head -n1 | awk '{print $1}')
        FREE_SPACE="--"

        if [ ! -z "$FIRST_PART" ]; then
            MOUNT_POINT=$(lsblk -no MOUNTPOINTS "/dev/$FIRST_PART" | head -n1)
            if [ ! -z "$MOUNT_POINT" ]; then
                FREE_SPACE=$(df -h "$MOUNT_POINT" | tail -n1 | awk '{print $4}')
            else
                FREE_SPACE="Unmounted"
            fi
        fi

        SMART_RAW=$(sudo smartctl -H "/dev/$disk" 2>/dev/null)
        if echo "$SMART_RAW" | grep -q "PASSED"; then HEALTH="🟢 PASSED"
        elif echo "$SMART_RAW" | grep -q "FAILED"; then HEALTH="🔴 FAILED!"
        elif echo "$SMART_RAW" | grep -q "OK"; then HEALTH="🟢 OK"
        else HEALTH="⚪ UNKNOWN"; fi

        printf "%-12s | %-20.20s | %-8s | %-8s | %-12s\n" "/dev/$disk" "$MODEL" "$SIZE" "$FREE_SPACE" "$HEALTH"
    done
    echo "========================================================================="
    echo "👉 Press [Enter] to return or [x] to exit straight to desktop"
    echo ""

    tui_read drive_choice "Select drive to image (e.g., sda): "
    if [ "$drive_choice" == "x" ] || [ "$drive_choice" == "X" ]; then escape_to_desktop; return; fi
    if [ -z "$drive_choice" ]; then return; fi

    if ! is_disk_name "$drive_choice" || [ ! -b "/dev/$drive_choice" ]; then
        echo "❌ Error: Device '/dev/$drive_choice' is not a valid block device."
        tui_read fakeKey "Press [Enter] key to continue..."
        return
    fi

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
        sudo ddrescue -v -b 4096 "$SRC_PATH" "$DEST_PATH" "$RESCUE_LOG"
        echo "✔ Sector streaming complete."
    else
        echo "❌ Migration execution cancelled."
    fi
    tui_read fakeKey "Press [Enter] key to continue..."
}
