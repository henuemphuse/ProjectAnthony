#!/bin/bash

# =========================================================================
#   PROJECT ANTHONY: CORE EMERGENCY TUI RECOVERY ENGINE (LIFERAFT)
# =========================================================================
# Description: Entry point installed as /usr/local/bin/project-anthony.
#              Loads helpers from a root-owned library directory. A
#              watchdog crash screen is shown before unlock; the rescue
#              menu still requires a local password on TTY3. --uninstall
#              is root-only and does not load the TUI or auth code.
# =========================================================================

if [ "$1" == "--manual" ] || [ "$1" == "--help" ]; then
    exec /usr/local/bin/project-anthony-show-manual
fi

# Hardcoded. Do not take this from the environment (that would let a
# caller point the TUI at attacker-controlled scripts).
PA_LIB="/usr/local/lib/project-anthony"
readonly PA_LIB

pa_source() {
    local name="$1" f owner
    [[ "$name" =~ ^[a-z0-9][a-z0-9.-]*\.sh$ ]] || {
        echo "❌ Refusing to load invalid library name."
        exit 1
    }
    f="$PA_LIB/$name"
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || {
        echo "❌ Missing or refusing symlink $f"
        echo "Reinstall Project Anthony."
        exit 1
    }
    owner=$(stat -c '%u' "$f" 2>/dev/null) || owner=""
    [ "$owner" = "0" ] || {
        echo "❌ Refusing to load $f (not root-owned)."
        exit 1
    }
    # Group- or world-writable library files would be a root hijack.
    if [ -n "$(find "$f" -maxdepth 0 -perm -0022 2>/dev/null)" ]; then
        echo "❌ Refusing to load group/world-writable $f"
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$f"
}

if [ ! -d "$PA_LIB" ] || [ -L "$PA_LIB" ] \
    || [ "$(stat -c '%u' "$PA_LIB" 2>/dev/null)" != "0" ] \
    || [ -n "$(find "$PA_LIB" -maxdepth 0 -perm -0022 2>/dev/null)" ]; then
    echo "❌ Refusing to use $PA_LIB (missing, symlink, not root-owned, or group/world-writable)."
    exit 1
fi

pa_source session.sh

# 📑 ARGUMENT PARSER & DYNAMIC RESOLUTION INTERCEPT MATRIX
# Intercepts flags right at execution before painting the terminal view frame
if [ "$1" == "--uninstall" ]; then
    pa_source uninstall.sh
    execute_system_teardown
    exit 0
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
    exec gnome-terminal --full-screen --zoom="$ZOOM_SCALE" -- "$0" --run-core-menu
fi

# Auth, crash prompt, and menu are the same process. The crash notice is
# shown before unlock so the user can see what died without a password.
pa_source auth.sh
pa_source tui.sh
pa_source tui-storage.sh
pa_source tui-crash.sh
pa_source tui-menu.sh

# 🚨 Watchdog intercept: crash flag from the monitor, or an explicit test flag.
# n on this screen returns to the desktop. y continues to unlock (TTY3)
# and then the rescue menu.
CRASH_WANTS_RECOVERY=0
if [ "$1" == "--crash-prompt" ] || { [ -f "$STATE_FILE" ] && [ "$(head -n1 "$STATE_FILE" 2>/dev/null)" = "CRASH_TRIGGERED" ]; }; then
    crash_recovery_prompt "$1"
    CRASH_WANTS_RECOVERY=1
fi

# TTY3 is already root. Unlock with a local password before the rescue
# menu. Desktop Ctrl+Alt+X is unchanged.
if [ "$ON_KERNEL_VT" -eq 1 ]; then
    require_console_auth || exit 1
elif [ "$(id -u)" -ne 0 ] && [ -x /usr/local/bin/project-anthony-bind-hotkeys ]; then
    # Genuine desktop TUI: put the real command back if gsettings drifted.
    /usr/local/bin/project-anthony-bind-hotkeys >/dev/null 2>&1 || true
fi

# Crash latch stays until unlock succeeds so a hung_task repeat cannot
# restart TTY3 during the password prompt.
if [ "$CRASH_WANTS_RECOVERY" -eq 1 ]; then
    rm -f "$STATE_FILE"
fi

run_core_menu
