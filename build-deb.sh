#!/bin/bash
# =========================================================================
#   PROJECT ANTHONY: DEB BUILDER
# =========================================================================
# Assembles the Debian staging tree from this source repo and builds the
# .deb. Default output is ./build/ next to this script (user-writable).
#
# Usage:
#   ./build-deb.sh
#   sudo ./build-deb.sh /home/johnny/Development/ProjectAnthony_1.0-1_amd64
# =========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG_NAME="ProjectAnthony_1.0-1_amd64"
DEST="${1:-"$ROOT/build/$PKG_NAME"}"
OUT_DEB="$(dirname "$DEST")/${PKG_NAME}.deb"

install_auth_helper() {
    local dest_bin="$1" dest_pam="$2" pamlib=""
    mkdir -p "$(dirname "$dest_bin")" "$(dirname "$dest_pam")"
    cp -f "$ROOT/packaging/project-anthony.pam" "$dest_pam"
    pamlib=$(ls /lib/*/libpam.so.0 /usr/lib/*/libpam.so.0 2>/dev/null | head -n1 || true)
    if command -v gcc >/dev/null && [ -n "$pamlib" ]; then
        gcc -O2 -s -o "$dest_bin" "$ROOT/src/project-anthony-auth.c" "$pamlib"
    else
        cp -f "$ROOT/src/project-anthony-auth.py" "$dest_bin"
    fi
    chmod 755 "$dest_bin"
    chmod 644 "$dest_pam"
}

rm -rf "$DEST"
mkdir -p "$DEST/DEBIAN" \
  "$DEST/usr/local/bin" \
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

chmod 755 "$DEST/DEBIAN/postinst" "$DEST/DEBIAN/prerm" "$DEST/DEBIAN/postrm" \
  "$DEST/usr/local/bin/project-anthony" \
  "$DEST/usr/local/bin/project-anthony-monitor" \
  "$DEST/usr/local/bin/project-anthony-tty" \
  "$DEST/usr/local/bin/project-anthony-bind-hotkeys" \
  "$DEST/usr/local/bin/liferaft-autosnap.sh" \
  "$DEST/usr/local/bin/project-anthony-show-manual" \
  "$DEST/usr/local/bin/project-anthony-auth"
chmod 644 "$DEST/DEBIAN/control" \
  "$DEST/etc/pam.d/project-anthony" \
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
