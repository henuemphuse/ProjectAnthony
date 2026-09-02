=========================================================================
          PROJECT ANTHONY: EMERGENCY SYSTEM LIFE RAFT - MANUAL
=========================================================================

QUICK START (read this first):
  Ctrl+Alt+X             Open Project Anthony over a living desktop
  Ctrl+Alt+F3            Rescue console if the desktop is frozen
  Alt+SysRq+R, then F3   Unstick a grabbed keyboard, then open TTY3
  Menu / Desktop         "Project Anthony Rescue" and "Project Anthony Manual"
  TUI key h              Open this document from the rescue menu
  This document          Opens automatically after install

  Ctrl+Alt+Del stays as the normal logout dialog.

DESCRIPTION:
  Project Anthony is a lightweight Text User Interface (TUI) environment
  engineered to serve as an indestructible system control interface.
  It isolates diagnostics below standard desktop compositors so users 
  can safely manage system hangs, display crashes, and disk failures 
  without triggering a hard hardware reset.

  One userspace program cannot survive a total GUI lockup. Recovery is
  stacked in three independent layers. Use the highest layer that still
  responds.

RECOVERY LAYERS:
  1. Desktop alive (Cinnamon still processing keys)
       [Ctrl] + [Alt] + [X]
       Opens Project Anthony full-screen over the current session.
       Ctrl+Alt+Del remains the stock logout dialog.

  2. Desktop frozen, kernel + systemd still alive
       [Ctrl] + [Alt] + [F3]
       Kernel virtual-terminal switch onto TTY3. A dedicated systemd
       service owns that console and draws the rescue TUI (getty is
       masked so it cannot crash-loop and leave a blank cursor).

  3. Keyboard stuck in raw/X grab (compositor dead, kernel alive)
       Hold [Alt], tap [SysRq] (often Print Screen), tap [R]
       Then [Ctrl] + [Alt] + [F3]
       SysRq+R is handled in the kernel keyboard ISR. It unraws the
       keyboard so the VT switch can complete. Nothing in userspace
       can do this.

  If the kernel itself is hung, no key combo will help. Use the
  hardware reset.

CORE OVERVIEW FUNCTIONS:
  1. Display Client Reinitialization: Inspects display server parameters 
     to provide in-place desktop refreshes under X11 configurations or
     display manager context reloads under LightDM.
  2. Smart Storage Matrix: Extracts physical hardware SMART controller
     diagnostics, live capacity tracking, and streams block-level clones/
     backups via ddrescue.
  3. Timeshift Restore: Automatically reads, lists, and mounts system 
     snapshots with targeted shortcuts for automated background rollbacks.
  4. Hardware & Kernel Diagnostics: Displays real-time motherboard rail
     voltages, thermals, and fan RPMs while pulling critical hardware-level
     error logs straight from the Linux kernel ring buffer.

BACKGROUND WATCHDOG:
  project-anthony-monitor.service is a low-priority daemon (nice 19, idle
  I/O, 32 MB cap). Every few seconds it checks for a compositor death
  under a live graphical login, a failed display manager, or a new kernel
  oops/panic/hung_task. On a hit it writes a crash flag, restarts TTY3,
  and switches you there.

  The TUI then names what tripped the watchdog (kernel oops, display
  manager failure, or a dead compositor) and prints a short evidence
  snippet from the journal, then asks:
    Would you like to restore from backup? [y/n]
      y  → Timeshift restore (rolling snapshot, or the full wizard)
      n  → Would you like to return to the desktop? [y/n]
             y  → switch back to the graphical VT
             n  → open the normal rescue menu

  Test the prompt without a real crash:
    sudo project-anthony --crash-prompt

COMMAND LINE:
  project-anthony                 Rescue TUI
  project-anthony --manual        This document
  sudo project-anthony --crash-prompt
                                  Test the watchdog y/n prompt

SYSTEM ALTERATIONS MADE:
  - System Launcher Bin: Placed into /usr/local/bin/project-anthony
  - Manual opener: /usr/local/bin/project-anthony-show-manual
  - Automated Background Script: Placed into /usr/local/bin/liferaft-autosnap.sh
  - System Package Layer Hook: Injected to /etc/apt/apt.conf.d/99-liferaft-autosnap
  - Cinnamon Ctrl+Alt+X bound to Project Anthony (Ctrl+Alt+Del stays logout)
  - Menu + Desktop launchers: Project Anthony Rescue and Project Anthony Manual
  - First-run autostart: project-anthony-first-run.desktop (shows this manual if
    dpkg ran without a live graphical session)
  - TTY3 rescue console: project-anthony-tty.service (getty@tty3 masked)
  - Magic SysRq enabled via /etc/sysctl.d/99-project-anthony-sysrq.conf
  - Crash watchdog: project-anthony-monitor.service (enabled at install)

SECURITY NOTE:
  TTY3 autologs in as root so a frozen machine can still be recovered
  without a password prompt. Physical console access equals root.
  Uninstall restores the Cinnamon Ctrl+Alt+X shortcut to empty.

=========================================================================
👉 PRESS [Q] AT ANY TIME TO EXIT
=========================================================================
