#!/bin/bash
#
# wiplex installer
# Installs the userspace parts (hostapd + dnsmasq + nftables). The optional
# kernel tweak for Intel/LAR cards is NOT installed automatically - see
# kernel/README.md.
#
# SPDX-License-Identifier: MIT
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
CONF_DST="/etc/wiplex.conf"
UNIT_DST="/etc/systemd/system/wiplex.service"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

install_pkgs() {
    local pkgs=(hostapd dnsmasq nftables iw)
    if command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm "${pkgs[@]}"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y "${pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}"
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install "${pkgs[@]}"
    else
        echo "Unknown package manager. Install manually: ${pkgs[*]}" >&2
    fi
}

echo "==> Installing dependencies"
install_pkgs

echo "==> Installing /usr/local/bin/wiplex"
install -Dm755 "$SRC/bin/wiplex" "$PREFIX/bin/wiplex"

echo "==> Installing systemd unit"
install -Dm644 "$SRC/systemd/wiplex.service" "$UNIT_DST"
install -Dm755 "$SRC/systemd/wiplex-sleep" /usr/lib/systemd/system-sleep/wiplex

if [ -f "$CONF_DST" ]; then
    echo "==> Keeping existing $CONF_DST"
else
    echo "==> Installing example config to $CONF_DST"
    install -Dm644 "$SRC/etc/wiplex.conf.example" "$CONF_DST"
    echo "    Edit it (SSID/PSK/interfaces) before starting the service."
fi

echo "==> Enabling IP forwarding persistently"
cat > /etc/sysctl.d/90-wiplex.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl -qw net.ipv4.ip_forward=1

if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^wifi-hotspot.service'; then
        echo
        echo "WARNING: an existing 'wifi-hotspot.service' was found."
        echo "Disable it to avoid both services managing the same radio:"
        echo "    sudo systemctl disable --now wifi-hotspot.service"
    fi
    systemctl daemon-reload
    systemctl enable wiplex.service
    echo
    echo "Installed. Review $CONF_DST, then:"
    echo "    sudo systemctl start wiplex"
    echo "    systemctl status wiplex"
else
    echo "systemd not found; start $PREFIX/bin/wiplex manually."
fi

echo
echo "Diagnostics: sudo $SRC/tools/diagnose.sh"
echo "Kernel tweak (Intel/LAR only): see $SRC/kernel/README.md"
