#!/bin/bash

# =========================================================================
#   PROJECT ANTHONY: MASTER SYSTEM INSTALLER (FORCE OVERWRITE ENABLED)
# =========================================================================
# Description: Automates the multi-tier deployment of Project Anthony.
#              Forces an overwrite of all existing hooks, binaries, and 
#              systemd configurations to repair broken environments.
# =========================================================================

# Ensure the script is executed with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This installer must be run with sudo permissions."
    echo "Usage: sudo ./install.sh"
    exit 1
fi

INSTALL_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$INSTALL_ROOT/src"

install_auth_helper() {
    local dest_bin="/usr/local/bin/project-anthony-auth"
    local dest_pam="/etc/pam.d/project-anthony"
    local pamlib=""
    cp -f "$INSTALL_ROOT/packaging/project-anthony.pam" "$dest_pam"
    pamlib=$(ls /lib/*/libpam.so.0 /usr/lib/*/libpam.so.0 2>/dev/null | head -n1)
    if command -v gcc >/dev/null && [ -n "$pamlib" ] && \
        gcc -O2 -s -o "$dest_bin" "$SRC_DIR/project-anthony-auth.c" "$pamlib" 2>/dev/null; then
        echo "✔ Installed PAM console-unlock helper."
    else
        cp -f "$SRC_DIR/project-anthony-auth.py" "$dest_bin"
        echo "✔ Installed PAM console-unlock helper (python fallback)."
    fi
    chmod 700 "$dest_bin"
    chmod 644 "$dest_pam"
}

echo "=================================================="
echo "          PROJECT ANTHONY: DEPLOYMENT             "
echo "=================================================="

# 1. Dependency Validation Engine
echo "📦 Step 1: Validating system dependencies..."
DEPENDENCIES=(timeshift gddrescue bc smartmontools lm-sensors)
MISSING_DEPS=()

for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
        if [ "$dep" == "smartmontools" ] && command -v smartctl &>/dev/null; then
            continue
        fi
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "⚠️  Missing core utilities: ${MISSING_DEPS[*]}"
    echo "🔄 Fetching missing components via apt-get..."
    apt-get update && apt-get install -y "${MISSING_DEPS[@]}"
    if [ $? -ne 0 ]; then
        echo "❌ Critical Error: Failed to acquire necessary system components."
        exit 1
    fi
else
    echo "✔ All core system utilities are securely present."
fi

# 2. Establish Workspace Architecture
echo "📁 Step 2: Syncing system configuration pathways..."
USER_HOME=""
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
[ -z "$USER_HOME" ] && USER_HOME=/root
CONFIG_DIR="$USER_HOME/.config/liferaft"

if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown -R "$SUDO_USER:$SUDO_USER" "$CONFIG_DIR"
    fi
    echo "✔ Created configuration storage matrix at $CONFIG_DIR"
fi

# 3. Deploy Executable Components (Forcing File Overwrite)
echo "🚀 Step 3: Deploying system-wide operational wrappers..."
if [ ! -f "$SRC_DIR/liferaft.sh" ]; then
    echo "❌ Critical Error: Unable to locate source file at $SRC_DIR/liferaft.sh"
    exit 1
fi

# Use -f to forcefully overwrite /usr/local/bin/project-anthony if it already exists
cp -f "$SRC_DIR/liferaft.sh" /usr/local/bin/project-anthony
chmod +x /usr/local/bin/project-anthony
echo "✔ Deployed main rescue interface launcher to /usr/local/bin/project-anthony"

cp -f "$INSTALL_ROOT/src/anthony-monitor.sh" /usr/local/bin/project-anthony-monitor
cp -f "$INSTALL_ROOT/src/project-anthony-tty.sh" /usr/local/bin/project-anthony-tty
cp -f "$INSTALL_ROOT/src/project-anthony-bind-hotkeys.sh" /usr/local/bin/project-anthony-bind-hotkeys
cp -f "$INSTALL_ROOT/src/project-anthony-show-manual.sh" /usr/local/bin/project-anthony-show-manual
chmod +x /usr/local/bin/project-anthony-monitor /usr/local/bin/project-anthony-tty \
    /usr/local/bin/project-anthony-bind-hotkeys /usr/local/bin/project-anthony-show-manual
install_auth_helper
cp -f "$INSTALL_ROOT/packaging/project-anthony-monitor.service" /etc/systemd/system/project-anthony-monitor.service
cp -f "$INSTALL_ROOT/packaging/project-anthony-tty.service" /etc/systemd/system/project-anthony-tty.service
mkdir -p /etc/xdg/autostart /usr/share/applications /usr/share/doc/project-anthony
cp -f "$INSTALL_ROOT/packaging/project-anthony-hotkeys.desktop" /etc/xdg/autostart/project-anthony-hotkeys.desktop
cp -f "$INSTALL_ROOT/packaging/project-anthony-first-run.desktop" /etc/xdg/autostart/project-anthony-first-run.desktop
cp -f "$INSTALL_ROOT/packaging/project-anthony.desktop" /usr/share/applications/project-anthony.desktop
cp -f "$INSTALL_ROOT/packaging/project-anthony-manual.desktop" /usr/share/applications/project-anthony-manual.desktop
cp -f "$INSTALL_ROOT/src/README.txt" /usr/share/doc/project-anthony/README.txt
cp -f "$INSTALL_ROOT/LICENSE" /usr/share/doc/project-anthony/LICENSE
cp -f "$INSTALL_ROOT/LICENSE" /usr/share/doc/project-anthony/copyright
systemctl daemon-reload
systemctl enable project-anthony-monitor.service
systemctl restart project-anthony-monitor.service
echo "✔ Deployed lightweight crash watchdog (project-anthony-monitor.service)."

# 4. Inject the Automated Rolling Snapshot System
echo "📸 Step 4: Initializing defensive background shield..."
AUTOSNAP_PATH="/usr/local/bin/liferaft-autosnap.sh"

cp -f "$SRC_DIR/liferaft-autosnap.sh" "$AUTOSNAP_PATH"
chmod +x "$AUTOSNAP_PATH"
"$AUTOSNAP_PATH" --bootstrap || true
echo "✔ Deployed single-slot rolling snapshot execution matrix."

# 5. Establish the System Update APT Hook
echo "⚓ Step 5: Anchoring automated update hook..."
HOOK_CONF="/etc/apt/apt.conf.d/99-liferaft-autosnap"
# Single redirect bracket '>' completely overwrites the configuration hook file cleanly
echo "DPkg::Pre-Install-Pkgs { \"$AUTOSNAP_PATH\"; };" > "$HOOK_CONF"
echo "✔ APT layer hook successfully locked into /etc/apt/apt.conf.d/"

# 6. Desktop hotkey: Ctrl+Alt+X (Ctrl+Alt+Del stays as logout)
echo "⌨️  Step 6: Binding Ctrl+Alt+X to Project Anthony..."
/usr/local/bin/project-anthony-bind-hotkeys || true
echo "✔ Desktop Ctrl+Alt+X opens Project Anthony. Ctrl+Alt+Del remains logout."

# 7. Restore stock systemd Ctrl+Alt+Del if an older build overrode it
rm -f /etc/systemd/system/ctrl-alt-del.target /etc/systemd/system/project-anthony-cad.service

# 8. Dedicated TTY3 rescue console (no getty autologin crash-loop)
echo "⚓ Step 8: Installing TTY3 rescue console service..."
if [ -f /root/.bashrc ]; then
    sed -i '/# Project Anthony TTY3 Shell Trap Module/,/fi/d' /root/.bashrc
fi
rm -rf /etc/systemd/system/getty@tty3.service.d
systemctl daemon-reload
systemctl stop getty@tty3.service >/dev/null 2>&1 || true
systemctl reset-failed getty@tty3.service >/dev/null 2>&1 || true
systemctl mask getty@tty3.service >/dev/null 2>&1 || true
systemctl enable --now project-anthony-tty.service
systemctl restart project-anthony-tty.service >/dev/null 2>&1 || true
echo "✔ TTY3 rescue console is active (password unlock required)."

# 9. Magic SysRq — last path when even systemd/chvt are wedged
# Alt+SysRq+R puts the keyboard back in cooked mode so Ctrl+Alt+F3 can land.
echo "⌨️  Step 9: Enabling Magic SysRq keyboard recovery..."
cat << 'EOF' > /etc/sysctl.d/99-project-anthony-sysrq.conf
# Project Anthony: Alt+SysRq+R only (unraw). Do not enable the full SysRq set.
kernel.sysrq = 16
EOF
sysctl -p /etc/sysctl.d/99-project-anthony-sysrq.conf >/dev/null
echo "✔ Magic SysRq unraw enabled (Alt+SysRq+R, then Ctrl+Alt+F3)."

# 10. Deliver System Documentation Matrix (README Display)
echo "📄 Step 10: Launching Project Anthony Documentation..."
/usr/local/bin/project-anthony-show-manual --from-install || true

echo "=================================================="
echo "🏆 PROJECT ANTHONY SYSTEM LAYER FULLY REPAIR-DEPLOYED!   "
echo "=================================================="
