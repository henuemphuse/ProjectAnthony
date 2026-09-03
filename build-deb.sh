#!/bin/bash
# =========================================================================
#   PROJECT ANTHONY: DEB BUILDER
# =========================================================================
# Assembles the Debian staging tree from this source repo and builds the
# .deb. Default output is ./build/ next to this script (user-writable).
#
# Usage:
#   ./build-deb.sh
#   sudo ./build-deb.sh /home/johnny/Development/ProjectAnthony_1.0-3_amd64
# =========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG_NAME="ProjectAnthony_1.0-3_amd64"
DEST="${1:-"$ROOT/build/$PKG_NAME"}"
OUT_DEB="$(dirname "$DEST")/${PKG_NAME}.deb"

install_auth_helper() {
    local dest_bin="$1" dest_pam="$2" pamlib="" dest_u2f
    dest_u2f="$(dirname "$dest_pam")/project-anthony-u2f"
    mkdir -p "$(dirname "$dest_bin")" "$(dirname "$dest_pam")"
    cp -f "$ROOT/packaging/project-anthony.pam" "$dest_pam"
    cp -f "$ROOT/packaging/project-anthony-u2f.pam" "$dest_u2f"
    pamlib=$(ls /lib/*/libpam.so.0 /usr/lib/*/libpam.so.0 2>/dev/null | head -n1 || true)
    if command -v gcc >/dev/null && [ -n "$pamlib" ]; then
        gcc -O2 -s -o "$dest_bin" "$ROOT/src/project-anthony-auth.c" "$pamlib"
    else
        cp -f "$ROOT/src/project-anthony-auth.py" "$dest_bin"
    fi
    chmod 700 "$dest_bin"
    chmod 644 "$dest_pam" "$dest_u2f"
}

rm -rf "$DEST"
mkdir -p "$DEST/DEBIAN" \
  "$DEST/usr/local/bin" \
  "$DEST/usr/local/lib/project-anthony" \
  "$DEST/usr/share/applications" \
  "$DEST/usr/share/doc/project-anthony" \
  "$DEST/etc/xdg/autostart" \
  "$DEST/etc/pam.d" \
  "$DEST/lib/systemd/system"

cp -f "$ROOT/debian/control" "$DEST/DEBIAN/control"
cp -f "$ROOT/debian/postinst" "$DEST/DEBIAN/postinst"
cp -f "$ROOT/debian/prerm" "$DEST/DEBIAN/prerm"
cp -f "$ROOT/debian/postrm" "$DEST/DEBIAN/postrm"
cp -f "$ROOT/src/liferaft.sh" "$DEST/usr/local/bin/project-anthony"
cp -f "$ROOT/src/anthony-monitor.sh" "$DEST/usr/local/bin/project-anthony-monitor"
cp -f "$ROOT/src/project-anthony-tty.sh" "$DEST/usr/local/bin/project-anthony-tty"
cp -f "$ROOT/src/project-anthony-bind-hotkeys.sh" "$DEST/usr/local/bin/project-anthony-bind-hotkeys"
cp -f "$ROOT/src/liferaft-autosnap.sh" "$DEST/usr/local/bin/liferaft-autosnap.sh"
cp -f "$ROOT/src/project-anthony-show-manual.sh" "$DEST/usr/local/bin/project-anthony-show-manual"
cp -f "$ROOT/src/project-anthony-mk-token.sh" "$DEST/usr/local/bin/project-anthony-mk-token"
cp -f "$ROOT/src/project-anthony-restrict-pam-caller.sh" \
  "$DEST/usr/local/lib/project-anthony/restrict-pam-caller"
for lib in session.sh auth.sh uninstall.sh tui.sh tui-storage.sh tui-crash.sh tui-menu.sh; do
    cp -f "$ROOT/src/lib/$lib" "$DEST/usr/local/lib/project-anthony/$lib"
done
cp -f "$ROOT/src/README.txt" "$DEST/usr/share/doc/project-anthony/README.txt"
cp -f "$ROOT/LICENSE" "$DEST/usr/share/doc/project-anthony/LICENSE"
cp -f "$ROOT/LICENSE" "$DEST/usr/share/doc/project-anthony/copyright"
cp -f "$ROOT/packaging/project-anthony.desktop" "$DEST/usr/share/applications/project-anthony.desktop"
cp -f "$ROOT/packaging/project-anthony-manual.desktop" "$DEST/usr/share/applications/project-anthony-manual.desktop"
cp -f "$ROOT/packaging/project-anthony-hotkeys.desktop" "$DEST/etc/xdg/autostart/project-anthony-hotkeys.desktop"
cp -f "$ROOT/packaging/project-anthony-first-run.desktop" "$DEST/etc/xdg/autostart/project-anthony-first-run.desktop"
cp -f "$ROOT/packaging/project-anthony-monitor.service" "$DEST/lib/systemd/system/project-anthony-monitor.service"
cp -f "$ROOT/packaging/project-anthony-tty.service" "$DEST/lib/systemd/system/project-anthony-tty.service"
install_auth_helper "$DEST/usr/local/bin/project-anthony-auth" "$DEST/etc/pam.d/project-anthony"

chmod 755 "$DEST/usr/local/lib/project-anthony"
chmod 755 "$DEST/DEBIAN/postinst" "$DEST/DEBIAN/prerm" "$DEST/DEBIAN/postrm" \
  "$DEST/usr/local/bin/project-anthony" \
  "$DEST/usr/local/bin/project-anthony-monitor" \
  "$DEST/usr/local/bin/project-anthony-tty" \
  "$DEST/usr/local/bin/project-anthony-bind-hotkeys" \
  "$DEST/usr/local/bin/liferaft-autosnap.sh" \
  "$DEST/usr/local/bin/project-anthony-show-manual" \
  "$DEST/usr/local/bin/project-anthony-mk-token" \
  "$DEST/usr/local/lib/project-anthony/restrict-pam-caller"
chmod 644 \
  "$DEST/usr/local/lib/project-anthony/session.sh" \
  "$DEST/usr/local/lib/project-anthony/auth.sh" \
  "$DEST/usr/local/lib/project-anthony/uninstall.sh" \
  "$DEST/usr/local/lib/project-anthony/tui.sh" \
  "$DEST/usr/local/lib/project-anthony/tui-storage.sh" \
  "$DEST/usr/local/lib/project-anthony/tui-crash.sh" \
  "$DEST/usr/local/lib/project-anthony/tui-menu.sh"
chmod 700 "$DEST/usr/local/bin/project-anthony-auth"
chmod 644 "$DEST/DEBIAN/control" \
  "$DEST/etc/pam.d/project-anthony" \
  "$DEST/etc/pam.d/project-anthony-u2f" \
  "$DEST/usr/share/applications/project-anthony.desktop" \
  "$DEST/usr/share/applications/project-anthony-manual.desktop" \
  "$DEST/etc/xdg/autostart/project-anthony-hotkeys.desktop" \
  "$DEST/etc/xdg/autostart/project-anthony-first-run.desktop" \
  "$DEST/lib/systemd/system/project-anthony-monitor.service" \
  "$DEST/lib/systemd/system/project-anthony-tty.service" \
  "$DEST/usr/share/doc/project-anthony/README.txt" \
  "$DEST/usr/share/doc/project-anthony/LICENSE" \
  "$DEST/usr/share/doc/project-anthony/copyright"

mkdir -p "$(dirname "$OUT_DEB")"
dpkg-deb --build "$DEST" "$OUT_DEB"
echo "✔ Built $OUT_DEB"
dpkg-deb -I "$OUT_DEB"
