# Project Anthony

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-informational)]()
[![Package](https://img.shields.io/badge/package-1.0--4_amd64-blue)]()

**Project Anthony** is a lightweight system restoration wrapper and interactive text dashboard for Linux. Named after the patron saint of lost things, it provides an emergency fallback to recover from corrupt software updates, display server deadlocks, or storage drive failures.

It uses native system utilities (`timeshift`, `gddrescue`, `smartctl`, `bc`, `lm-sensors`) so the resource overhead stays near zero.

---

## Key Features

* **Background Crash Interceptor:** A systemd daemon watches for a kernel oops/panic/hung task, a failed display manager, or a dead compositor under a live graphical login. Recoverable stalls (hung task, soft lockup, dead compositor, failed display-manager) are re-checked across a short confirmation loop so a brief hang can clear before the console is taken; oops/panic/hard lockup still trip immediately. Sleep/wake thaw gets a short grace so opening the lid does not look like a crash. On a confirmed hit it switches to TTY3 and the rescue prompt names the failure and prints a short journal snippet. Faults inside the watchdog itself are not treated as a desktop death: they are written to a root-only system log, and the TUI **System logs** row shows `error` until you open a static snapshot of the last 12 short records (not a live kernel feed).
* **Crash Recovery Shield:** If launched immediately after a monitored system failure, the utility bypasses the standard menu, shows the crash type plus evidence, and asks you to type `YES` to restore from your automated backup (a single `y` is not enough).
* **Single-Slot Rolling Update Shield:** A pre-invocation hook into the APT package manager. Whenever `apt upgrade` runs or the graphical Update Manager button is clicked, the background subshell terminates stray backend database instances (never a live `timeshift --restore`), clears active file system locks (`/var/run/timeshift.lock`), captures a fresh `SYSTEM_LIFERAFT_ROLLING` snapshot, then purges the previous rolling slot. After the snapshot completes, the storage footprint stays flat. A failed create keeps the old slot.
* **Rescue Hotkeys:** `Ctrl+Alt+X` opens the rescue TUI over a living desktop session. The binder toggles Cinnamon’s custom-keybinding list so the grab actually reloads. If the compositor is frozen, `Ctrl+Alt+F3` is a kernel virtual-terminal switch onto the TTY3 rescue console. If the keyboard is stuck in an X grab, `Alt+SysRq+R` then `Ctrl+Alt+F3` unraws it from the kernel ISR. Uninstall runs `project-anthony-bind-hotkeys --unbind` so `Ctrl+Alt+X` is cleared.
* **Hardware & Kernel Diagnostics:** Real-time motherboard voltage rails (Vcore, 12V, 5V, 3.3V), component thermals, and fan RPMs, plus a scan of the kernel ring buffer for hardware allocation errors and panics.
* **Storage Topography & Diagnostics:** Parses physical disk layers into a column-locked dashboard matching hardware models, capacity, live partition space (`df -h`), and SMART health (`PASSED` / `FAILED`). Unmounted volumes can be mounted first so free space is real before a `ddrescue` clone.
* **Built-in Uninstall:** Type `u` or `uninstall` at the option prompt. From a living desktop the TUI re-invokes teardown with `sudo` instead of exiting; on TTY3 it is already root. Finish work is a detached `systemd-run` unit (not a `/run` script — that filesystem is noexec) that strips package hooks, daemon services, and custom hotkeys. After uninstall the desktop window closes; TTY3 jumps back to the compositor. There is no post-uninstall shell.

---

## Architecture

Source lives in this repo. `./build-deb.sh` copies it into a Debian staging tree and emits the `.deb` under `./build/`. That `build/` tree is generated output, not the source of truth. A sibling folder such as `../ProjectAnthony_1.0-4_amd64/` is an optional staging target for the same builder.

```text
ProjectAnthony/
├── src/
│   ├── liferaft.sh                         # Rescue TUI dispatcher (installed as /usr/local/bin/project-anthony)
│   ├── lib/
│   │   ├── session.sh                    # VT / graphical-session helpers
│   │   ├── auth.sh                       # TTY3 unlock: PAM, U2F, idle lock, USB token
│   │   ├── uninstall.sh                  # Self-cleanup (`project-anthony --uninstall`)
│   │   ├── tui.sh                        # Rescue sub-screens (logs, Timeshift, diagnostics)
│   │   ├── tui-menu.sh                   # Main menu draw + input dispatch
│   │   ├── tui-crash.sh                  # Watchdog crash-restore y/n screen
│   │   └── tui-storage.sh                # Storage matrix, optional volume mount, ddrescue clone (menu option 2)
│   ├── project-anthony-tty.sh            # TTY3 wrapper: exec the password-gated TUI
│   ├── project-anthony-bind-hotkeys.sh   # Cinnamon Ctrl+Alt+X bind/unbind
│   ├── project-anthony-auth.c            # PAM password check for TTY3 unlock
│   ├── project-anthony-auth.py           # Fallback helper if gcc is unavailable
│   ├── project-anthony-restrict-pam-caller.sh  # PAM gate: helper-only caller
│   ├── project-anthony-show-manual.sh    # Opens packaged README.txt (install / menu / --manual)
│   ├── project-anthony-mk-token.sh       # USB rescue token (root CLI only; not in the TUI)
│   ├── anthony-monitor.sh                  # Lightweight crash watchdog daemon
│   ├── liferaft-autosnap.sh              # Single-slot Timeshift rolling snapshot
│   └── README.txt                         # In-app / packaged manual
├── packaging/
│   ├── project-anthony-tty.service       # Owns /dev/tty3 (masks getty@tty3)
│   ├── project-anthony-monitor.service    # Watchdog unit (nice 19, idle I/O)
│   ├── project-anthony-hotkeys.desktop   # Hidden autostart: rebind Ctrl+Alt+X on login
│   ├── project-anthony-first-run.desktop # Hidden autostart: show manual if dpkg had no GUI
│   ├── project-anthony.desktop            # Menu + Desktop: "Project Anthony Rescue"
│   ├── project-anthony-manual.desktop   # Menu + Desktop: "Project Anthony Manual"
│   ├── project-anthony.pam              # /etc/pam.d/project-anthony (TTY3 password)
│   └── project-anthony-u2f.pam          # /etc/pam.d/project-anthony-u2f (optional FIDO2)
├── debian/
│   ├── control                            # Package metadata and Depends
│   ├── postinst                           # Enable units, bind hotkeys, SysRq, APT hook, open manual
│   ├── prerm                             # Stop units, invoke TUI --uninstall
│   └── postrm                            # Package-manager cleanup
├── build-deb.sh                           # Assemble staging tree + .deb (default: ./build/)
├── install.sh                             # Optional source-tree deploy (same hooks as postinst)
├── uninstall.sh                          # Calls project-anthony --uninstall
├── LICENSE
└── README.md
```

Runtime paths after `dpkg -i`:

```text
/usr/local/bin/project-anthony              ← src/liferaft.sh
/usr/local/bin/project-anthony-tty          ← TTY3 ExecStart
/usr/local/bin/project-anthony-monitor      ← watchdog
/usr/local/bin/project-anthony-bind-hotkeys
/usr/local/bin/project-anthony-show-manual
/usr/local/bin/project-anthony-auth
/usr/local/lib/project-anthony/restrict-pam-caller
/usr/local/lib/project-anthony/*.sh         ← sourced TUI/auth/uninstall helpers (644, root-owned)
/usr/local/bin/project-anthony-mk-token
/usr/local/bin/liferaft-autosnap.sh
/lib/systemd/system/project-anthony-tty.service
/lib/systemd/system/project-anthony-monitor.service
/usr/share/applications/project-anthony.desktop
/usr/share/applications/project-anthony-manual.desktop
/usr/share/doc/project-anthony/README.txt
/usr/share/doc/project-anthony/LICENSE
/usr/share/doc/project-anthony/copyright     ← Debian copy of LICENSE
/etc/xdg/autostart/project-anthony-hotkeys.desktop
/etc/xdg/autostart/project-anthony-first-run.desktop
/etc/apt/apt.conf.d/99-liferaft-autosnap    ← written by postinst
/etc/sysctl.d/99-project-anthony-sysrq.conf ← written by postinst
/etc/pam.d/project-anthony                  ← TTY3 password unlock
/etc/pam.d/project-anthony-u2f              ← optional FIDO2/U2F (only used if enrolled)
/etc/project-anthony/rescue-token.sha256    ← optional USB token hash (created by mk-token)
/etc/project-anthony/u2f_mappings           ← optional FIDO2 mappings (created by --u2f)
/var/log/project-anthony/system.log         ← watchdog / internal error log (root-only)
/run/project-anthony-log-alert              ← TUI OK/error flag (ERROR token only)
```

Recovery is two independent entry points, not one program on both layers:

| Layer | Key | What actually runs |
| --- | --- | --- |
| Desktop alive | `Ctrl+Alt+X` | `gnome-terminal` → `project-anthony --run-core-menu` |
| Menu / Desktop | — | "Project Anthony Rescue" and "Project Anthony Manual" |
| Desktop frozen | `Ctrl+Alt+F3` | Kernel VT switch → TTY3 **password unlock**, then rescue TUI |
| Keyboard grabbed | `Alt+SysRq+R`, then F3 | Kernel unraw, then the same TTY3 unlock + TUI |
| Crash watchdog | (automatic) | Monitor → TTY3 crash type + **view recovery options?** (no password). n → desktop. y → unlock, then rescue menu |
| Watchdog self-fault | TUI option `6` | Static snapshot of last 12 records; menu flag `OK` / `error` (no console steal, not a live feed) |

---

## Installation

Project Anthony is distributed as a Debian package.

### 1. Install the `.deb`

Download the latest release from GitHub Releases, or build from this tree:

```bash
sudo apt install ./ProjectAnthony_1.0-4_amd64.deb
```

To build from source:

```bash
./build-deb.sh
sudo apt install ./build/ProjectAnthony_1.0-4_amd64.deb
```

The package manager resolves backend dependencies (`timeshift`, `gddrescue`, `bc`, `smartmontools`, `lm-sensors`, `gnome-terminal`, `kbd`) during install.

### 2. Verify the install

```bash
# Verify the background daemon status
systemctl status project-anthony-monitor.service

# Launch the rescue TUI
project-anthony

# Open the packaged manual
project-anthony --manual

# Test the watchdog y/n prompt (no live crash required)
sudo project-anthony --crash-prompt
```

---

## Uninstall

Open the rescue TUI or press `Ctrl+Alt+X`, type **`u`** or `uninstall` at the option prompt, and confirm. From a living desktop the TUI asks for your `sudo` password, then a detached `systemd-run` unit finishes purge and getty restore so the TUI can exit. After it succeeds the window closes. Uninstall from TTY3 jumps back to the compositor.

Package-manager removal invokes the same teardown:

```bash
sudo apt remove project-anthony
```

---

## Security

TTY3 still runs as root so a frozen machine can be recovered. The crash notice (what died, and whether to view recovery options) is shown without a password; **n** returns to the desktop. The rescue menu stays locked until a local account username and password are accepted. The unlock prompt does not pre-fill the username. After unlock, 60 seconds of idle at a prompt relocks the console (password required again). Failed unlocks wait 10s after tries 1–2, 60s after try 3, 3 minutes after try 4; the fifth failed attempt locks the console until a registered rescue USB is inserted (reboot also clears the count in `/run`). Create that USB from a working desktop with `sudo project-anthony-mk-token /media/YOU/USBNAME` — it is not in the rescue menu. The machine stores only a SHA-256 of `project-anthony.rescue`; `--revoke` invalidates every copy. The TTY3 PAM service is helper-only (not a public password oracle) and does not share the desktop account lockout, so guessing on F3 cannot lock you out of Cinnamon. FIDO2/U2F is optional and off until you install `libpam-u2f` and run `sudo project-anthony-mk-token --u2f` (or `--u2f-import`); enrolled accounts then touch a registered key after the password. Repeat `--u2f alice` / `--u2f bob` for a shared workstation, or the same username again for a spare key. `--u2f-import` copies keys for that username only. `--u2f-disable` turns it off. There is no root shell. Watchdog evidence stays in root-only files (`/run/project-anthony-state`, `/var/log/project-anthony/system.log`); the TUI OK/error flag is world-readable and contains only the word `ERROR`. The TUI will not install packages, will not let `less` spawn a shell, and will only clone to another disk or a folder under `/mnt`, `/media`, `/root`, or `/home`. Type `desktop` at the user prompt to leave without unlocking. Returning to the desktop ends that unlock; the next F3 asks again. Magic SysRq is limited to keyboard unraw (`kernel.sysrq = 16`). `Ctrl+Alt+X` on a living desktop still runs as your user and uses sudo for privileged tools. Uninstall restores the Cinnamon `Ctrl+Alt+X` shortcut to empty via `project-anthony-bind-hotkeys --unbind`.

---

## License

This software is released under the **MIT License**. It is free to use, modify, distribute, or integrate into commercial environments. See the included `LICENSE` file for details.
