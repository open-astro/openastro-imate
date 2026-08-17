#!/bin/bash
# OpenAstro layer for the iOptron iMate (OrangePi 3 LTS / Allwinner H6).
#
# This turns a stock Armbian "Orange Pi 3 LTS" image (Debian 13 Trixie, mainline
# kernel) into the OpenAstro OS for the iMate: the stock-style WiFi access point,
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
AP_IP="${AP_IP:-172.24.1.1}"
AP_SUBNET="${AP_SUBNET:-172.24.1.0/24}"
AP_DHCP_RANGE="${AP_DHCP_RANGE:-172.24.1.50,172.24.1.150,12h}"
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
    hostapd dnsmasq iptables iw wireless-regdb \
    network-manager polkitd \
    libgpiod3 gpiod \
    curl gnupg ca-certificates \
    >/dev/null
# hostapd ships masked on Debian until configured.
systemctl unmask hostapd 2>/dev/null || true

# ============================================================
# WiFi access point (standalone hostapd; NetworkManager ignores wlan0)
# ============================================================
# The UWE5622 driver only supports a working AP under hostapd: wpa_supplicant's
# AP mode (which NetworkManager uses for hotspots) activates and beacons, but
# incoming client auth frames are never processed (empty station dump, clients
# loop on the password prompt) - verified on hardware 2026-08-17 with PMF off
# and strict WPA2/CCMP, hot-switch and clean boot. So we run hostapd directly
# and keep NetworkManager off wlan0. Consequence: AlpacaBridge's Personal
# Hotspot card (NM-based) shows the hotspot as off even though it is running;
# fixing that needs a hostapd backend in AlpacaBridge.
# Validated on Armbian 6.18.33: 5 GHz ch40 HT40 comes up clean.
log "Configuring WiFi access point..."

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-openastro-wlan0-unmanaged.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
# NetworkManager (+ nmcli) is installed and enabled so AlpacaBridge's WiFi card
# has a backend to talk to; wlan0 stays unmanaged (the AP is standalone hostapd
# because of the UWE5622 nl80211 deadlock above).
systemctl enable NetworkManager >/dev/null 2>&1 || true

mkdir -p /etc/hostapd
cat > /etc/hostapd/hostapd.conf <<EOF
# OpenAstro iMate AP. SSID is rewritten from the wlan0 MAC at boot by
# openastro-ap-ssid.service. HT40 on 5 GHz ch40 (the UWE5622 mainline driver
# rejects VHT/80 MHz; HT40 = 40 MHz is plenty and proven to come up).
interface=wlan0
driver=nl80211
ssid=${AP_SSID_PREFIX}-AP
country_code=${AP_COUNTRY}
ieee80211d=1
hw_mode=a
channel=${AP_CHANNEL}
ieee80211n=1
ht_capab=[HT40+]
wmm_enabled=1
auth_algs=1
macaddr_acl=0
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
EOF

cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

cat > /etc/dnsmasq.d/openastro-ap.conf <<EOF
interface=wlan0
listen-address=${AP_IP}
bind-dynamic
server=8.8.8.8
domain-needed
bogus-priv
dhcp-range=${AP_DHCP_RANGE}
EOF

# Uplink-agnostic NAT: share whatever wired uplink exists (Armbian names it
# end0/enx…, not eth0) with WiFi clients.
cat > /etc/openastro-nat.rules <<EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i wlan0 -j ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${AP_SUBNET} ! -o wlan0 -j MASQUERADE
COMMIT
EOF
cat > /etc/sysctl.d/99-openastro-ap.conf <<EOF
net.ipv4.ip_forward=1
EOF

# Derive SSID from wlan0 MAC (matches the OpenAstro-XXXX scheme used on the
# other OpenAstro boards).
cat > /usr/local/sbin/openastro-ap-ssid.sh <<'EOF'
#!/bin/bash
set -e
IFACE=wlan0; CONF=/etc/hostapd/hostapd.conf
for _ in $(seq 1 30); do [ -r "/sys/class/net/$IFACE/address" ] && break; sleep 0.5; done
[ -r "/sys/class/net/$IFACE/address" ] || exit 0
mac=$(tr -d ':' < "/sys/class/net/$IFACE/address" | tr 'a-f' 'A-F')
sed -i "s/^ssid=.*/ssid=${AP_SSID_PREFIX}-${mac: -4}/" "$CONF"
EOF
# Bake the configured prefix into the script (it runs without env at boot).
sed -i "s/\${AP_SSID_PREFIX}/${AP_SSID_PREFIX}/g" /usr/local/sbin/openastro-ap-ssid.sh
chmod +x /usr/local/sbin/openastro-ap-ssid.sh

# Bring wlan0 up with the static AP address + set SSID, before hostapd.
cat > /etc/systemd/system/openastro-ap-up.service <<EOF
[Unit]
Description=OpenAstro AP: wlan0 static IP + SSID-from-MAC
After=network-pre.target
Wants=network-pre.target
Before=hostapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/openastro-ap-ssid.sh
ExecStart=/sbin/ip addr replace ${AP_IP}/24 dev wlan0
ExecStart=/sbin/ip link set wlan0 up
ExecStartPost=/usr/sbin/iptables-restore /etc/openastro-nat.rules
ExecStop=/sbin/ip addr flush dev wlan0

[Install]
WantedBy=multi-user.target
EOF

systemctl enable openastro-ap-up.service hostapd dnsmasq >/dev/null 2>&1

log "WiFi AP configured."

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
fi

log "OpenAstro OS layer complete (WiFi AP + libgpiod/GPIO + LEDs + eMMC auto-installer + AlpacaBridge)."
