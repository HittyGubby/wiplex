#!/bin/bash
#
# wiplex diagnose - read-only checks. Reports whether this machine can host an
# AP on the same radio as its WiFi client, and why not if it cannot.
#
# SPDX-License-Identifier: MIT
set -u

hr() { printf '%s\n' "-------------------------------------------------------------"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (sudo $0) for complete output." >&2
fi

hr; echo "Wireless hardware"; hr
(lspci -nnk 2>/dev/null | grep -iA3 -E 'network|wireless') || true
(lsusb 2>/dev/null | grep -iE 'wireless|wlan|802.11') || true

detect_wifi_if() {
    local d
    d=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$d" ] && [ -d "/sys/class/net/$d/wireless" ]; then printf '%s' "$d"; return; fi
    for d in /sys/class/net/*; do
        [ -d "$d/wireless" ] || continue
        d=$(basename "$d")
        case "$d" in p2p-dev-*) continue ;; esac
        iw dev "$d" info 2>/dev/null | grep -q "type managed" || continue
        printf '%s' "$d"; return
    done
}
WIFI_IF=$(detect_wifi_if)
echo "WiFi interface: ${WIFI_IF:-<none>}"

hr; echo "Driver"; hr
if [ -n "${WIFI_IF:-}" ]; then
    ls -l "/sys/class/net/$WIFI_IF/device/driver" 2>/dev/null | sed 's#.*/##' || true
fi

hr; echo "Supported interface modes / combinations"; hr
if command -v iw >/dev/null 2>&1; then
    iw list 2>/dev/null | sed -n '/Supported interface modes/,/^\tBand /p' | grep -E '^\s+\*'
    echo
    iw list 2>/dev/null | sed -n '/valid interface combinations/,/^$/p' | grep -E '#\{|\* #'
else
    echo "iw not installed"
fi

hr; echo "Regulatory domain"; hr
iw reg get 2>/dev/null | grep -E 'country|self-managed' || true

hr; echo "5 GHz AP permission"; hr
blocked=0
if iw list 2>/dev/null | grep -q '\[NO_IR\]'; then
    blocked=1
    echo "Some channels are NO-IR. If every 5 GHz channel is NO-IR, an AP cannot"
    echo "start on 5 GHz until the regulatory domain is fixed."
fi
if iw reg get 2>/dev/null | grep -q 'self-managed'; then
    blocked=1
    echo "The wiphy is SELF-MANAGED (e.g. Intel LAR). Userspace 'iw reg set' is"
    echo "ignored, so 5 GHz may stay NO-IR. See kernel/README.md for the optional"
    echo "iwlwifi patch."
fi
[ "$blocked" = 0 ] && echo "No 5 GHz AP blockers detected (ensure COUNTRY is set)."

hr; echo "Port 53 / :53 users"; hr
(ss -lnup 2>/dev/null | grep ':53 ') || echo "nothing listening on :53"
echo "If something already owns *:53, set DNS_MODE=external in /etc/wiplex.conf."

hr; echo "IP forwarding"; hr
sysctl -n net.ipv4.ip_forward 2>/dev/null

hr; echo "Current STA link"; hr
[ -n "${WIFI_IF:-}" ] && iw dev "$WIFI_IF" link 2>/dev/null || true
