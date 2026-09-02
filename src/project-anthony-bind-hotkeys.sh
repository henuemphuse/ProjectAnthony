#!/bin/bash
# Desktop hotkey: Ctrl+Alt+X opens Project Anthony.
# Ctrl+Alt+Del is left as Cinnamon's stock logout dialog.
#
# Cinnamon only rebuilds custom hotkeys when custom-list changes
# (see cinnamon-settings KeybindingTable.ensureCustomListChanges).

CAD_CMD='/usr/bin/gnome-terminal --full-screen -- /usr/local/bin/project-anthony --run-core-menu'
CUSTOM_ID='custom0'
SCHEMA='org.cinnamon.desktop.keybindings.custom-keybinding'
CUSTOM_PATH="/org/cinnamon/desktop/keybindings/custom-keybindings/${CUSTOM_ID}/"

gs() {
    gsettings "$@"
}

# gsettings relocatable schema: SCHEMA:PATH KEY VALUE  (KEY is a separate argv)
custom_gs() {
    gs set "${SCHEMA}:${CUSTOM_PATH}" "$@"
}

# Toggle __dummy__ so cinnamon's changed::custom-list handler reloads grabs.
touch_custom_list() {
    local list merged
    list=$(gs get org.cinnamon.desktop.keybindings custom-list 2>/dev/null || echo "[]")
    case "$list" in
        "@as []"|"[]") merged="['${CUSTOM_ID}']" ;;
        *"'$CUSTOM_ID'"*) merged="$list" ;;
        *) merged="${list%]*}, '${CUSTOM_ID}']" ;;
    esac
    case "$merged" in
        *"__dummy__"*)
            merged=$(printf '%s\n' "$merged" | sed -e "s/, '__dummy__'//g" -e "s/'__dummy__', //g")
            ;;
        *)
            merged="${merged%]*}, '__dummy__']"
            ;;
    esac
    gs set org.cinnamon.desktop.keybindings custom-list "$merged"
}

apply_bindings() {
    gs set org.cinnamon.desktop.keybindings.media-keys logout "['<Control><Alt>Delete']"
    custom_gs name "Project Anthony Rescue"
    custom_gs command "$CAD_CMD"
    custom_gs binding "['<Primary><Alt>x']"
    touch_custom_list
}

unbind_bindings() {
    custom_gs binding "[]"
    custom_gs command "''"
    touch_custom_list
}

gsettings_on_bus() {
    local u="$1"
    shift
    local uid bus home
    uid=$(id -u "$u" 2>/dev/null) || return 0
    home=$(getent passwd "$u" | cut -d: -f6)
    bus="unix:path=/run/user/${uid}/bus"
    sudo -u "$u" env \
        HOME="${home:-/home/$u}" \
        USER="$u" \
        LOGNAME="$u" \
        DBUS_SESSION_BUS_ADDRESS="$bus" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        DISPLAY="${DISPLAY:-:0}" \
        gsettings "$@"
}

apply_for_user() {
    local u="$1"
    local uid
    uid=$(id -u "$u" 2>/dev/null) || return 0
    gs() { gsettings_on_bus "$u" "$@"; }
    if [ -S "/run/user/${uid}/bus" ]; then
        if [ "${UNBIND:-0}" = 1 ]; then
            unbind_bindings
        else
            apply_bindings
        fi
    else
        sudo -u "$u" dbus-run-session -- "$0" ${UNBIND:+--unbind} || true
    fi
}

UNBIND=0
if [ "${1:-}" = "--unbind" ]; then
    UNBIND=1
    shift
fi

if [ "$(id -u)" -eq 0 ]; then
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home\// {print $1}' | while read -r u; do
        apply_for_user "$u"
    done
    exit 0
fi

if [ "$UNBIND" = 1 ]; then
    unbind_bindings
else
    apply_bindings
fi
