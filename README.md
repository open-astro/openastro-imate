# OpenAstro for the iOptron iMate

<img src="https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png" alt="OpenAstro logo" width="420">

OpenAstro OS for the **iOptron iMate** (OrangePi 3 LTS / Allwinner H6): an
[Armbian](https://www.armbian.com/)-based **Debian 13 (Trixie)** image on a
mainline kernel - with the iMate's WiFi access point, full GPIO/power-port
support, and [AlpacaBridge](https://github.com/open-astro/AlpacaBridge)
preinstalled and ready to use.

You flash one image to a microSD, boot the iMate once, and it **installs itself
to the internal eMMC** - then you pull the SD and it runs from internal storage.
No SSH, no scripts, no configuration.

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

### 2. First boot - from the SD card (installs to eMMC)

Insert the SD card, power on the iMate, and **watch the status LED**:

| LED | Meaning |
|-----|---------|
| 🔴🟢 **Red & green blinking** | Booting from the SD card - **do not remove the SD** |
| 🔴 **Solid red** | Installing to eMMC - **do not remove the SD** |
| 🟢 **Solid green** | Install complete - power off and remove the SD card |

### 3. Second boot - without the SD card

With the SD card removed, power the iMate back on:

| LED | Meaning |
|-----|---------|
| 🔴🟢 **Red & green blinking** | Booting from the device (eMMC) |
| 🔴 **Solid red** | Normal operation (powered on) |

### 3. Remove the SD - done

When the LED is **solid green**, power off, **remove the microSD**, and power back on.
The iMate now boots OpenAstro from its internal eMMC. The SD card is no longer needed.

## First boot defaults

| Setting | Value |
|---------|-------|
| Hostname | `openastro` |
| Login | `astro` / `astro` - **change immediately:** `passwd` |
| WiFi AP | `OpenAstro-XXXX` (5 GHz, XXXX = last 4 hex of the WiFi MAC), password `12345678` |
| AP address | `172.24.1.1` (DHCP for clients) |
| Ethernet | DHCP |
| Status LED | Solid red = on |

Reach it over ethernet (`ssh astro@<ip>`) or by joining the `OpenAstro-…` WiFi.

### Connect to your own network instead (optional)

NetworkManager manages both the wired port and WiFi. The easiest way to join
an existing WiFi network is the **WiFi** card in the AlpacaBridge web UI
(Server Info tab); `nmcli` works too:

```bash
nmcli dev wifi list
nmcli dev wifi connect "<SSID>" password "<pass>"
```

The iMate has a single WiFi radio with no AP+client concurrency: while it is
joined to your network the hotspot is down, and NetworkManager falls back to
the hotspot automatically when your network is out of range (e.g. at a dark
site). Note the radio also cannot scan while the hotspot is running, so
network lists are gathered while the hotspot is briefly down.

## AlpacaBridge

AlpacaBridge comes **preinstalled** (from the OpenAstro apt repository, which is
configured in the image - `apt update && apt upgrade` gets you future releases).
The appliance works out of the box, even at a dark site with no internet.

The hotspot is a NetworkManager profile (`OpenAstro-AP`), so the AlpacaBridge
**Personal Hotspot** card manages it natively - name, password, band and
on/off all work from the web UI, same as on the other OpenAstro boards. (The
iMate's UWE5622 firmware rejects the PSK-SHA256 key-management variant that
NetworkManager advertises by default; the image ships a dispatcher hook,
`/etc/NetworkManager/dispatcher.d/90-uwe5622-psk-only`, that pins the hotspot
to plain WPA2-PSK - without it, clients get stuck in a password loop.)

`libgpiod` (v2) is in the image too, so the **iMate PowerBox** works immediately -
add it in the AlpacaBridge web UI as a **Switch → iOptron → iMate PowerBox**
(it drives the DC ports over `/dev/gpiochip1`).

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
iMate itself - it's a native chroot, no emulation):

```bash
# 1. grab the upstream Armbian "Orange Pi 3 LTS" (Trixie, current kernel) image
wget -O armbian.img.xz https://dl.armbian.com/orangepi3-lts/Trixie_current_minimal

# 2. bake in the OpenAstro layer and repack
sudo apt install parted e2fsprogs
sudo build/build-openastro-image.sh armbian.img.xz images/openastro-imate.img.xz
```

- [`build/build-openastro-image.sh`](build/build-openastro-image.sh) - customizes the
  Armbian image in a chroot and produces a compressed, flashable `.img.xz`.
- [`openastro/openastro-setup.sh`](openastro/openastro-setup.sh) - the OpenAstro layer
  (NetworkManager WiFi + hotspot, libgpiod/GPIO, dark-for-imaging LEDs, eMMC auto-installer). Idempotent;
  also runnable directly on a booted Armbian board.
- [`openastro/openastro-emmc-install.sh`](openastro/openastro-emmc-install.sh) - the
  first-boot SD→eMMC self-installer.

## Hardware documentation

See [`hardware/imate-h6/inventory.md`](hardware/imate-h6/inventory.md) - GPIO map,
WiFi/BT chipset, and partition layout.

## License

See [LICENSE.md](LICENSE.md).
