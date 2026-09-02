#!/bin/bash
# Rescue TUI on a kernel VT. exec so this process *is* the TUI (and later
# the shell). "Exit to Open Command Shell" replaces the TUI with bash
# in-place; systemd Restart=always brings the menu back when that shell
# exits. --noprofile/--norc so /root/.bashrc cannot relaunch the TUI.
export TERM="${TERM:-linux}"
export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
cd /root 2>/dev/null || cd /
exec /usr/local/bin/project-anthony --run-core-menu
