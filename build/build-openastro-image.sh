#!/bin/bash
# Build the OpenAstro iMate OS image.
#
# Customizes a stock Armbian "Orange Pi 3 LTS" image by running the OpenAstro
# layer (openastro/openastro-setup.sh) inside a chroot, then repacks it as a
# compressed, flashable image. The build host must be aarch64 (native chroot —
# no qemu), e.g. another Armbian/Debian arm64 box or the iMate itself.
#
# Usage: sudo build/build-openastro-image.sh <stock-armbian.img[.xz]> [output.img.xz]
#
# AlpacaBridge is NOT baked in — users apt-install it after flashing.
set -euo pipefail

REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?usage: $0 <stock-armbian.img[.xz]> [output.img.xz]}"
OUT="${2:-$REPODIR/images/openastro-imate.img.xz}"
WORK="$(mktemp -d)"
IMG="$WORK/openastro.img"
MNT="$WORK/rootfs"
LOOP=""

log() { echo "[build] $*"; }
cleanup() {
    set +e
    umount -lf "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" 2>/dev/null
    mountpoint -q "$MNT" && umount -lf "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "Build host must be aarch64 (native chroot)." >&2; exit 1; }

log "Staging source image..."
case "$SRC" in
    *.xz) xz -dc "$SRC" > "$IMG" ;;
    *)    cp --reflink=auto "$SRC" "$IMG" ;;
esac

# Grow the image so there's room to install packages in the chroot. The unused
# space is zeroed and xz-compressed away at the end, so the .img.xz stays small.
truncate -s +700M "$IMG"
LOOP=$(losetup -fP --show "$IMG")
parted -s "$LOOP" resizepart 1 100%
partprobe "$LOOP" 2>/dev/null || true; sleep 1
e2fsck -fy "${LOOP}p1" >/dev/null 2>&1 || true
resize2fs "${LOOP}p1" >/dev/null 2>&1
mkdir -p "$MNT"
mount "${LOOP}p1" "$MNT"
log "rootfs free space: $(df -h "$MNT" | awk 'NR==2{print $4}')"

# chroot plumbing (native aarch64, networked via the host)
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount -o bind /dev "$MNT/dev"
mount -t devpts devpts "$MNT/dev/pts"
# The image's /etc/resolv.conf is a dangling symlink (resolved at runtime), so
# replace it with a real one for the chroot's apt, and restore it afterwards.
RESOLV_LINK=$(readlink "$MNT/etc/resolv.conf" 2>/dev/null || true)
rm -f "$MNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || echo 'nameserver 8.8.8.8' > "$MNT/etc/resolv.conf"

install -d "$MNT/opt/openastro"
install -m 0755 "$REPODIR/openastro/openastro-setup.sh" \
                "$REPODIR/openastro/openastro-emmc-install.sh" "$MNT/opt/openastro/"

log "Running openastro-setup.sh in chroot..."
chroot "$MNT" /bin/bash -c "cd /opt/openastro && ./openastro-setup.sh"

log "Cleaning image..."
chroot "$MNT" /bin/bash -c "apt-get clean" || true
rm -rf "$MNT"/var/lib/apt/lists/* "$MNT"/var/log/* "$MNT"/tmp/* 2>/dev/null || true
rm -f "$MNT"/etc/ssh/ssh_host_*           # regenerated per-device on first boot
: > "$MNT/etc/machine-id" 2>/dev/null || true
rm -f "$MNT"/etc/openastro-emmc-installed # ensure the self-installer runs on first boot
rm -f "$MNT/etc/resolv.conf"              # don't ship the build host's DNS
[ -n "${RESOLV_LINK:-}" ] && ln -sf "$RESOLV_LINK" "$MNT/etc/resolv.conf"  # restore runtime symlink

log "Zero-filling free space (so the image compresses small)..."
dd if=/dev/zero of="$MNT/ZERO.fill" bs=4M status=none 2>/dev/null || true
sync; rm -f "$MNT/ZERO.fill"; sync

umount -lf "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys"
umount "$MNT"
losetup -d "$LOOP"; LOOP=""

log "Compressing -> $OUT"
mkdir -p "$(dirname "$OUT")"
xz -T0 -6 -c "$IMG" > "$OUT"
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
log "Done: $OUT ($(du -h "$OUT" | cut -f1))"
