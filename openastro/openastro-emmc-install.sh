#!/bin/bash
# OpenAstro eMMC auto-installer.
#
# Runs once on first boot when the image is booted from the removable SD card.
# Copies the running OpenAstro system to the eMMC and writes the bootloader, so
# the user can pull the SD and the iMate boots OpenAstro from internal storage.
#
# It replicates the core of Armbian's `armbian-install` (which is interactive)
# using Armbian's own board-specific U-Boot writer (write_uboot_platform).
set -euo pipefail

DONE_MARKER=/etc/openastro-emmc-installed
EMMC=/dev/mmcblk2          # iMate internal eMMC (OrangePi 3 LTS / H6)
MNT=/mnt/openastro-emmc

log() { echo "[openastro-emmc] $*"; }

# --- LED progress signalling -------------------------------------------------
# Red blinking  = installing to eMMC, do NOT remove the SD card.
# Solid green   = done, safe to power off and remove the SD.
# (Anything else / still blinking = not finished or failed - leave the SD in.)
_leds() { ls -d /sys/class/leds/*"$1"* 2>/dev/null; }
led_installing() {
    for l in $(_leds green); do echo none > "$l/trigger" 2>/dev/null || true; echo 0 > "$l/brightness" 2>/dev/null || true; done
    for l in $(_leds red);   do echo timer > "$l/trigger" 2>/dev/null || true; echo 400 > "$l/delay_on" 2>/dev/null || true; echo 400 > "$l/delay_off" 2>/dev/null || true; done
}
led_done() {
    for l in $(_leds red);   do echo none > "$l/trigger" 2>/dev/null || true; echo 0 > "$l/brightness" 2>/dev/null || true; done
    for l in $(_leds green); do echo none > "$l/trigger" 2>/dev/null || true; echo "$(cat "$l/max_brightness" 2>/dev/null || echo 1)" > "$l/brightness" 2>/dev/null || true; done
}

[ -e "$DONE_MARKER" ] && { log "already installed; nothing to do."; exit 0; }

ROOT_SRC=$(findmnt -no SOURCE /)
SD_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"

# Only run when actually booted from the SD (root on mmcblk0), with the eMMC present.
[ "$SD_DISK" = "/dev/mmcblk0" ] || { log "not booted from SD ($SD_DISK); skipping."; exit 0; }
[ -b "$EMMC" ] || { log "no eMMC at $EMMC; skipping."; exit 0; }

# Don't clobber the disk we're running from.
[ "$EMMC" != "$SD_DISK" ] || { log "refusing: eMMC == boot disk."; exit 1; }

log "Installing OpenAstro to $EMMC ..."
led_installing   # red blinking until we finish (or fail, in which case it stays blinking)

# 1. Partition + format the eMMC (single ext4 root, matching Armbian's layout).
umount "${EMMC}"* 2>/dev/null || true
dd if=/dev/zero of="$EMMC" bs=1M count=4 conv=fsync status=none
parted -s "$EMMC" mklabel msdos
parted -s "$EMMC" mkpart primary ext4 4MiB 100%
partprobe "$EMMC"; sleep 1
mkfs.ext4 -qF -L armbi_root "${EMMC}p1"

# 2. Copy the running rootfs (filesystem-level, so size differences are fine).
mkdir -p "$MNT"
mount "${EMMC}p1" "$MNT"
rsync -aHAXx \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/tmp/*' \
  --exclude='/run/*' --exclude='/mnt/*' --exclude='/media/*' --exclude='/lost+found' \
  / "$MNT/"
mkdir -p "$MNT"/{dev,proc,sys,tmp,run,mnt,media}

# 3. Point the eMMC copy at its own root partition (fstab + Armbian boot env).
NEWUUID=$(blkid -s UUID -o value "${EMMC}p1")
sed -i -E "s|^UUID=[^[:space:]]+([[:space:]]+/[[:space:]])|UUID=${NEWUUID}\1|" "$MNT/etc/fstab" || true
if [ -f "$MNT/boot/armbianEnv.txt" ]; then
    if grep -q '^rootdev=' "$MNT/boot/armbianEnv.txt"; then
        sed -i "s|^rootdev=.*|rootdev=UUID=${NEWUUID}|" "$MNT/boot/armbianEnv.txt"
    else
        echo "rootdev=UUID=${NEWUUID}" >> "$MNT/boot/armbianEnv.txt"
    fi
fi

# 4. Make sure the eMMC copy doesn't try to re-install itself.
touch "$MNT$DONE_MARKER"

# 5. Write U-Boot to the eMMC using Armbian's board-specific writer.
DIR=/usr/lib/u-boot
# shellcheck disable=SC1091
source /usr/lib/u-boot/platform_install.sh
write_uboot_platform "$DIR" "$EMMC"

sync
umount "$MNT"
touch "$DONE_MARKER"
led_done   # solid green = safe to power off and remove the SD
log "Done. OpenAstro is on the eMMC - solid green LED: power off and remove the SD card."
