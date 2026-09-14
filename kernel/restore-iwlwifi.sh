#!/bin/bash
#
# Revert the wiplex iwlwifi build to the distribution's original modules.
#
# SPDX-License-Identifier: MIT
set -euo pipefail

KVER="$(uname -r)"
DST="/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

modprobe -r iwlmvm iwlwifi 2>/dev/null || true

for baz in "iwlwifi.ko:$DST" "iwlmvm.ko:$DST/mvm"; do
    name="${baz%%:*}"; dir="${baz##*:}"
    if [ -f "$dir/$name.zst.orig" ]; then
        rm -f "$dir/$name"
        mv "$dir/$name.zst.orig" "$dir/$name.zst"
        echo "restored $dir/$name.zst"
    else
        echo "no backup for $dir/$name (skipped)"
    fi
done

depmod -a
modprobe iwlwifi 2>/dev/null || true
modprobe iwlmvm 2>/dev/null || true
echo "Original modules restored."
