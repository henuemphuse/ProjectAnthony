#!/bin/bash
# Rescue TUI on a kernel VT. exec so this process *is* the TUI. The TUI
# asks for a local password before the menu or crash prompt. There is no
# root-shell option; leaving the menu (or returning to the desktop) exits
# so systemd Restart=always can present a fresh locked prompt.
export TERM="${TERM:-linux}"
export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
cd /root 2>/dev/null || cd /
export LESSSECURE=1
export HOME=/root
exec /usr/local/bin/project-anthony --run-core-menu
