#!/bin/bash

# =========================================================================
#   PROJECT ANTHONY: LOCAL DEVELOPMENT ENVIRONMENT UNINSTALLER WRAPPER
# =========================================================================
# Description: Invokes Project Anthony's native integrated self-cleanup 
#              engine to completely revert hooks and system parameters.
# =========================================================================

# Ensure the script is executed with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This uninstaller must be run with sudo permissions."
    echo "Usage: sudo ./uninstall.sh"
    exit 1
fi

if [ -f /usr/local/bin/project-anthony ]; then
    # Simply fire the master self-teardown function built into the core binary
    sudo /usr/local/bin/project-anthony --uninstall
else
    echo "❌ Project Anthony core binary not detected in /usr/local/bin/."
    echo "The environment is likely already cleanly removed from your host system."
fi
