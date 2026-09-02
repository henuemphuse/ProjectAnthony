#!/bin/bash

# =========================================================================
#   PROJECT ANTHONY: CORE EMERGENCY TUI RECOVERY ENGINE (LIFERAFT)
# =========================================================================
# Description: Provides an isolated Text User Interface dashboard below
#              standard display servers to manage system freezes, disk
#              cloning, system diagnostics, and automated rollbacks.
# =========================================================================

# Desktop users (uid >= 1000) so CAD bindings survive dpkg installs with no SUDO_USER
desktop_users() {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1}'
}

gsettings_as() {
    local user="$1"
    shift
    local uid
    uid=$(id -u "$user" 2>/dev/null) || return 0
    sudo -u "$user" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" gsettings "$@" 2>/dev/null || true
}

# Numeric VT from a loginctl TTY string ("tty8", "/dev/tty8") or a raw digit.
vt_from_tty_string() {
    local tty="$1"
    if [[ "$tty" == /dev/tty[0-9]* ]]; then
        echo "${tty#/dev/tty}"
    elif [[ "$tty" == tty[0-9]* ]]; then
        echo "${tty#tty}"
    elif [[ "$tty" == [0-9]* ]]; then
        echo "$tty"
    fi
}

# Probe the machine's graphical login (not this process). F3 is a kernel VT and
# the Ctrl+Alt+X launcher often has no XDG_SESSION_TYPE, so $XDG_SESSION_TYPE
# is the wrong signal for "is Cinnamon/X11 up".
#
# LightDM's Cinnamon Wayland session reports Type=wayland, VTNr=8, and an empty
# TTY property. Reading TTY and falling back to VT 7 lands on a blank kernel
# console (black screen, blinking cursor). Prefer VTNr, skip closing sessions,
# and keep the logind session id so we can ActivateSession on the way back.
probe_graphical_session() {
    GRAPHICAL_TYPE=""
    GRAPHICAL_VT=""
    GRAPHICAL_USER=""
    GRAPHICAL_SESSION=""
    GRAPHICAL_DISPLAY="${DISPLAY:-}"
    GRAPHICAL_XAUTHORITY="${XAUTHORITY:-}"

    local sid type class state tty vtnr display name rank best_rank=99
    while read -r sid _; do
        [ -z "$sid" ] && continue
        type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
        class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null)
        state=$(loginctl show-session "$sid" -p State --value 2>/dev/null)
        { [ "$type" = "x11" ] || [ "$type" = "wayland" ]; } || continue
        [ "$class" = "user" ] || continue
        [ "$state" = "closing" ] && continue

        rank=1
        [ "$state" = "active" ] && rank=0
        [ "$rank" -ge "$best_rank" ] && continue

        vtnr=$(loginctl show-session "$sid" -p VTNr --value 2>/dev/null)
        tty=$(loginctl show-session "$sid" -p TTY --value 2>/dev/null)
        name=$(loginctl show-session "$sid" -p Name --value 2>/dev/null)
        display=$(loginctl show-session "$sid" -p Display --value 2>/dev/null)

        GRAPHICAL_SESSION="$sid"
        GRAPHICAL_TYPE="$type"
        GRAPHICAL_USER="$name"
        [ -n "$display" ] && GRAPHICAL_DISPLAY="$display"
        if [ -n "$vtnr" ] && [ "$vtnr" != "0" ]; then
            GRAPHICAL_VT="$vtnr"
        else
            GRAPHICAL_VT=$(vt_from_tty_string "$tty")
        fi
        best_rank=$rank
        [ "$rank" -eq 0 ] && break
    done < <(loginctl list-sessions --no-legend 2>/dev/null)

    if [ -z "$GRAPHICAL_TYPE" ]; then
        if pgrep -x Xorg >/dev/null; then
            GRAPHICAL_TYPE="x11"
        elif pgrep -x gnome-shell >/dev/null || pgrep -x mutter >/dev/null \
            || pgrep -x muffin >/dev/null || pgrep -x Xwayland >/dev/null; then
            GRAPHICAL_TYPE="wayland"
        elif pgrep -x cinnamon >/dev/null || pgrep -x cinnamon-session >/dev/null; then
            GRAPHICAL_TYPE="x11"
        fi
    fi

    if [ -z "$GRAPHICAL_DISPLAY" ] && [ "$GRAPHICAL_TYPE" = "x11" ]; then
        GRAPHICAL_DISPLAY=":0"
    fi
    if [ -z "$GRAPHICAL_USER" ]; then
        GRAPHICAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1; exit}')
    fi
    if [ -n "$GRAPHICAL_USER" ]; then
        local home uid
        home=$(getent passwd "$GRAPHICAL_USER" | cut -d: -f6)
        uid=$(id -u "$GRAPHICAL_USER" 2>/dev/null)
        if [ -z "$GRAPHICAL_XAUTHORITY" ] && [ -n "$home" ] && [ -f "$home/.Xauthority" ]; then
            GRAPHICAL_XAUTHORITY="$home/.Xauthority"
        fi
        if [ -z "$GRAPHICAL_XAUTHORITY" ] && [ -n "$uid" ]; then
            local f
            for f in "/run/user/${uid}/gdm/Xauthority" "/run/user/${uid}/Xauthority"; do
                if [ -f "$f" ]; then
                    GRAPHICAL_XAUTHORITY="$f"
                    break
                fi
            done
        fi
    fi
}

find_graphical_vt() {
    probe_graphical_session
    if [ -n "$GRAPHICAL_VT" ]; then
        echo "$GRAPHICAL_VT"
        return 0
    fi
    return 1
}

on_kernel_vt() {
    local t
    t=$(tty 2>/dev/null || true)
    [[ "$t" == /dev/tty[0-9]* ]]
}

# Switch back to the compositor's VT. chvt alone is enough for Xorg (VT_PROCESS).
# Wayland compositors reclaim DRM via logind ResumeDevice, so ActivateSession
# has to run first. Blindly chvt 7 is wrong here: LightDM Wayland sits on VT 8
# with an empty TTY property, and VT 7 is an unused kernel console.
escape_to_desktop() {
    probe_graphical_session
    local vt="$GRAPHICAL_VT"
    local sid="$GRAPHICAL_SESSION"

    echo "🖥️ Switching to the graphical desktop${vt:+ (TTY${vt})}..."
    sleep 1

    if [ -n "$sid" ]; then
        loginctl activate "$sid" --no-ask-password 2>/dev/null || true
    fi
    if [ -n "$vt" ] && [ "$vt" != "0" ]; then
        chvt "$vt" 2>/dev/null && return 0
    fi
    return 1
}

# 🧼 THE INTEGRATED SELF-CLEANUP UNINSTALL ENGINE
execute_system_teardown() {
    echo "=================================================="
    echo "          PROJECT ANTHONY: SELF-CLEANUP           "
    echo "=================================================="
    
    # Verify root execution privileges for system file modification
    if [ "$EUID" -ne 0 ]; then
        echo "❌ Error: System teardown requires elevated root privileges."
        echo "Please re-run using: sudo project-anthony --uninstall"
        exit 1
    fi

    # 0. Stop the crash watchdog so it cannot fire during teardown
    echo "🐕 Stopping crash watchdog..."
    systemctl stop project-anthony-monitor.service 2>/dev/null || true
    systemctl disable project-anthony-monitor.service 2>/dev/null || true
    rm -f /run/project-anthony-state /run/project-anthony-monitor.cursor
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
        rm -f /etc/systemd/system/project-anthony-monitor.service
        rm -f /usr/local/bin/project-anthony-monitor
        systemctl daemon-reload 2>/dev/null || true
    fi

    # 1. Sever the System Update APT Hook
    echo "⚓ Step 1: Dismantling automated update hook..."
    HOOK_CONF="/etc/apt/apt.conf.d/99-liferaft-autosnap"
    if [ -f "$HOOK_CONF" ]; then
        rm -f "$HOOK_CONF"
        echo "✔ Successfully removed APT layer hook."
    fi

    # 2. Wipe Background Executable Components (only when not invoked from dpkg)
    echo "📸 Step 2: Removing rolling snapshot shield..."
    AUTOSNAP_PATH="/usr/local/bin/liferaft-autosnap.sh"
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ] && [ -f "$AUTOSNAP_PATH" ]; then
        rm -f "$AUTOSNAP_PATH"
        echo "✔ Successfully removed background snapshot matrix."
    fi

    # 3. Restore systemd Ctrl+Alt+Del to the stock reboot target
    echo "⚓ Step 3: Restoring systemd Ctrl+Alt+Del reboot target..."
    rm -f /etc/systemd/system/ctrl-alt-del.target
    rm -f /etc/systemd/system/project-anthony-cad.service
    systemctl daemon-reload
    echo "✔ systemd Ctrl+Alt+Del restored to default reboot behavior."

    # 4. Remove TTY3 rescue service and restore stock getty
    echo "⚓ Step 4: Removing TTY3 rescue console..."
    systemctl disable --now project-anthony-tty.service >/dev/null 2>&1 || true
    rm -rf /etc/systemd/system/getty@tty3.service.d
    rm -f /etc/xdg/autostart/project-anthony-hotkeys.desktop
    rm -f /etc/xdg/autostart/project-anthony-first-run.desktop
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
        rm -f /etc/systemd/system/project-anthony-tty.service
        rm -f /usr/local/bin/project-anthony-tty
        rm -f /usr/local/bin/project-anthony-bind-hotkeys
        rm -f /usr/local/bin/project-anthony-show-manual
        rm -f /usr/share/applications/project-anthony.desktop
        rm -f /usr/share/applications/project-anthony-manual.desktop
        rm -f /usr/share/doc/project-anthony/README.txt
        rm -f /usr/share/doc/project-anthony/LICENSE
        rm -f /usr/share/doc/project-anthony/copyright
        rmdir /usr/share/doc/project-anthony 2>/dev/null || true
    fi
    for u in $(desktop_users); do
        local_home=$(getent passwd "$u" | cut -d: -f6)
        [ -n "$local_home" ] || continue
        rm -f "${local_home}/Desktop/project-anthony.desktop"
        rm -f "${local_home}/Desktop/project-anthony-manual.desktop"
        rm -f "${local_home}/desktop/project-anthony.desktop"
        rm -f "${local_home}/desktop/project-anthony-manual.desktop"
        rm -f "${local_home}/.config/project-anthony/manual-seen"
    done
    systemctl unmask getty@tty3.service >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl reset-failed getty@tty3.service >/dev/null 2>&1 || true
    systemctl start getty@tty3.service >/dev/null 2>&1 || true
    echo "✔ TTY3 restored to a normal login getty."

    # 5. Disable Magic SysRq drop-in
    echo "⌨️  Step 5: Removing Magic SysRq sysctl drop-in..."
    rm -f /etc/sysctl.d/99-project-anthony-sysrq.conf
    sysctl --system >/dev/null 2>&1 || true

    # 6. Restore Cinnamon Ctrl+Alt+Del logout mapping for every desktop user
    echo "⌨️  Step 6: Restoring desktop Ctrl+Alt+Del logout shortcut..."
    if [ -x /usr/local/bin/project-anthony-bind-hotkeys ]; then
        /usr/local/bin/project-anthony-bind-hotkeys --unbind || true
    else
        for u in $(desktop_users); do
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.media-keys logout "['<Control><Alt>Delete']"
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/ binding "[]"
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/ command "''"
        done
    fi
    echo "✔ Desktop logout hotkey restored."

    # 7. Scrub the TTY3 Shell Trap from root's .bashrc
    echo "🧹 Step 7: Scrubbing shell trap blocks from /root/.bashrc..."
    if [ -f /root/.bashrc ]; then
        sed -i '/# Project Anthony TTY3 Shell Trap Module/,/fi/d' /root/.bashrc
        echo "✔ Finished scanning and cleaning /root/.bashrc lines."
    fi

    # 8. Purge the Core Menu Launcher Last (never steal files from a live dpkg remove)
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
        echo "🚀 Step 8: Deleting core UI launcher binary..."
        LAUNCHER_PATH="/usr/local/bin/project-anthony"
        if [ -f "$LAUNCHER_PATH" ]; then
            rm -f "$LAUNCHER_PATH"
            echo "✔ Core binary flagged for deletion."
        fi
        (
            sleep 1
            dpkg --purge project-anthony &>/dev/null
        ) &
    fi

    echo "=================================================="
    echo "🧹 PROJECT ANTHONY WIPE COMPLETE!        "
    echo "=================================================="

    # Adaptive session type check for a clean graphical exit
    CURRENT_SESSION_TYPE="$XDG_SESSION_TYPE"
    if [ -z "$CURRENT_SESSION_TYPE" ]; then
        CURRENT_SESSION_TYPE=$(loginctl show-session $(loginctl | grep "$USER" | awk '{print $1}') -p Type | cut -d= -f2)
    fi

    if [ "$CURRENT_SESSION_TYPE" == "x11" ]; then
        escape_to_desktop
    else
        echo "🚪 Wayland context detected. Closing environment window safely..."
        sleep 1
        exit 0
    fi
}

# Prompt used when the background watchdog detects a crash.
# Y restores from Timeshift. N asks whether to return to the desktop.
# State file (written by anthony-monitor): line 1 = CRASH_TRIGGERED,
# line 2 = one-line summary, remaining lines = short evidence snippet.
STATE_FILE="/run/project-anthony-state"
crash_recovery_prompt() {
    local summary="" details=""
    if [ -f "$STATE_FILE" ]; then
        summary=$(sed -n '2p' "$STATE_FILE" 2>/dev/null)
        details=$(tail -n +3 "$STATE_FILE" 2>/dev/null)
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
    echo "Would you like to restore from backup? [y/n]"
    echo "---------------------------------------------------------"
    echo ""
    read -p "Enter choice [y/n]: " crash_choice
    echo ""

    if [[ "$crash_choice" == "y" || "$crash_choice" == "Y" ]]; then
        echo "🚀 Opening Timeshift restore..."
        SYSTEM_SNAP_ID=$(sudo timeshift --list 2>/dev/null | grep "SYSTEM_LIFERAFT_ROLLING" | awk '{print $3}')
        if [ -n "$SYSTEM_SNAP_ID" ]; then
            sudo timeshift --restore --snapshot "$SYSTEM_SNAP_ID"
        else
            echo "❌ SYSTEM_LIFERAFT_ROLLING recovery point not found."
            echo "Opening the full Timeshift restore wizard instead..."
            sudo timeshift --restore
        fi
        read -p "Press [Enter] to continue..." fakeKey
        return 0
    fi

    read -p "Would you like to return to the desktop? [y/n]: " desk_choice
    echo ""
    if [[ "$desk_choice" == "y" || "$desk_choice" == "Y" ]]; then
        escape_to_desktop
        exit 0
    fi
}

# 📑 ARGUMENT PARSER & DYNAMIC RESOLUTION INTERCEPT MATRIX
# Intercepts flags right at execution before painting the terminal view frame
if [ "$1" == "--uninstall" ]; then
    execute_system_teardown
    exit 0
fi

if [ "$1" == "--manual" ] || [ "$1" == "--help" ]; then
    exec /usr/local/bin/project-anthony-show-manual
fi

# Kernel VTs (Ctrl+Alt+F3) have no DISPLAY. Run the TUI in-place so a
# frozen compositor cannot block the escape hatch.
CURRENT_TTY=$(tty 2>/dev/null || true)
ON_KERNEL_VT=0
if [[ "$CURRENT_TTY" == /dev/tty[0-9]* ]]; then
    ON_KERNEL_VT=1
fi

# This wrapper checks the display hardware grid and forces a perfectly upscaled
# full-screen terminal layout profile if launched from a living desktop session.
if [ "$1" != "--run-core-menu" ] && [ "$1" != "--crash-prompt" ] && [ "$1" != "--manual" ] && [ "$1" != "--help" ] && [ "$ON_KERNEL_VT" -eq 0 ] && { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; }; then
    if command -v xrandr &>/dev/null && [ "$XDG_SESSION_TYPE" == "x11" ]; then
        # X11 Layer Check: Grab the vertical resolution pixel metric
        V_RES=$(xrandr --current | grep -w connected | grep -oE '[0-9]+x[0-9]+' | head -n1 | cut -d'x' -f2)
    else
        # Wayland / Fallback Layer Check: Query DRM graphics nodes directly
        V_RES=$(cat /sys/class/drm/*/modes 2>/dev/null | grep -E '^[0-9]+x[0-9]+' | head -n1 | cut -d'x' -f2)
    fi

    # Baseline safe tracking fallback if display metrics fail to report completely
    [ -z "$V_RES" ] && V_RES=1080

    # Evaluate Resolution Profiles
    if [ "$V_RES" -ge 1440 ]; then
        # 1440p High-Density Display Scale Profile (Perfect for your 1440p display!)
        ZOOM_SCALE="1.5"
    elif [ "$V_RES" -ge 1080 ]; then
        # 1080p Standard Desktop Scale Profile
        ZOOM_SCALE="1.0"
    else
        # 720p / Low-Resolution Scale Profile
        ZOOM_SCALE="0.85"
    fi

    # Relaunch ourselves inside a clean, perfectly scaled full-screen terminal window
    # The '--run-core-menu' flag lets the script know it can skip the check on the next loop
    exec gnome-terminal --full-screen --zoom="$ZOOM_SCALE" -- bash -c "$0 --run-core-menu; exec bash"
fi

# 🚨 Watchdog intercept: crash flag from the monitor, or an explicit test flag
if [ "$1" == "--crash-prompt" ] || { [ -f "$STATE_FILE" ] && [ "$(head -n1 "$STATE_FILE" 2>/dev/null)" = "CRASH_TRIGGERED" ]; }; then
    crash_recovery_prompt "$1"
fi


# =========================================================================
# 📋 MAIN INTERACTIVE CORE LOOP 
# =========================================================================
while true
do
	clear
	echo "=========================================="
	echo "          PROJECT ANTHONY: RESCUE         "
	echo "=========================================="
	echo " 1. Desktop Client Reinitialization (X11/Wayland)"
	echo " 2. Create Disk Image & Drive Migration (ddrescue)"
	echo " 3. Timeshift Restore (System)"
	echo " 4. Hardware & Kernel Diagnostics (Voltages/Logs)"
	
		# 🖥️ DYNAMIC SESSION & TTY EVALUATION MATRIX
	probe_graphical_session
	CURRENT_TTY=$(tty)
	GRAPHICAL_VT="$GRAPHICAL_VT"
	ON_RESCUE_VT=0
	if [[ "$CURRENT_TTY" == /dev/tty[0-9]* ]]; then
		ON_RESCUE_VT=1
		CURRENT_SESSION_TYPE="tty"
	else
		CURRENT_SESSION_TYPE="${XDG_SESSION_TYPE:-$GRAPHICAL_TYPE}"
	fi

	# Rescue console still has a desktop to jump back to — that is the whole point of F3.
	if [ "$ON_RESCUE_VT" -eq 1 ]; then
		if [ -n "$GRAPHICAL_VT" ]; then
			echo " 5. Return to Graphical Desktop (TTY${GRAPHICAL_VT})"
		else
			echo " 5. Return to Graphical Desktop"
		fi
		echo " 6. Exit to Open Command Shell"
	elif [ "$CURRENT_SESSION_TYPE" == "x11" ] || [ "$CURRENT_SESSION_TYPE" == "wayland" ]; then
		echo " 5. Exit to Graphical Desktop"
		echo " 6. Exit to Open Terminal (Shell)"
	else
		echo " 5. Exit to Open Command Shell"
	fi
	echo " h. View Manual (hotkeys, what it does, how to open it)"
	echo "=========================================="
	echo " Access: Ctrl+Alt+X (desktop)  |  Ctrl+Alt+F3 (frozen)  |  Alt+SysRq+R then F3 (stuck keyboard)"
	echo "=========================================="
	read -p "Enter choice: " choice

	case $choice in
		1)
			while true; do
			clear
			echo "🔄 Desktop Client Reinitialization"
			echo "==========================================="
			
			# Use the machine's graphical session, not this process's TTY/env.
			probe_graphical_session
			CURRENT_SESSION_TYPE="${GRAPHICAL_TYPE:-unknown}"

			echo "📊 Active Graphics Environment Layer: ${CURRENT_SESSION_TYPE^^}"
			if [ -n "$GRAPHICAL_USER" ]; then
				echo "   Session user: ${GRAPHICAL_USER}   display: ${GRAPHICAL_DISPLAY:-n/a}"
			fi
			echo "-------------------------------------------"
			echo "Select which display action to execute:"
			
			if [ "$CURRENT_SESSION_TYPE" == "x11" ]; then
				echo " a) Restart Cinnamon Desktop (Keep open applications)"
			else
				echo " a) [DISABLED] Soft restart is unsupported on Wayland architecture"
			fi
			echo " b) Force Reset Display Manager (Reload LightDM Login Interface)"
			echo " c) Return to Main Menu"
			echo " x) EMERGENCY: Exit straight to desktop"
			echo "-------------------------------------------"
			read -r -p "Enter choice [a-x]: " desktop_choice </dev/tty
			echo ""

			case $desktop_choice in
				a)
					if [ "$CURRENT_SESSION_TYPE" == "x11" ]; then
						echo "⚡ Attempting an in-place soft restart of Cinnamon..."
						probe_graphical_session
						local_display="${GRAPHICAL_DISPLAY:-:0}"
						local_user="${GRAPHICAL_USER:-}"
						local_auth="${GRAPHICAL_XAUTHORITY:-}"
						local_uid=""
						[ -n "$local_user" ] && local_uid=$(id -u "$local_user" 2>/dev/null)
						local_dbus=""
						[ -n "$local_uid" ] && [ -S "/run/user/${local_uid}/bus" ] && local_dbus="unix:path=/run/user/${local_uid}/bus"
						# stdin MUST be /dev/null or cinnamon inherits this TTY and eats Enter.
						if [ "$(id -u)" -eq 0 ] && [ -n "$local_user" ] && [ "$local_user" != "root" ]; then
							sudo -u "$local_user" env \
								DISPLAY="$local_display" \
								${local_auth:+XAUTHORITY="$local_auth"} \
								${local_dbus:+DBUS_SESSION_BUS_ADDRESS="$local_dbus"} \
								${local_uid:+XDG_RUNTIME_DIR="/run/user/${local_uid}"} \
								cinnamon --replace </dev/null >/dev/null 2>&1 &
						else
							env DISPLAY="$local_display" \
								${local_auth:+XAUTHORITY="$local_auth"} \
								cinnamon --replace </dev/null >/dev/null 2>&1 &
						fi
						disown >/dev/null 2>&1 || true
						echo "✔ Refresh signal transmitted to the active desktop environment."
					else
						echo "⛔ Action blocked! Soft-replacing a compositor on Wayland will crash your session."
					fi
					read -r -p "Press [Enter] key to continue..." fakeKey </dev/tty
					;;
				b)
					echo "⚠️ WARNING: This action will instantly force-close all open applications!"
					read -r -p "Are you sure you want to completely reload LightDM? [y/n]: " confirm_reset </dev/tty
					if [ "$confirm_reset" == "y" ] || [ "$confirm_reset" == "Y" ]; then
						echo "🚀 Restarting LightDM Display Manager..."
						sudo systemctl restart display-manager
					else
						echo "❌ Reset sequence aborted."
						read -r -p "Press [Enter] key to continue..." fakeKey </dev/tty
					fi
					;;
				c|"")
					break
					;;
				x)
					escape_to_desktop
					;;
				*)
					echo "❌ Invalid choice option selected."
					read -r -p "Press [Enter] key to continue..." fakeKey </dev/tty
					;;
			esac
			done
			;;
		2)
			echo "💾 Project Anthony: Enhanced Capacity & Storage Matrix"
			echo "========================================================================="
			printf "%-12s | %-20s | %-8s | %-8s | %-12s\n" "DEVICE" "MODEL / NAME" "TOTAL" "FREE" "SMART HEALTH"
			echo "------------------------------------------------------------------------="
			
			if ! command -v smartctl &>/dev/null; then
				sudo apt install -y smartmontools &>/dev/null
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
			
			read -p "Select drive to image (e.g., sda): " drive_choice
			if [ "$drive_choice" == "x" ] || [ "$drive_choice" == "X" ]; then escape_to_desktop; continue; fi
			if [ -z "$drive_choice" ]; then continue; fi
			
			if [ ! -b "/dev/$drive_choice" ]; then
				echo "❌ Error: Device '/dev/$drive_choice' is not a valid block device."
				read -p "Press [Enter] key to continue..." fakeKey
				continue
			fi

			SRC_PATH="/dev/$drive_choice"
			SRC_SIZE_BYTES=$(blockdev --getsize64 "$SRC_PATH")
			SRC_SIZE_GB=$(echo "scale=2; $SRC_SIZE_BYTES / 1024 / 1024 / 1024" | bc)

			read -p "Enter DESTINATION drive or path (or [x] to exit straight to desktop): " dest_choice
			if [ "$dest_choice" == "x" ] || [ "$dest_choice" == "X" ]; then escape_to_desktop; continue; fi
			if [ -z "$dest_choice" ]; then continue; fi
			
			if [[ "$dest_choice" == *"$drive_choice"* ]]; then
				echo "⛔ CRITICAL ERROR: Destination cannot match or reside on source hardware!"
				read -p "Press [Enter] key to continue..." fakeKey
				continue
			fi

			if [ -b "/dev/$dest_choice" ]; then
				DEST_PATH="/dev/$dest_choice"
				DEST_SIZE_BYTES=$(blockdev --getsize64 "$DEST_PATH")
				DEST_SIZE_GB=$(echo "scale=2; $DEST_SIZE_BYTES / 1024 / 1024 / 1024" | bc)

				echo "📊 Sizing Analysis:"
				echo "   Source size:      $SRC_SIZE_GB GB"
				echo "   Destination size: $DEST_SIZE_GB GB"

				if (( $(echo "$DEST_SIZE_BYTES < $SRC_SIZE_BYTES" | bc -l) )); then
					echo "⚠️ WARNING: Target drive is SMALLER than source hardware."
					read -p "Force proceed anyway? [y/n]: " force_choice
					if [[ "$force_choice" != "y" && "$force_choice" != "Y" ]]; then continue; fi
				fi
			elif [ -d "$dest_choice" ]; then
				DEST_PATH="$dest_choice/${drive_choice}_backup.img"
			else
				echo "❌ Error: Destination target is invalid."
				read -p "Press [Enter] key to continue..." fakeKey
				continue
			fi

			echo "--------------------------------------------------"
			echo "🚨 PROPOSED DISK DEPLOYMENT TARGET:"
			echo "   SOURCE:      $SRC_PATH ($SRC_SIZE_GB GB)"
			echo "   DESTINATION: $DEST_PATH"
			echo "--------------------------------------------------"
			read -p "Commit to hardware migration? [y/n]: " final_lock

			if [[ "$final_lock" == "y" || "$final_lock" == "Y" ]]; then
				echo "🚀 Deploying cloning stream via ddrescue..."
				sudo ddrescue -v -b 4096 "$SRC_PATH" "$DEST_PATH" "${HOME}/${drive_choice}_rescue.log"
				echo "✔ Sector streaming complete."
			else
				echo "❌ Migration execution cancelled."
			fi
			read -p "Press [Enter] key to continue..." fakeKey
			;;
		3)
			echo "🚨 Timeshift System Restoration"
			echo "------------------------------------------"
			SYSTEM_SNAP_ID=$(sudo timeshift --list 2>/dev/null | grep "SYSTEM_LIFERAFT_ROLLING" | awk '{print $3}')

			if [ ! -z "$SYSTEM_SNAP_ID" ]; then
				read -p "Restore from automated system backup ($SYSTEM_SNAP_ID)? [y/n] (or [x] to exit to desktop): " quick_choice
				if [ "$quick_choice" == "x" ] || [ "$quick_choice" == "X" ]; then escape_to_desktop; continue; fi
				if [ "$quick_choice" == "y" ] || [ "$quick_choice" == "Y" ]; then
					echo "🚀 Initiating instant rollback to snapshot $SYSTEM_SNAP_ID..."
					sudo timeshift --restore --snapshot "$SYSTEM_SNAP_ID"
					read -p "Press [Enter] key to continue..." fakeKey
					continue
				fi
			fi

			echo "📋 Opening full snapshot selection wizard..."
			sudo timeshift --restore
			read -p "Press [Enter] key to continue..." fakeKey
			;;
		4)
			clear
			echo "📊 Project Anthony: Hardware & Kernel Diagnostics"
			echo "========================================================================="
			
			if ! command -v sensors &>/dev/null; then
				echo "🔄 Provisioning hardware sensor modules (lm-sensors)..."
				sudo apt install -y lm-sensors &>/dev/null
				sudo sensors-detect --auto &>/dev/null
			fi

			echo "⚡ Motherboard Voltages, Thermals & Fan Controllers:"
			echo "-------------------------------------------------------------------------"
			sensors 2>/dev/null | grep -E "Vcore|12V|5V|3.3V|in|fan|temp|Crit|Core" || echo "⚠️  No compatible monitoring sensors exposed."
			echo "-------------------------------------------------------------------------"
			echo ""
			echo "🧠 Core Kernel Alerts & Hardware Allocations (Last 5 Alerts):"
			echo "-------------------------------------------------------------------------"
			sudo dmesg -T | grep -Ei "error|fail|panic|corrupt|kill|hardware" | tail -n 5 || echo "✔ Kernel reports clean hardware allocations."
			echo "-------------------------------------------------------------------------"
			echo ""
			echo "👉 Press [Enter] to return or [x] to exit straight to desktop"
			read -p "Enter command: " diagnostic_exit
			if [[ "$diagnostic_exit" == "x" || "$diagnostic_exit" == "X" ]]; then
				escape_to_desktop
			fi
			;;
		5)
			if [ "$ON_RESCUE_VT" -eq 1 ]; then
				escape_to_desktop
			else
				# Already inside a desktop terminal window — just close the TUI.
				exit 0
			fi
			;;
		6)
			echo "🚪 Dropping to a root shell. Type 'exit' to return to the rescue menu."
			export PS1='[anthony] \u@\h:\w# '
			exec /bin/bash --noprofile --norc -i
			;;
		h|H|help|manual|m|M)
			MANUAL="/usr/share/doc/project-anthony/README.txt"
			[ -f "$MANUAL" ] || MANUAL="/usr/share/doc/project-anthony/README"
			if [ "$ON_RESCUE_VT" -eq 1 ] || [ ! -x /usr/local/bin/project-anthony-show-manual ]; then
				less -X "$MANUAL"
			else
				/usr/local/bin/project-anthony-show-manual || less -X "$MANUAL"
			fi
			;;
		u|uninstall|U|UNINSTALL)
			echo "⚠️  Initiating built-in system uninstallation sequence..."
			read -p "Are you absolutely sure you want to delete Project Anthony? [y/n]: " confirm_ui_wipe
			if [[ "$confirm_ui_wipe" == "y" || "$confirm_ui_wipe" == "Y" ]]; then
				execute_system_teardown
			else
				echo "❌ Action cancelled. Returning to dashboard..."
				sleep 1
			fi
			;;
		*)
			echo "❌ Invalid option or utility command. Please try again."
			read -p "Press [Enter] key to continue..." fakeKey
			;;
	esac
done