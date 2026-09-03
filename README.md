# ⚓ Project Anthony: Automated System Rescue Engine & TUI Life Raft

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-informational)]()
[![Package](https://img.shields.io/badge/package-1.0--2_amd64-blue)]()

**Project Anthony** is an ultra-lightweight, zero-bloat system restoration wrapper and interactive text dashboard designed for Linux clients. Named after the patron saint of lost things, this utility provides an emergency fallback environment to recover systems from corrupt software updates, display server deadlocks, or imminent storage drive failures.

By leveraging native, proven system utilities (`timeshift`, `gddrescue`, `smartctl`, `bc`, `lm-sensors`) Project Anthony guarantees **100% operational resilience** with practically zero system resource overhead.

---

## 🔥 Key Enterprise Features

* **⚡ Proactive Background Crash Interceptor:** Runs a highly optimized systemd daemon that watches for a kernel oops/panic/hung task, a failed display manager, or a dead compositor under a live graphical login. On a hit it switches to TTY3 and the rescue prompt names the failure and prints a short journal snippet so you can see what crashed. Faults inside the watchdog itself are not treated as a desktop death: they are written to a root-only system log, and the TUI **System logs** row shows `error` until you open a static snapshot of the last 12 short records (not a live kernel feed).
* **🛡️ Smart Crash Recovery Shield:** If launched immediately following a monitored system failure, the utility bypasses the standard menu layout, shows the crash type plus evidence, and deploys an instant y/n prompt to restore from your automated backup.
* **⚡ Lock-Breaking Single-Slot Rolling Update Shield:** Injects a secure pre-invocation hook into the APT package manager. Whenever `apt upgrade` runs or the graphical Update Manager button is clicked, the background subshell forcefully terminates stray backend database instances, clears active file system locks (`/var/run/timeshift.lock`), purges the last update's snapshot, and captures a fresh `SYSTEM_LIFERAFT_ROLLING` snapshot. **Your system storage footprint remains perfectly flat.**
* **⌨️ Two-Layer Rescue Hotkeys:** `Ctrl+Alt+X` opens the rescue TUI over a living desktop session. The binder toggles Cinnamon’s custom-keybinding list so the grab actually reloads. `Ctrl+Alt+Del` stays as the stock logout dialog. If the compositor is frozen, `Ctrl+Alt+F3` is a kernel virtual-terminal switch onto the TTY3 rescue console. If the keyboard is stuck in an X grab, `Alt+SysRq+R` then `Ctrl+Alt+F3` unraws it from the kernel ISR. Uninstall runs `project-anthony-bind-hotkeys --unbind` so `Ctrl+Alt+X` is cleared and Cinnamon drops the grab.
* **📊 Hardware & Kernel Diagnostics:** Provides real-time visibility into motherboard voltage rails (Vcore, 12V, 5V, 3.3V), physical component thermals, and fan controller RPMs, while scanning the core kernel ring buffer for critical hardware allocation errors and panics.
* **💾 Smart Storage Topography & Diagnostics:** Parses physical disk layers into a clean, column-locked dashboard matching hardware models, exact capacity dimensions, live partition space tracking (`df -h`), and real-time factory SMART health logs (`🟢 PASSED` / `🔴 FAILED!`).
* **🧼 One-Click Built-in Cleanup:** Includes an explicit self-teardown routine accessible straight from the UI text prompt. Type `u` or `uninstall`, and the script forks a delayed subshell to forcefully strip its own package hooks, daemon services, and custom user hotkey registries completely from system memory.

---

## 🗂️ Architectural Blueprint

Source lives in this repo. `./build-deb.sh` copies it into a Debian staging tree and emits the `.deb` under `./build/`. That `build/` tree is generated output, not the source of truth. A sibling folder such as `../ProjectAnthony_1.0-2_amd64/` is an optional staging target for the same builder.

```text
ProjectAnthony/
├── src/
│   ├── liferaft.sh                         # Rescue TUI (installed as /usr/local/bin/project-anthony)
│   ├── project-anthony-tty.sh            # TTY3 wrapper: exec the password-gated TUI
│   ├── project-anthony-bind-hotkeys.sh   # Cinnamon Ctrl+Alt+X bind/unbind (CAD stays logout)
│   ├── project-anthony-auth.c            # PAM password check for TTY3 unlock
│   ├── project-anthony-auth.py           # Fallback helper if gcc is unavailable
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
| Crash watchdog | (automatic) | Monitor → TTY3 **password unlock**, then crash type + Timeshift y/n |
| Watchdog self-fault | TUI option `6` | Static snapshot of last 12 records; menu flag `OK` / `error` (no console steal, not a live feed) |

`Ctrl+Alt+Del` is left as Cinnamon’s stock logout dialog.

---

## 🚀 Installation & Deployment

Project Anthony is distributed as a native Debian installation package for maximum OS integration and seamless deployment across enterprise networks.

### 📥 1. Installing the `.deb` Package
Download the latest pre-compiled release from the GitHub Releases dashboard and deploy it via standard system channels:

```bash
sudo apt install ./ProjectAnthony_1.0-2_amd64.deb
```

To build that package from this source tree instead:

```bash
./build-deb.sh
sudo apt install ./build/ProjectAnthony_1.0-2_amd64.deb
```

*Note: The package manager will automatically resolve and provision all required backend dependencies (`timeshift`, `gddrescue`, `bc`, `smartmontools`, `lm-sensors`, `gnome-terminal`, `kbd`) seamlessly during this process.*

### 🛠️ 2. Verifying the Deployment
To ensure your core background shields and hotkeys are active, you can query your system setup:

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

## 🧹 Complete System Removal

Unlike modern sandboxed packages that can leave stray configuration files behind on the host OS, Project Anthony can clean up after itself completely. Open the emergency terminal workspace or strike `Ctrl+Alt+X`, type **`u`** or `uninstall` at the option prompt, and confirm the execution.

Alternatively, running standard administrative package manager removal commands will automatically invoke the pre-removal script and revert all settings back to pristine system defaults:

```bash
sudo apt remove project-anthony
```

---

## ⚠️ Security Note

TTY3 still runs as root so a frozen machine can be recovered, but the rescue menu and crash-restore prompt stay locked until a local account password is accepted (your desktop user by default). After unlock, 60 seconds of idle at a prompt relocks the console (password required again). Failed unlocks wait 10s after tries 1–2, 60s after try 3, 3 minutes after try 4; the fifth failed attempt locks the console until a registered rescue USB is inserted (reboot also clears the count in `/run`). Create that USB from a working desktop with `sudo project-anthony-mk-token /media/YOU/USBNAME` — it is not in the rescue menu. The machine stores only a SHA-256 of `project-anthony.rescue`; `--revoke` invalidates every copy. FIDO2/U2F is optional and off until you install `libpam-u2f` and run `sudo project-anthony-mk-token --u2f` (or `--u2f-import`); enrolled accounts then touch a registered key after the password. Repeat `--u2f alice` / `--u2f bob` for a shared workstation, or the same username again for a spare key. `--u2f-disable` turns it off. There is no root shell. Watchdog evidence stays in root-only files (`/run/project-anthony-state`, `/var/log/project-anthony/system.log`); the TUI OK/error flag is world-readable and contains only the word `ERROR`. The TUI will not install packages, will not let `less` spawn a shell, and will only clone to another disk or a folder under `/mnt`, `/media`, `/root`, or `/home`. Type `desktop` at the user prompt to leave without unlocking. Returning to the desktop ends that unlock; the next F3 asks again. Magic SysRq is limited to keyboard unraw (`kernel.sysrq = 16`). `Ctrl+Alt+X` on a living desktop still runs as your user and uses sudo for privileged tools. Uninstall restores the Cinnamon `Ctrl+Alt+X` shortcut to empty via `project-anthony-bind-hotkeys --unbind`.

---

## 📄 License & Enterprise Usage

This software is released under the **MIT License**. It is completely free to use, modify, distribute, or integrate into commercial enterprise environment pipelines for any purpose without any regulatory friction or tracking overhead. See the included `LICENSE` file for further details.
