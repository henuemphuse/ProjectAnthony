# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# Session / VT helpers shared by the TUI, console unlock, and uninstaller.

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
        chvt "$vt" 2>/dev/null || true
    fi
    # Kernel VT: drop this unlocked root session so the next F3 re-prompts.
    t=$(tty 2>/dev/null || true)
    if [[ "$t" == /dev/tty[0-9]* ]]; then
        exit 0
    fi
    return 0
}
