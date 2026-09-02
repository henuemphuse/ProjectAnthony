#!/bin/bash
# Desktop hotkey: Ctrl+Alt+X opens Project Anthony.
# Ctrl+Alt+Del is left as Cinnamon's stock logout dialog.

CAD_CMD='/usr/bin/gnome-terminal --full-screen -- /usr/local/bin/project-anthony --run-core-menu'
SCHEMA_PATH='org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/'

apply_bindings() {
    gsettings set org.cinnamon.desktop.keybindings.media-keys logout "['<Control><Alt>Delete']"
    gsettings set org.cinnamon.desktop.keybindings custom-list "['custom0']"
    gsettings set "${SCHEMA_PATH}name" "Project Anthony Rescue"
    gsettings set "${SCHEMA_PATH}command" "$CAD_CMD"
    gsettings set "${SCHEMA_PATH}binding" "['<Primary><Alt>x']"
}

gsettings_on_bus() {
    local u="$1"
    local uid bus
    uid=$(id -u "$u" 2>/dev/null) || return 0
    bus="unix:path=/run/user/${uid}/bus"
    sudo -u "$u" env \
        DBUS_SESSION_BUS_ADDRESS="$bus" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        DISPLAY="${DISPLAY:-:0}" \
        gsettings "$@"
}

apply_for_user() {
    local u="$1"
    local uid
    uid=$(id -u "$u" 2>/dev/null) || return 0
    if [ -S "/run/user/${uid}/bus" ]; then
        gsettings_on_bus "$u" set org.cinnamon.desktop.keybindings.media-keys logout "['<Control><Alt>Delete']"
        gsettings_on_bus "$u" set org.cinnamon.desktop.keybindings custom-list "['custom0']"
        gsettings_on_bus "$u" set "${SCHEMA_PATH}name" "Project Anthony Rescue"
        gsettings_on_bus "$u" set "${SCHEMA_PATH}command" "$CAD_CMD"
        gsettings_on_bus "$u" set "${SCHEMA_PATH}binding" "['<Primary><Alt>x']"
    else
        sudo -u "$u" dbus-run-session -- "$0" || true
    fi
}

if [ "$(id -u)" -eq 0 ]; then
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1}' | while read -r u; do
        apply_for_user "$u"
    done
    exit 0
fi

apply_bindings
