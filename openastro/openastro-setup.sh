#!/bin/bash
# OpenAstro layer for the iOptron iMate (OrangePi 3 LTS / Allwinner H6).
#
# This turns a stock Armbian "Orange Pi 3 LTS" image (Debian 13 Trixie, mainline
# kernel) into the OpenAstro OS for the iMate: NetworkManager-native WiFi (the
# OpenAstro-XXXX hotspot and home-network joins, both managed from AlpacaBridge),
# libgpiod v2 + GPIO plumbing for the iMate PowerBox, dark-for-imaging LEDs, and
# a self-install-to-eMMC flow. AlpacaBridge is preinstalled from the OpenAstro
# apt repository (apt.openastro.net), so the appliance works out of the box even
# at a dark site with no internet.
#
# Why Armbian instead of the old stock-BSP overlay: the stock 5.16 Allwinner BSP
# kernel OOPSes in cpufreq_dt when the WCN/WiFi chip powers on, wedging the box.
# Armbian's mainline kernel fixes cpufreq AND already ships the UWE5622 WiFi/BT
# driver, so we inherit a maintained kernel with working DVFS, USB3, WiFi and BT.
#
# Idempotent: safe to re-run. Runs as root, either post-flash on a booted board
# or from the Armbian build hook (build/customize-image.sh).

set -euo pipefail

# --- Config (override via env) ---
AP_SSID_PREFIX="${AP_SSID_PREFIX:-OpenAstro}"   # SSID becomes <prefix>-<wlan0 MAC last 4 hex>
AP_PASSPHRASE="${AP_PASSPHRASE:-12345678}"
AP_IP="${AP_IP:-172.24.1.1}"                # fleet-wide AP address; NM "shared" serves DHCP+NAT on it
AP_CHANNEL="${AP_CHANNEL:-40}"              # 5 GHz ch40 (UNII-1, non-DFS); HT40 (VHT/80MHz is rejected by the UWE5622 mainline driver)
AP_COUNTRY="${AP_COUNTRY:-US}"
# iMate PowerBox GPIO: mainline H6 main bank is /dev/gpiochip1 (BSP had it as gpiochip0).
# DC1=line 118 (PD22), DC2=line 114 (PD18). DC3=always-on passthrough (no GPIO).
POWERBOX_GPIOCHIP="${POWERBOX_GPIOCHIP:-/dev/gpiochip1}"

log() { echo "[openastro] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }

# ============================================================
# Packages
# ============================================================
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    network-manager dnsmasq-base polkitd iptables iw wireless-regdb \
    libgpiod3 gpiod \
    curl gnupg ca-certificates \
    >/dev/null

# ============================================================
# WiFi (NetworkManager-native: hotspot + client join, like the other boards)
# ============================================================
# NetworkManager owns wlan0 outright: the hotspot is an NM AP-mode profile and
# joining a home network is a plain NM client connection, so AlpacaBridge's
# WiFi card (an NM D-Bus frontend) manages everything truthfully.
#
# UWE5622 quirks this section works around (all hardware-verified 2026-08-17):
# - The firmware runs the AP SME and silently drops client association when
#   the RSN IE advertises PSK-SHA256, which NM hardcodes into AP-mode
#   key_mgmt (pmf=disable does not remove it). A dispatcher hook rewrites the
#   supplicant AP network to plain WPA-PSK on every hotspot activation; with
#   it, clients associate and complete the 4-way handshake reliably.
# - 5 GHz needs a real regulatory domain before the AP will start (world
#   domain forbids the channels), so the country is baked in at module load.
# - The radio cannot scan while beaconing (no AP+STA concurrency); network
#   lists must be gathered while the hotspot is down. That UX lives in
#   AlpacaBridge, not here.
log "Configuring WiFi (NetworkManager)..."

# Clean up the pre-NM hostapd stack (upgrades / re-runs on older installs).
systemctl disable --now hostapd dnsmasq openastro-ap-up.service >/dev/null 2>&1 || true
rm -f /etc/NetworkManager/conf.d/10-openastro-wlan0-unmanaged.conf \
      /etc/hostapd/hostapd.conf /etc/default/hostapd \
      /etc/dnsmasq.d/openastro-ap.conf /etc/openastro-nat.rules \
      /etc/sysctl.d/99-openastro-ap.conf \
      /etc/systemd/system/openastro-ap-up.service

systemctl enable NetworkManager >/dev/null 2>&1 || true

# UWE5622 driver override: the sprdwl_ng module Armbian bundles fails
# wpa_supplicant AP-mode init on this kernel; ship a known-good build of the
# maintained out-of-tree uwe5622 tree (commit d6bec75) instead. Prebuilt for
# exactly this kernel, so hold the kernel packages - an apt kernel upgrade
# would reintroduce the broken bundled module. (TODO: replace with DKMS.)
KREL="6.18.33-current-sunxi64"
MODSRC="$(dirname "$0")/modules/sprdwl_ng-${KREL}.ko"
MODDST="/lib/modules/${KREL}/kernel/drivers/net/wireless/uwe5622/unisocwifi/sprdwl_ng.ko"
if [ -f "$MODSRC" ] && [ -d "$(dirname "$MODDST")" ]; then
    install -m 0644 "$MODSRC" "$MODDST"
    apt-mark hold linux-image-current-sunxi64 linux-dtb-current-sunxi64 >/dev/null 2>&1 || true
    log "UWE5622 driver override installed (kernel ${KREL} held)."
else
    log "WARNING: UWE5622 driver override not installed (kernel ${KREL} not present?)"
fi

# Regulatory domain from module load, so the 5 GHz AP can start at boot
# before any userspace (AlpacaBridge persists later changes itself).
cat > /etc/modprobe.d/openastro-regdom.conf <<EOF
options cfg80211 ieee80211_regdom=${AP_COUNTRY}
EOF

# UWE5622 + NM hotspot fix: strip PSK-SHA256 from the supplicant AP network
# (see the section comment above).
mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/90-uwe5622-psk-only <<'EOF'
#!/bin/sh
# UWE5622 firmware silently rejects client association when the AP's RSN IE
# advertises PSK-SHA256, and NetworkManager hardcodes "WPA-PSK WPA-PSK-SHA256"
# for AP-mode connections regardless of the pmf setting. Force the supplicant
# network to plain WPA-PSK whenever a hotspot comes up on wlan0.
[ "$1" = "wlan0" ] || exit 0
case "$2" in up|reapply) ;; *) exit 0 ;; esac

mode=$(nmcli -g 802-11-wireless.mode connection show "$CONNECTION_UUID" 2>/dev/null)
[ "$mode" = "ap" ] || exit 0

id=$(wpa_cli -i wlan0 list_networks 2>/dev/null | awk 'NR==2 {print $1}')
[ -n "$id" ] || exit 0

km=$(wpa_cli -i wlan0 get_network "$id" key_mgmt 2>/dev/null)
case "$km" in
*SHA256*)
    wpa_cli -i wlan0 set_network "$id" key_mgmt WPA-PSK
    wpa_cli -i wlan0 disable_network "$id"
    wpa_cli -i wlan0 enable_network "$id"
    logger -t uwe5622-psk-only "stripped PSK-SHA256 from AP key_mgmt (network $id)"
    ;;
esac
exit 0
EOF
chmod +x /etc/NetworkManager/dispatcher.d/90-uwe5622-psk-only

# The hotspot profile, under AlpacaBridge's well-known id ("OpenAstro-AP") so
# the web UI's Personal Hotspot card edits this exact profile. Low autoconnect
# priority: a joined home network wins at boot when it is in range, and NM
# falls back to the hotspot when it is not (client-or-AP, single radio).
# SSID here is a placeholder; openastro-ap-ssid.service rewrites it from the
# wlan0 MAC on first boot (OpenAstro-XXXX fleet scheme).
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection <<EOF
[connection]
id=OpenAstro-AP
type=wifi
autoconnect=true
autoconnect-priority=-10

[wifi]
mode=ap
band=a
channel=${AP_CHANNEL}
ssid=${AP_SSID_PREFIX}-AP

[wifi-security]
key-mgmt=wpa-psk
psk=${AP_PASSPHRASE}
# Strict WPA2/CCMP with PMF off - the UWE5622 driver has no
# set_default_mgmt_key (IGTK install fails with EOPNOTSUPP and supplicant
# aborts AP init), and an unpinned profile lets TKIP/PMF into the mix.
pmf=1
proto=rsn;
group=ccmp;
pairwise=ccmp;

[ipv4]
method=shared
address1=${AP_IP}/24

[ipv6]
method=disabled
EOF
chmod 600 /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection

# Derive SSID from wlan0 MAC (matches the OpenAstro-XXXX scheme used on the
# other OpenAstro boards).
cat > /usr/local/sbin/openastro-ap-ssid.sh <<'EOF'
#!/bin/bash
set -e
IFACE=wlan0
for _ in $(seq 1 60); do nmcli -t general status >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 30); do [ -r "/sys/class/net/$IFACE/address" ] && break; sleep 0.5; done
[ -r "/sys/class/net/$IFACE/address" ] || exit 0
mac=$(tr -d ':' < "/sys/class/net/$IFACE/address" | tr 'a-f' 'A-F')
want="${AP_SSID_PREFIX}-${mac: -4}"
cur=$(nmcli -g 802-11-wireless.ssid connection show OpenAstro-AP 2>/dev/null) || exit 0
[ "$cur" = "$want" ] && exit 0
nmcli connection modify OpenAstro-AP 802-11-wireless.ssid "$want"
# Bounce the hotspot if it already beacons under the placeholder name.
if nmcli -g GENERAL.STATE connection show OpenAstro-AP 2>/dev/null | grep -q activated; then
    nmcli connection up OpenAstro-AP >/dev/null 2>&1 || true
fi
EOF
sed -i "s/\${AP_SSID_PREFIX}/${AP_SSID_PREFIX}/g" /usr/local/sbin/openastro-ap-ssid.sh
chmod +x /usr/local/sbin/openastro-ap-ssid.sh

cat > /etc/systemd/system/openastro-ap-ssid.service <<EOF
[Unit]
Description=OpenAstro AP: SSID-from-MAC for the NM hotspot profile
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/openastro-ap-ssid.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl enable openastro-ap-ssid.service >/dev/null 2>&1

log "WiFi configured (NM hotspot profile OpenAstro-AP)."

# ============================================================
# System identity (turnkey - no Armbian first-boot wizard)
# ============================================================
log "Setting system identity..."
OA_HOSTNAME="${OPENASTRO_HOSTNAME:-openastro}"
OA_USER="${OPENASTRO_USER:-astro}"
OA_PASS="${OPENASTRO_PASS:-astro}"
echo "$OA_HOSTNAME" > /etc/hostname
if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1\t$OA_HOSTNAME/" /etc/hosts
else echo -e "127.0.1.1\t$OA_HOSTNAME" >> /etc/hosts; fi
id "$OA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,dialout,plugdev,audio,video "$OA_USER"
echo "${OA_USER}:${OA_PASS}" | chpasswd
# Disable Armbian's interactive first-login wizard (credentials are baked in).
systemctl disable armbian-firstlogin.service 2>/dev/null || true
rm -f /root/.not_logged_in_yet 2>/dev/null || true

# ============================================================
# GPIO enablement for the iMate PowerBox (libgpiod v2)
# ============================================================
# Hardware plumbing so the PowerBox works with the preinstalled AlpacaBridge:
# libgpiod v2 (libgpiod3 + the gpiod CLI, installed above), a gpio group, and a
# udev rule making the gpiochip char devices group-accessible.
#
# iMate PowerBox is on ${POWERBOX_GPIOCHIP} (mainline H6 main bank): DC1=line 118
# (PD22), DC2=line 114 (PD18); DC3 is an always-on passthrough. AlpacaBridge's
# iMate PowerBox driver talks to gpiochip1 via libgpiod - its service user must
# be a member of the gpio group (the alpacabridge .deb handles that on install).
log "Enabling GPIO access (libgpiod v2) for the PowerBox..."
getent group gpio >/dev/null || groupadd --system gpio
cat > /etc/udev/rules.d/99-openastro-gpio.rules <<EOF
KERNEL=="gpiochip[0-9]*", GROUP="gpio", MODE="0660"
EOF

# ============================================================
# Dark for imaging - turn off the board LEDs
# ============================================================
# A *blinking* status LED ruins astrophotography at night. So kill every LED
# trigger (no blinking) and turn everything off, then leave just the red status
# LED solid-on as a quiet "power is on" indicator (red is the astronomy-friendly
# colour and a steady light doesn't catch the eye like a blink does).
log "Configuring board LEDs (dark for imaging, solid red = on)..."
cat > /usr/local/sbin/openastro-leds-off.sh <<'EOF'
#!/bin/bash
# Stop all blinking and turn every LED off.
for l in /sys/class/leds/*; do
    [ -e "$l/trigger" ]    && echo none > "$l/trigger"    2>/dev/null || true
    [ -e "$l/brightness" ] && echo 0    > "$l/brightness" 2>/dev/null || true
done
# Solid-on red status LED as the power indicator.
for l in /sys/class/leds/*red*; do
    [ -e "$l/brightness" ] || continue
    echo "$(cat "$l/max_brightness" 2>/dev/null || echo 1)" > "$l/brightness" 2>/dev/null || true
done
exit 0
EOF
chmod +x /usr/local/sbin/openastro-leds-off.sh
cat > /etc/systemd/system/openastro-leds-off.service <<EOF
[Unit]
Description=OpenAstro: turn off board LEDs (dark for imaging)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/openastro-leds-off.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl enable openastro-leds-off.service >/dev/null 2>&1

# ============================================================
# Auto-install to eMMC on first boot from SD (appliance install)
# ============================================================
# When the image is booted from the removable SD, copy OpenAstro to the eMMC and
# write the bootloader, so the user just flashes the SD, powers on, waits, and
# removes the SD - the iMate then boots from internal storage with no SD needed.
log "Installing eMMC auto-installer..."
install -m 0755 "$(dirname "$0")/openastro-emmc-install.sh" /usr/local/sbin/openastro-emmc-install.sh 2>/dev/null || true
cat > /etc/systemd/system/openastro-emmc-install.service <<EOF
[Unit]
Description=OpenAstro: install to eMMC on first boot from SD
After=multi-user.target
ConditionPathExists=!/etc/openastro-emmc-installed

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openastro-emmc-install.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl enable openastro-emmc-install.service >/dev/null 2>&1

# ============================================================
# AlpacaBridge (preinstalled - the whole point of the appliance;
# a dark site has no internet to apt install from)
# ============================================================
INSTALL_ALPACABRIDGE="${INSTALL_ALPACABRIDGE:-yes}"
if [ "$INSTALL_ALPACABRIDGE" = yes ]; then
log "Installing AlpacaBridge from apt.openastro.net..."
curl -fsSL https://apt.openastro.net/repo/openastro-archive-keyring.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/openastro-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openastro-archive-keyring.gpg] https://apt.openastro.net trixie main" \
    > /etc/apt/sources.list.d/openastro.list
apt-get update -qq
apt-get install -y -qq alpacabridge >/dev/null
log "AlpacaBridge $(dpkg-query -W -f '${Version}' alpacabridge) installed."
# Seed the WiFi regulatory country so the 5 GHz hotspot is allowed out of the
# box (AlpacaBridge requires a persisted country before 5 GHz AP settings and
# reads it from its state dir; the user can change it in the web UI).
install -d /etc/alpacabridge/config
if [ ! -f /etc/alpacabridge/config/wifi_country ]; then
    echo "${AP_COUNTRY}" > /etc/alpacabridge/config/wifi_country
fi
chown -R alpacabridge:alpacabridge /etc/alpacabridge/config 2>/dev/null || true
fi

log "OpenAstro OS layer complete (NM WiFi + libgpiod/GPIO + LEDs + eMMC auto-installer + AlpacaBridge)."
