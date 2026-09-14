#!/bin/bash
#
# wiplex uninstaller. Removes the userspace parts. Does NOT undo the optional
# kernel tweak (use kernel/restore-iwlwifi.sh for that).
#
# SPDX-License-Identifier: MIT
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
CONF_DST="/etc/wiplex.conf"
UNIT_DST="/etc/systemd/system/wiplex.service"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now wiplex.service 2>/dev/null || true
fi

rm -f "$UNIT_DST"
rm -f "$PREFIX/bin/wiplex"
rm -f /etc/sysctl.d/90-wiplex.conf

if [ "${KEEP_CONFIG:-0}" = "1" ]; then
    echo "Keeping $CONF_DST (KEEP_CONFIG=1)"
else
    rm -f "$CONF_DST"
fi

command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
echo "wiplex uninstalled."
echo "Kernel tweak, if applied, is still active; revert with kernel/restore-iwlwifi.sh"
