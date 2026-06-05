# OpenAstro for the iOptron iMate

<img src="https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png" alt="OpenAstro logo" width="420">

A modern, reliable OS for the **iOptron iMate** (OrangePi 3 LTS / Allwinner H6): an
[Armbian](https://www.armbian.com/)-based **Debian 13 (Trixie)** image with a
**mainline kernel**, the iMate's WiFi access point, full GPIO/power-port support,
and everything ready for [AlpacaBridge](https://github.com/open-astro/AlpacaBridge).

You flash one image to a microSD, boot the iMate once, and it **installs itself to
the internal eMMC** — then you pull the SD and it runs from internal storage. No
SSH, no scripts, no configuration.

## Why a mainline kernel (not the stock BSP)

The stock iMate runs an old (2022) Allwinner BSP kernel that **crashes** under load:
its `cpufreq_dt` driver oopses when the WiFi/BT chip powers on, wedging the CPU
governor so the box hangs (AlpacaBridge can't even bind its port). Armbian's
mainline-based kernel fixes that and is actively maintained — and it **already ships
the Unisoc UWE5622 WiFi/BT driver**, so you get working DVFS (full CPU speed), USB3,
WiFi, and Bluetooth with security updates, on hardware iOptron froze years ago.

## Supported hardware

| Device | SoC | Storage | Status |
|--------|-----|---------|--------|
| iOptron iMate | Allwinner H6 (OrangePi 3 LTS) | 29 GB eMMC | Supported |

## Install

### 1. Download + flash

Grab the latest `openastro-imate.img.xz` from the [Releases](../../releases) page and
flash it to a microSD card (8 GB+) with [Raspberry Pi Imager](https://www.raspberrypi.com/software/),
[balenaEtcher](https://etcher.balena.io/), or `dd`:

```bash
xzcat openastro-imate.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

### 2. Boot once from the SD — it installs itself to the eMMC

Insert the SD, power on the iMate, and **watch the status LED**:

| LED | Meaning |
|-----|---------|
| 🔴 **Red blinking** | Installing to internal storage — **do not remove the SD** |
| 🟢 **Solid green** | Done — power off and remove the SD card |
| 🔴 **Solid red** | Normal operation (powered on) |

### 3. Remove the SD — done

When the LED is **solid green**, power off, **remove the microSD**, and power back on.
The iMate now boots OpenAstro from its internal eMMC. The SD card is no longer needed.

## First boot defaults

| Setting | Value |
|---------|-------|
| Hostname | `openastro` |
| Login | `astro` / `astro` — **change immediately:** `passwd` |
| WiFi AP | `iMate_<MAC>` (5 GHz), password `12345678` |
| AP address | `172.24.1.1` (DHCP for clients) |
| Ethernet | DHCP |
| Status LED | Solid red = on |

Reach it over ethernet (`ssh astro@<ip>`) or by joining the `iMate_…` WiFi.

### Connect to your own network instead (optional)

NetworkManager manages the wired port; to also join an existing WiFi network:

```bash
nmcli dev wifi list
nmcli dev wifi connect "<SSID>" password "<pass>"
```

## Install AlpacaBridge

AlpacaBridge is **not** baked into the image — install it from the OpenAstro apt
repository, the same as on every other platform (see the
[AlpacaBridge install guide](https://github.com/open-astro/AlpacaBridge)):

```bash
sudo apt install alpacabridge
```

`libgpiod` (v2) is already in the image, so the **iMate PowerBox** works as soon as
AlpacaBridge is installed — add it in the AlpacaBridge web UI as a **Switch → iOptron
→ iMate PowerBox** (it drives the DC ports over `/dev/gpiochip1`).

### DC power ports

| Port | Control |
|------|---------|
| DC1, DC2 | Switchable via the AlpacaBridge **iMate PowerBox** Switch device |
| DC3 | Always on (hardwired pass-through) |

## Restore stock iOptron firmware

OpenAstro lives on the eMMC, so to go back to stock use iOptron's official SD card
recovery image: [Restore/Update iMate IMG File](https://www.ioptron.com/Articles.asp?ID=366).
After restoring, the stock login is `imate` / `imate` and the WiFi password is `12345678`.

## Build the image yourself

The release image is built from a stock Armbian *Orange Pi 3 LTS* image plus the
OpenAstro layer. On an **aarch64** host (another arm64 Debian/Armbian box, or the
iMate itself — it's a native chroot, no emulation):

```bash
# 1. grab the upstream Armbian "Orange Pi 3 LTS" (Trixie, current kernel) image
wget -O armbian.img.xz https://dl.armbian.com/orangepi3-lts/Trixie_current_minimal

# 2. bake in the OpenAstro layer and repack
sudo apt install parted e2fsprogs
sudo build/build-openastro-image.sh armbian.img.xz images/openastro-imate.img.xz
```

- [`build/build-openastro-image.sh`](build/build-openastro-image.sh) — customizes the
  Armbian image in a chroot and produces a compressed, flashable `.img.xz`.
- [`openastro/openastro-setup.sh`](openastro/openastro-setup.sh) — the OpenAstro layer
  (WiFi AP, libgpiod/GPIO, dark-for-imaging LEDs, eMMC auto-installer). Idempotent;
  also runnable directly on a booted Armbian board.
- [`openastro/openastro-emmc-install.sh`](openastro/openastro-emmc-install.sh) — the
  first-boot SD→eMMC self-installer.

## Hardware documentation

See [`hardware/imate-h6/`](hardware/imate-h6/) — [`inventory.md`](hardware/imate-h6/inventory.md)
(GPIO map, WiFi/BT chipset, partition layout) and
[`fix-apt-trixie-repos.md`](hardware/imate-h6/fix-apt-trixie-repos.md).

## License

See [LICENSE.md](LICENSE.md).
