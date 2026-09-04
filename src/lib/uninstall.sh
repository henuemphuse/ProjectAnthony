# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# Integrated self-cleanup. Invoked as `project-anthony --uninstall` (dpkg
# prerm, uninstall.sh, TUI `u`). Requires root; does not skip TTY3 auth
# when reached from the menu (the dispatcher already unlocked). Desktop
# TUI `u` re-invokes this via sudo. Direct `--uninstall` is EUID 0 only.

# True when this process is the TTY3 rescue service. Stopping that unit
# from inside itself deadlocks systemd (`disable --now` waits for us to
# die; we wait for it). `Conflicts=getty@tty3` would also stop us if we
# started getty now. Restart=always would respawn the TUI if we just exit.
teardown_is_tty_service() {
    local me main
    me=$$
    main=$(systemctl show -p MainPID --value project-anthony-tty.service 2>/dev/null || true)
    [ -n "$main" ] && [ "$main" != "0" ] && [ "$me" = "$main" ]
}

# Finish work that must outlive this process: restore getty, drop the
# runtime TTY mask so a later reinstall can start the unit, and
# `dpkg --purge` so the package record is gone (reinstall does not need
# a manual purge). A background `&` job dies with the TUI / sudo pty;
# a transient systemd unit does not.
# Do not exec a file from /run — it is noexec, which produced
# "Failed to find executable ... Permission denied".
schedule_teardown_finish() {
    local purge="${1:-0}"
    if ! systemd-run --collect --quiet /bin/bash -c '
sleep 2
systemctl unmask --runtime project-anthony-tty.service >/dev/null 2>&1 || true
systemctl unmask project-anthony-tty.service >/dev/null 2>&1 || true
systemctl unmask getty@tty3.service >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed getty@tty3.service >/dev/null 2>&1 || true
systemctl start getty@tty3.service >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1 || true
if [ "$1" = "1" ]; then
    dpkg --purge project-anthony >/dev/null 2>&1 || true
fi
' x "$purge"; then
        echo "⚠️  Could not schedule post-uninstall purge. Run: sudo dpkg --purge project-anthony"
        return 1
    fi
    if [ "$purge" = "1" ]; then
        echo "📦 Package purge scheduled. You can reinstall without a manual dpkg --purge."
    fi
}

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
    rm -f /run/project-anthony-state /run/project-anthony-monitor.cursor /run/project-anthony-auth-fails \
        /run/project-anthony-log-alert /run/project-anthony-log-ratelimit
    rm -rf /var/log/project-anthony
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

    # Restore desktop hotkeys before deleting the binder binary.
    echo "⌨️  Restoring desktop hotkeys to system defaults..."
    if [ -x /usr/local/bin/project-anthony-bind-hotkeys ]; then
        /usr/local/bin/project-anthony-bind-hotkeys --unbind || true
    else
        for u in $(desktop_users); do
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.media-keys logout "['<Control><Alt>Delete']"
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/ binding "[]"
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/ command "''"
            gsettings_as "$u" set org.cinnamon.desktop.keybindings.custom-keybinding:/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/ name "''"
        done
    fi
    echo "✔ Ctrl+Alt+X released. Ctrl+Alt+Del is Cinnamon logout."

    # 4. Remove TTY3 rescue service and restore stock getty
    echo "⚓ Step 4: Removing TTY3 rescue console..."
    TEARDOWN_SELF=0
    if teardown_is_tty_service; then
        TEARDOWN_SELF=1
        systemctl disable project-anthony-tty.service >/dev/null 2>&1 || true
        # Mask so Restart=always cannot respawn the TUI after we exit.
        systemctl mask --runtime project-anthony-tty.service >/dev/null 2>&1 || true
    else
        systemctl disable --now project-anthony-tty.service >/dev/null 2>&1 || true
    fi
    rm -rf /etc/systemd/system/getty@tty3.service.d
    rm -f /etc/xdg/autostart/project-anthony-hotkeys.desktop
    rm -f /etc/xdg/autostart/project-anthony-first-run.desktop
    rm -rf /etc/project-anthony
    if [ -z "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
        rm -f /etc/systemd/system/project-anthony-tty.service
        rm -f /usr/local/bin/project-anthony-tty
        rm -f /usr/local/bin/project-anthony-bind-hotkeys
        rm -f /usr/local/bin/project-anthony-show-manual
        rm -f /usr/local/bin/project-anthony-auth
        rm -f /usr/local/bin/project-anthony-mk-token
        rm -f /usr/local/lib/project-anthony/restrict-pam-caller
        rm -f /usr/local/lib/project-anthony/session.sh
        rm -f /usr/local/lib/project-anthony/auth.sh
        rm -f /usr/local/lib/project-anthony/uninstall.sh
        rm -f /usr/local/lib/project-anthony/tui.sh
        rm -f /usr/local/lib/project-anthony/tui-storage.sh
        rm -f /usr/local/lib/project-anthony/tui-crash.sh
        rm -f /usr/local/lib/project-anthony/tui-menu.sh
        rmdir /usr/local/lib/project-anthony 2>/dev/null || true
        rm -f /etc/pam.d/project-anthony
        rm -f /etc/pam.d/project-anthony-u2f
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
        remove_desktop_launchers "$u"
        rm -f "${local_home}/.config/project-anthony/manual-seen"
        rm -rf "${local_home}/.config/project-anthony"
        rm -rf "${local_home}/.config/liferaft"
    done
    rm -rf /root/.config/project-anthony /root/.config/liferaft
    if findmnt -n /run/project-anthony-usbcheck >/dev/null 2>&1; then
        umount -l /run/project-anthony-usbcheck 2>/dev/null || true
    fi
    rmdir /run/project-anthony-usbcheck 2>/dev/null || true
    rm -f /etc/systemd/system/multi-user.target.wants/project-anthony-monitor.service \
        /etc/systemd/system/multi-user.target.wants/project-anthony-tty.service
    if [ "$TEARDOWN_SELF" -eq 1 ]; then
        echo "✔ TTY3 service disabled. Login getty will start after this console exits."
    else
        systemctl unmask getty@tty3.service >/dev/null 2>&1 || true
        systemctl daemon-reload
        systemctl reset-failed getty@tty3.service >/dev/null 2>&1 || true
        systemctl start getty@tty3.service >/dev/null 2>&1 || true
        echo "✔ TTY3 restored to a normal login getty."
    fi

    # 5. Disable Magic SysRq drop-in
    echo "⌨️  Step 5: Removing Magic SysRq sysctl drop-in..."
    rm -f /etc/sysctl.d/99-project-anthony-sysrq.conf
    # TTY3 has ProtectKernelTunables=yes; the deferred restorer applies this.
    if [ "$TEARDOWN_SELF" -eq 0 ]; then
        sysctl --system >/dev/null 2>&1 || true
    fi

    echo "✔ Magic SysRq drop-in removed."

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
        # Always purge via a detached unit so closing the TUI cannot
        # leave the package in `rc`/`ii` and block a later reinstall.
        schedule_teardown_finish 1
    elif [ "$TEARDOWN_SELF" -eq 1 ]; then
        schedule_teardown_finish 0
    fi

    echo "=================================================="
    echo "🧹 PROJECT ANTHONY WIPE COMPLETE!        "
    echo "=================================================="

    # TTY3: jump back to the compositor. Desktop TUI just closes.
    if on_kernel_vt; then
        escape_to_desktop
    fi
}
