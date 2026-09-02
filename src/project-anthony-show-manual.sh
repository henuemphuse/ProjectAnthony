#!/bin/bash
# Open the Project Anthony manual in a visible desktop window.
# postinst calls --from-install as root (must not block dpkg).
# Autostart calls --first-run so a headless .deb install still shows
# the manual on the next graphical login.

README="/usr/share/doc/project-anthony/README.txt"
[ -f "$README" ] || README="/usr/share/doc/project-anthony/README"

desktop_users() {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1}'
}

home_of() {
    getent passwd "$1" | cut -d: -f6
}

stamp_of() {
    echo "$(home_of "$1")/.config/project-anthony/manual-seen"
}

mark_seen() {
    local home stamp
    home=$(home_of "$1")
    [ -n "$home" ] || return 0
    stamp="${home}/.config/project-anthony/manual-seen"
    mkdir -p "$(dirname "$stamp")"
    touch "$stamp"
    chown -R "$1:" "${home}/.config/project-anthony" 2>/dev/null || true
}

already_seen() {
    [ -f "$(stamp_of "$1")" ]
}

target_users() {
    local u
    [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ] && echo "$SUDO_USER"
    if [ -n "${PKEXEC_UID:-}" ]; then
        u=$(getent passwd "$PKEXEC_UID" | cut -d: -f1)
        [ -n "$u" ] && [ "$u" != "root" ] && echo "$u"
    fi
    desktop_users
}

unique_users() {
    target_users | awk 'NF && !seen[$0]++'
}

user_has_graphical_session() {
    local u="$1" uid
    uid=$(id -u "$u" 2>/dev/null) || return 1
    [ -S "/run/user/${uid}/bus" ] || return 1
    [ -S "/run/user/${uid}/wayland-0" ] && return 0
    [ -S "/run/user/${uid}/wayland-1" ] && return 0
    [ -n "${DISPLAY:-}" ] && return 0
    [ -S /tmp/.X11-unix/X0 ] && return 0
    return 1
}

user_launch_env() {
    local u="$1" uid home sid type display
    uid=$(id -u "$u")
    home=$(home_of "$u")
    echo "HOME=${home}"
    echo "USER=${u}"
    echo "LOGNAME=${u}"
    echo "XDG_RUNTIME_DIR=/run/user/${uid}"
    echo "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus"
    echo "PATH=/usr/local/bin:/usr/bin:/bin"
    if [ -S "/run/user/${uid}/wayland-0" ]; then
        echo "WAYLAND_DISPLAY=wayland-0"
    elif [ -S "/run/user/${uid}/wayland-1" ]; then
        echo "WAYLAND_DISPLAY=wayland-1"
    fi
    while read -r sid _; do
        [ -z "$sid" ] && continue
        [ "$(loginctl show-session "$sid" -p Name --value 2>/dev/null)" = "$u" ] || continue
        type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
        display=$(loginctl show-session "$sid" -p Display --value 2>/dev/null)
        if [ -n "$display" ]; then
            echo "DISPLAY=${display}"
        elif [ "$type" = "x11" ]; then
            echo "DISPLAY=:0"
        fi
        break
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    if [ -z "${display:-}" ] && [ -S /tmp/.X11-unix/X0 ]; then
        echo "DISPLAY=:0"
    fi
    if [ -f "${home}/.Xauthority" ]; then
        echo "XAUTHORITY=${home}/.Xauthority"
    fi
}

install_desktop_shortcuts() {
    local u="$1" home desk src dest
    home=$(home_of "$u")
    [ -n "$home" ] || return 0
    desk="${home}/Desktop"
    [ -d "$desk" ] || desk="${home}/desktop"
    [ -d "$desk" ] || return 0
    for src in /usr/share/applications/project-anthony.desktop \
               /usr/share/applications/project-anthony-manual.desktop; do
        [ -f "$src" ] || continue
        dest="${desk}/$(basename "$src")"
        cp -f "$src" "$dest"
        chown "$u:" "$dest" 2>/dev/null || true
        chmod 0755 "$dest"
        sudo -u "$u" env $(user_launch_env "$u") \
            gio set "$dest" metadata::trusted true >/dev/null 2>&1 || true
    done
}

pick_opener() {
    if command -v xed >/dev/null; then
        echo xed
    elif command -v xdg-open >/dev/null; then
        echo xdg-open
    elif command -v gnome-text-editor >/dev/null; then
        echo gnome-text-editor
    elif command -v gedit >/dev/null; then
        echo gedit
    elif command -v pluma >/dev/null; then
        echo pluma
    elif command -v mousepad >/dev/null; then
        echo mousepad
    elif command -v gnome-terminal >/dev/null; then
        echo gnome-terminal
    fi
}

open_readme_here() {
    local opener
    [ -f "$README" ] || return 1
    opener=$(pick_opener)
    case "$opener" in
        gnome-terminal)
            gnome-terminal --title="Project Anthony Manual" --geometry=100x42 -- \
                env LESSSECURE=1 less -X -- "$README" >/dev/null 2>&1 &
            disown >/dev/null 2>&1 || true
            ;;
        "")
            if [ -t 1 ]; then
                LESSSECURE=1 less -X -- "$README"
                return 0
            fi
            return 1
            ;;
        *)
            "$opener" "$README" >/dev/null 2>&1 &
            disown >/dev/null 2>&1 || true
            ;;
    esac
}

spawn_as_user() {
    local u="$1" uid gid envline
    local -a cmd
    uid=$(id -u "$u" 2>/dev/null) || return 1
    gid=$(id -g "$u" 2>/dev/null) || return 1
    user_has_graphical_session "$u" || return 1
    if command -v systemd-run >/dev/null; then
        # Detach from dpkg's cgroup so the editor survives postinst exit.
        cmd=(systemd-run --quiet --collect
            --uid="$uid" --gid="$gid"
            --property=KillMode=process)
        while IFS= read -r envline; do
            [ -n "$envline" ] || continue
            cmd+=(--setenv="$envline")
        done < <(user_launch_env "$u")
        cmd+=(/usr/local/bin/project-anthony-show-manual --as-user)
        "${cmd[@]}"
        return $?
    fi
    sudo -u "$u" env $(user_launch_env "$u") \
        nohup /usr/local/bin/project-anthony-show-manual --as-user \
        >/dev/null 2>&1 &
}

if [ "${1:-}" = "--as-user" ]; then
    open_readme_here
    exit 0
fi

if [ "${1:-}" = "--first-run" ]; then
    me=$(id -un)
    already_seen "$me" && exit 0
    install_desktop_shortcuts "$me"
    if open_readme_here; then
        mark_seen "$me"
    fi
    exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "📄 Opening the Project Anthony manual for the desktop user..."
    while read -r u; do
        [ -n "$u" ] || continue
        install_desktop_shortcuts "$u"
        if spawn_as_user "$u"; then
            mark_seen "$u"
            echo "✔ Manual launched for ${u}."
        else
            echo "ℹ  ${u} has no live graphical session yet. The manual will open at next login."
        fi
    done < <(unique_users)
    exit 0
fi

open_readme_here
exit 0
