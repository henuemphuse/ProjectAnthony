# Sourced by /usr/local/bin/project-anthony. Not a standalone program.
# Main rescue menu: draw the option list, read a choice, dispatch it.
# Sub-screens live in tui.sh / tui-storage.sh. Crash prompt is tui-crash.sh.

draw_core_menu() {
    clear
    echo "=========================================="
    echo "          PROJECT ANTHONY: RESCUE         "
    echo "=========================================="
    echo " 1. Desktop Client Reinitialization (X11/Wayland)"
    echo " 2. Create Disk Image & Drive Migration (ddrescue)"
    echo " 3. Timeshift Restore (System)"
    echo " 4. Hardware & Kernel Diagnostics (Voltages/Logs)"

        # 🖥️ DYNAMIC SESSION & TTY EVALUATION MATRIX
    probe_graphical_session
    CURRENT_TTY=$(tty)
    GRAPHICAL_VT="$GRAPHICAL_VT"
    ON_RESCUE_VT=0
    if [[ "$CURRENT_TTY" == /dev/tty[0-9]* ]]; then
        ON_RESCUE_VT=1
        CURRENT_SESSION_TYPE="tty"
    else
        CURRENT_SESSION_TYPE="${XDG_SESSION_TYPE:-$GRAPHICAL_TYPE}"
    fi

    # Rescue console still has a desktop to jump back to — that is the whole point of F3.
    if [ "$ON_RESCUE_VT" -eq 1 ]; then
        if [ -n "$GRAPHICAL_VT" ]; then
            echo " 5. Return to Graphical Desktop (TTY${GRAPHICAL_VT})"
        else
            echo " 5. Return to Graphical Desktop"
        fi
    else
        echo " 5. Exit to Graphical Desktop"
    fi
    echo " 6. System logs (status: $(system_log_status))"
    echo " h. View Manual (hotkeys, what it does, how to open it)"
    echo "=========================================="
    echo " Access: Ctrl+Alt+X (desktop)  |  Ctrl+Alt+F3 (frozen)  |  Alt+SysRq+R then F3 (stuck keyboard)"
    echo "=========================================="
}

dispatch_core_choice() {
    case $choice in
        1)
            desktop_reinit_menu
            ;;
        2)
            storage_matrix_menu
            ;;
        3)
            timeshift_restore_menu
            ;;
        4)
            hardware_diagnostics
            ;;
        5)
            if [ "$ON_RESCUE_VT" -eq 1 ]; then
                escape_to_desktop
                # Exit so systemd restarts a locked TUI. Next F3 asks again.
                exit 0
            else
                # Already inside a desktop terminal window — just close the TUI.
                exit 0
            fi
            ;;
        6)
            show_system_logs
            ;;
        h|H|help|manual|m|M)
            open_packaged_manual
            ;;
        u|uninstall|U|UNINSTALL)
            confirm_and_uninstall
            ;;
        *)
            echo "❌ Invalid option or utility command. Please try again."
            tui_read fakeKey "Press [Enter] key to continue..."
            ;;
    esac
}

run_core_menu() {
    while true
    do
        draw_core_menu
        tui_read choice "Enter choice: "
        dispatch_core_choice
    done
}
