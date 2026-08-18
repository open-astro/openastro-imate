# iOptron iMate - Hardware Inventory

## Overview

| Field | Value |
|-------|-------|
| Device | iOptron iMate |
| Board | OrangePi 3 LTS |
| SoC | Allwinner H6 (sun50i-h6) |
| CPU | 4× Cortex-A53 @ 1.8 GHz (ARMv8-A / aarch64) |
| RAM | ~2 GB |
| Storage | 29.1 GB eMMC (mmcblk2) |
| WiFi | Unisoc UWE5622 (chip ID 0x2355b001), driver: sprdwl_ng, 802.11ac 5 GHz |
| Ethernet | Gigabit (eth0) |
| Bluetooth | Yes (BlueZ service running) |
| GPIO | WiringPi-based, pins 2 and 6 used for power box relay control |
| Serial | ttyS0–ttyS5 available; UART3 enabled via device-tree overlay |
| I2C | i2c-0 through i2c-3 available; i2c0 enabled via device-tree overlay (DS1307 RTC commented out in rc.local) |
| USB | 3 physical ports (1x USB 3.0, 2x USB 2.0), 1x OTG (musb-hdrc) |

## Stock OS

| Field | Value |
|-------|-------|
| OS | Debian 11 (Bullseye) |
| Kernel | 5.16.17-sun50iw6 (Allwinner BSP) |
| Architecture | aarch64 |
| Display Manager | LightDM |
| Remote Desktop | NoMachine (nxserver) |
| Root filesystem | ext4 on mmcblk2p1 |
| Boot | U-Boot, orangepiEnv.txt config |
| Display mode | 1920×1080p60 |

## Partition Layout

Single-partition layout on eMMC:

```
mmcblk2       29.1G  disk
└─mmcblk2p1   28.8G  part  /       (ext4)
mmcblk2boot0     4M  disk  (eMMC boot partition 0)
mmcblk2boot1     4M  disk  (eMMC boot partition 1)
```

Swap is zram-based (zram0 = ~992 MB swap, zram1 = 50 MB for /var/log).

## Network Configuration

### WiFi Access Point (hostapd)

The iMate runs as a WiFi AP on wlan0:

- **SSID (stock firmware):** `iMate_85F2D7` (derived from last 3 octets of wlan0 MAC); OpenAstro uses `OpenAstro-XXXX` (last 4 hex)
- **Security:** WPA2-PSK, default passphrase `12345678`
- **Mode:** 802.11ac, channel 40 (5 GHz)
- **Subnet:** 172.24.1.0/24
- **AP address:** 172.24.1.1

### DHCP (dnsmasq)

- Interface: wlan0
- Range: 172.24.1.50–172.24.1.150
- Lease: 12 hours
- DNS: forwarded to 8.8.8.8

### NAT / Routing

iptables masquerade from wlan0 → eth0, allowing WiFi clients to reach the internet through the ethernet uplink. Restored on boot via `orangepi-restore-iptables.service`.

### Ethernet

Managed by NetworkManager, gets DHCP from the local network.

## GPIO / Power Box

Two GPIO-controlled relay outputs for the iMate PowerBox accessory:

| Port | WiringPi Pin | GPIO | Physical Pin | State on Boot |
|------|-------------|------|-------------|---------------|
| DC1 | 2 | 118 (PWM.0) | 7 | ON (high) |
| DC2 | 6 | 114 (PD18) | 12 | ON (high) |
| DC3 | - | - | - | Always on (passthrough) |

Set to output mode and driven high in `/etc/rc.local`.
Controlled interactively via `/home/imate/imatepowerbox.sh`.

## WiFi / Bluetooth

- **Chip:** Unisoc UWE5622 (Spreadtrum/Marlin2)
- **Chip ID:** 0x2355b001
- **Interface:** SDIO
- **WiFi driver:** `sprdwl_ng` (out-of-tree UWE5622). Not in *vanilla* mainline, but **bundled in Armbian's mainline-based kernel** (the basis for OpenAstro), so a modern kernel keeps WiFi.
- **WiFi firmware:** `/lib/firmware/wcnmodem.bin`, `/lib/firmware/wifi_2355b001_1ant.ini`
- **BT driver:** `sprdbt_tty`
- **Helper module:** `sunxi_addr` (address mapping for SDIO)
- **GPIO chips (stock BSP):** gpiochip0 (main), gpiochip352 (r_pio/PL). On the OpenAstro mainline kernel the numbering differs: **gpiochip1 = main bank** (`300b000.pinctrl`, 256 lines - where DC1=118/DC2=114 live) and gpiochip0 = `7022000.pinctrl` (r_pio/PL, 64 lines).
- **AP mode:** Confirmed working (hostapd, 802.11ac, 5 GHz channel 40)
- **Station mode:** Requires testing on new OS

**Note (OpenAstro):** Armbian's mainline-based kernel also ships the UWE5622 driver (`drivers/net/wireless/uwe5622` → `sprdwl_ng` + `sprdbt_tty`) plus firmware and an auto-load config, so OpenAstro runs a mainline kernel and keeps WiFi/BT. Both AP mode (NetworkManager hotspot with the PSK-only dispatcher hook; firmware rejects PSK-SHA256 in the RSN IE) and station mode (5 GHz WPA2 join, clean PTK/GTK install) are confirmed on hardware (2026-08-17). No AP+STA concurrency, and no scanning while beaconing. The rest of this file documents the original **stock BSP** system for reference.

## FTDI Library

FTDI D2XX library installed at `/usr/local/lib/libftd2xx.so.1.4.27` with headers at `/usr/local/include/ftd2xx.h`. This is likely used for USB-to-serial communication with the mount via an FTDI chip (no FTDI device was present on USB at time of inventory - mount was not connected).

## iPolar (Polar Alignment Server)

Located at `/home/imate/ipolar/publish/`:

| File | Description |
|------|-------------|
| `iPolarServer` | aarch64 ELF binary (stripped), the polar alignment camera server |
| `libcvextern.so` | OpenCV wrapper library (~62 MB, not stripped) |
| `iPolarServer.ini` | Config file (contains single value: `6`) |
| `ioptronlogo.png` | 6060×6060 iOptron logo |

## TCP Control Server (Dart)

A Dart-based TCP server listens on port 3000 for remote commands (GPIO control, time setting, etc.). This is the primary control interface used by iOptron's apps.

| Field | Value |
|-------|-------|
| Service | `tcp_server.service` |
| Runtime | Dart SDK 3.7.3 (`/home/imate/dart-sdk/`) |
| Source | `/home/imate/my_tcp_server/tcp_server.dart` |
| Port | 3000 |
| User | imate |

## Running Services (Stock)

Key services beyond standard Debian:

| Service | Purpose |
|---------|---------|
| hostapd | WiFi access point |
| dnsmasq | DHCP/DNS for WiFi clients |
| NetworkManager | Ethernet management |
| nxserver | NoMachine remote desktop |
| lightdm | Display manager |
| bluetooth | Bluetooth stack |
| chrony | NTP time sync |
| strongswan + xl2tpd | VPN (IPsec/L2TP) - purpose unclear |
| cups | Print server - likely unused |
| ssh | OpenSSH server |
| smartmontools | Disk health monitoring |
| tcp_server | Dart TCP control server (port 3000) - iOptron app interface |
| haveged | Entropy daemon |

## Boot Configuration (orangepiEnv.txt)

```
verbosity=1
bootlogo=false
console=both
disp_mode=1920x1080p60
overlay_prefix=sun50i-h6
rootdev=UUID=<device-specific>
rootfstype=ext4
overlays=i2c0 uart3
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
```

## iMate Scripts

| Script | Purpose |
|--------|---------|
| `imatemodAP.sh` | Sets hostapd SSID from wlan0 MAC address |
| `imatepowerbox.sh` | Interactive menu for GPIO power box relay control |
| `imatesettime.sh` | Manual date/time setter |
| `imate_write_EMMC.sh` | Wipes and reinstalls eMMC via `nand-sata-install` |

## Credentials

| User | Password |
|------|----------|
| imate | imate |
