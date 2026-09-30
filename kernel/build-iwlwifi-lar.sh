#!/bin/bash
#
# Build a locally patched iwlwifi/iwlmvm for the RUNNING kernel so that an
# Intel card with LAR stops marking its wiphy self-managed and instead follows
# the standard cfg80211 regulatory domain. This is what allows a 5 GHz AP.
#
# Re-run this after every kernel upgrade.
#
# Overrides:
#   SRC_VER=x.y.z   force the kernel.org source version (default: autodetect)
#   SRC_URL=<url>   explicit source tarball URL (any of .tar.xz/.tar.gz)
#   JOBS=n          build parallelism (default: nproc)
#
# SPDX-License-Identifier: MIT
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/iwlwifi-lar-disable.patch"
CACHE="${WIPLEX_KERNEL_CACHE:-/var/cache/wiplex-kernel}"

KVER="$(uname -r)"
BUILD="/lib/modules/${KVER}/build"
DST="/lib/modules/${KVER}/kernel/drivers/net/wireless/intel/iwlwifi"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
[ -d "$BUILD" ] || { echo "ERROR: kernel headers for $KVER not installed" >&2; exit 1; }
[ -f "$DST/iwlwifi.ko.zst" ] || [ -f "$DST/iwlwifi.ko" ] || {
    echo "ERROR: iwlwifi not found for $KVER - is this an Intel WiFi system?" >&2; exit 1; }

KREL="$(cat "$BUILD/include/config/kernel.release" 2>/dev/null || echo "$KVER")"
VER="${SRC_VER:-$(echo "$KREL" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?')}"
[ -n "$VER" ] || { echo "ERROR: cannot determine source version from '$KREL'" >&2; exit 1; }
MAJ="${VER%%.*}"

# Candidate source URLs (first that downloads wins). SRC_URL overrides all.
URLS=()
if [ -n "${SRC_URL:-}" ]; then
    URLS+=("$SRC_URL")
elif [ "${VER#*-rc}" != "$VER" ]; then
    # Mainline RC: cdn.kernel.org has no testing/ tree, so use the git tag
    # archive. GitHub first (reliable); kernel.org tarball service as fallback.
    VER="${VER/\.0-rc/-rc}"
    URLS+=("https://github.com/torvalds/linux/archive/refs/tags/v${VER}.tar.gz")
    URLS+=("https://git.kernel.org/torvalds/t/linux-${VER}.tar.gz")
else
    case "$VER" in *.[0-9]0) VER="${VER%.0}" ;; esac
    URLS+=("https://cdn.kernel.org/pub/linux/kernel/v${MAJ}.x/linux-${VER}.tar.xz")
fi

echo "Kernel : $KVER"
echo "Source : linux-${VER}"

mkdir -p "$CACHE"
TARBALL=""
for u in "${URLS[@]}"; do
    TARBALL="$(basename "$u")"
    if [ -s "$CACHE/$TARBALL" ]; then
        echo "Using cached $TARBALL"
        break
    fi
    echo "Downloading $u"
    if curl -L --fail --speed-limit 2048 --speed-time 30 \
            -o "$CACHE/$TARBALL" "$u"; then
        break
    fi
    echo "  mirror failed, trying next"
    rm -f "$CACHE/$TARBALL"
    TARBALL=""
done
if [ -z "$TARBALL" ] || [ ! -s "$CACHE/$TARBALL" ]; then
    echo "ERROR: could not download kernel source for $VER." >&2
    echo "Set SRC_URL=<tarball-url> to use a specific source." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Extracting driver sources"
tar -xf "$CACHE/$TARBALL" -C "$WORK"
SRC="$WORK/linux-${VER}/drivers/net/wireless/intel/iwlwifi"
if [ ! -d "$SRC" ]; then
    SRC="$(find "$WORK" -maxdepth 6 -type d \
        -path '*/drivers/net/wireless/intel/iwlwifi' 2>/dev/null | head -1)"
fi
[ -n "$SRC" ] && [ -d "$SRC" ] || {
    echo "ERROR: driver source not found under $WORK" >&2; exit 1; }

echo "Applying patch"
if ! patch -p1 -d "$SRC" --fuzz=3 < "$PATCH"; then
    echo "ERROR: patch did not apply to $VER - upstream code changed." >&2
    echo "Inspect $PATCH and update it for this kernel." >&2
    exit 1
fi

echo "Building modules"
make -C "$BUILD" M="$SRC" modules -j"${JOBS:-$(nproc)}"

echo "Installing (original modules backed up as *.ko.zst.orig)"
for f in "iwlwifi.ko:iwlwifi.ko" "mvm/iwlmvm.ko:iwlmvm.ko"; do
    src="$SRC/${f%%:*}"; baz="${f##*:}"
    dstdir="$DST/$(dirname "${f%%:*}")"; [ "$dstdir" = "$DST/." ] && dstdir="$DST"
    if [ -f "$dstdir/$baz.zst" ] && [ ! -f "$dstdir/$baz.zst.orig" ]; then
        cp -a "$dstdir/$baz.zst" "$dstdir/$baz.zst.orig"
    fi
    cp "$src" "$dstdir/$baz"
    rm -f "$dstdir/$baz.zst"
done
depmod -a

echo
echo "Done. Reboot, or reload now with:"
echo "    modprobe -r iwlmvm iwlwifi && modprobe iwlwifi && modprobe iwlmvm"
