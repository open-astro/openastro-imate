#!/bin/bash
# OpenAstro layer for the iOptron iMate (OrangePi 3 LTS / Allwinner H6).
#
# This turns a stock Armbian "Orange Pi 3 LTS" image (Debian 13 Trixie, mainline
# kernel) into the OpenAstro OS for the iMate: the standard OpenAstro WiFi
# access point (OpenAstro-XXXX / 12345678), libgpiod v2 + GPIO plumbing for the
# iMate PowerBox, dark-for-imaging LEDs, and a self-install-to-eMMC flow.
#
# Why Armbian instead of the old stock-BSP overlay: the stock 5.16 Allwinner BSP
# kernel OOPSes in cpufreq_dt when the WCN/WiFi chip powers on, wedging the box.
# Armbian's mainline kernel fixes cpufreq AND already ships the UWE5622 WiFi/BT
# driver, so we inherit a maintained kernel with working DVFS, USB3, WiFi and BT.
#
# Networking matches the other OpenAstro images (fleet policy): NetworkManager
# manages ALL interfaces, and the AP is an NM keyfile connection (mode=ap,
# ipv4.method=shared). AlpacaBridge's WiFi manager drives this same NM setup
# over D-Bus. Note: an earlier iteration ran standalone hostapd because the
# UWE5622 driver deadlocked when NM auto-managed the radio as a client; the
# keyfile AP is a different code path - validate on hardware and fall back to
# 2.4 GHz (AP_BAND=bg AP_CHANNEL=6) if 5 GHz misbehaves.
#
# Idempotent: safe to re-run. Runs as root, either in the image-build chroot
# (build/build-openastro-image.sh) or post-flash on a booted board.

set -euo pipefail

# --- Config (override via env) ---
AP_SSID="${AP_SSID:-OpenAstro}"
AP_PASSPHRASE="${AP_PASSPHRASE:-12345678}"
AP_IP="${AP_IP:-172.24.1.1}"                # pinned (not NM's 10.42.0.1 default) so docs can give a fixed bridge IP
AP_BAND="${AP_BAND:-a}"                     # 5 GHz; "bg" = 2.4 GHz fallback
AP_CHANNEL="${AP_CHANNEL:-36}"              # UNII-1, non-DFS (the UWE5622 mainline driver rejects VHT/80 MHz; NM's AP uses HT which is fine)
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
# dnsmasq-base is only a Recommends of network-manager and Armbian minimal
# disables recommends - without it NM's shared mode flaps forever with
# "could not start dnsmasq".
apt-get install -y -qq \
    network-manager dnsmasq-base iw wireless-regdb \
    libgpiod3 gpiod curl gpg \
    >/dev/null

# ============================================================
# WiFi access point (NetworkManager)
# ============================================================
# The AP is an NM keyfile connection with mode=ap and ipv4.method=shared -
# NM's internal dnsmasq serves DHCP/DNS and sets up NAT to whatever uplink
# exists. AlpacaBridge's WiFi manager drives this same NM setup over D-Bus
# (polkit rule ships in the AlpacaBridge .deb).
log "Configuring WiFi access point..."

# Retire the old hostapd/standalone-dnsmasq stack from earlier images.
systemctl disable hostapd dnsmasq openastro-ap-up.service >/dev/null 2>&1 || true
rm -f /etc/NetworkManager/conf.d/10-openastro-wlan0-unmanaged.conf \
      /etc/hostapd/hostapd.conf /etc/default/hostapd \
      /etc/dnsmasq.d/openastro-ap.conf /etc/openastro-nat.rules \
      /etc/sysctl.d/99-openastro-ap.conf \
      /usr/local/sbin/openastro-ap-ssid.sh \
      /etc/systemd/system/openastro-ap-up.service

# Armbian drives ethernet through netplan's networkd renderer; hand the whole
# stack to NM instead and stop networkd so the two don't fight over the wired
# port.
if [ -d /etc/netplan ]; then
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/10-openastro.yaml <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
    chmod 600 /etc/netplan/10-openastro.yaml
fi
systemctl disable systemd-networkd.service systemd-networkd.socket >/dev/null 2>&1 || true

# autoconnect keeps the hotspot up from boot: the board is always reachable
# at ${AP_IP} via its own AP even when the user can't log in over their LAN.
AP_UUID=$(cat /proc/sys/kernel/random/uuid)
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection <<EOF
[connection]
id=OpenAstro-AP
uuid=${AP_UUID}
type=wifi
interface-name=wlan0
autoconnect=true
# Below default (0): saved client networks are tried first; the hotspot is
# the fallback when none of them connects.
autoconnect-priority=-10
# Retry forever: with the default (4 attempts) a slow first boot can
# permanently block the AP until reboot.
autoconnect-retries=0

[wifi]
mode=ap
ssid=${AP_SSID}
band=${AP_BAND}
channel=${AP_CHANNEL}

[wifi-security]
key-mgmt=wpa-psk
psk=${AP_PASSPHRASE}

[ipv4]
method=shared
addresses=${AP_IP}/24

[ipv6]
method=disabled
EOF
chmod 600 /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection

# Keyfile was just (re)written with the generic SSID - let the suffixer run
# again on next boot.
rm -f /var/lib/openastro/ssid-set

# Per-board SSID: suffix with the last 4 hex digits of the wlan0 MAC (unique
# and burned into the SoC/radio). Runs once on first boot, before NM, so
# multiple boards at a star party don't collide on the same SSID.
cat > /usr/local/sbin/openastro-ssid <<'EOF'
#!/bin/bash
set -euo pipefail
for _ in $(seq 1 60); do
    [ -r /sys/class/net/wlan0/address ] && break
    sleep 1
done
mac=$(tr -d ':' < /sys/class/net/wlan0/address)
suffix=$(echo "${mac: -4}" | tr 'a-f' 'A-F')
[ ${#suffix} -eq 4 ] || exit 0   # no/odd MAC: keep the generic SSID
sed -i "s/^ssid=\(.*\)/ssid=\1-${suffix}/" \
    /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection
EOF
chmod 755 /usr/local/sbin/openastro-ssid

cat > /etc/systemd/system/openastro-ssid.service <<'EOF'
[Unit]
Description=OpenAstro: per-board AP SSID from wlan0 MAC
Before=NetworkManager.service
ConditionPathExists=!/var/lib/openastro/ssid-set

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openastro-ssid
ExecStartPost=/bin/mkdir -p /var/lib/openastro
ExecStartPost=/bin/touch /var/lib/openastro/ssid-set

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/openastro-ssid.conf <<'EOF'
[Unit]
After=openastro-ssid.service
Wants=openastro-ssid.service
EOF
systemctl enable openastro-ssid.service >/dev/null 2>&1

# Regdom for the 5 GHz AP - set every way that sticks in a chroot.
iw reg set "${AP_COUNTRY}" 2>/dev/null || true
cat > /etc/modprobe.d/openastro-regdom.conf <<EOF
options cfg80211 ieee80211_regdom=${AP_COUNTRY}
EOF
# Clear any persisted rfkill soft-block so the AP can start on first boot.
rm -f /var/lib/systemd/rfkill/*wlan* 2>/dev/null || true

# WiFi behavior for an always-on hotspot: no powersave (an AP that naps
# drops clients serving a mount all night) and no scan MAC randomization
# (keeps the radio identity stable/predictable).
cat > /etc/NetworkManager/conf.d/20-openastro-wifi.conf <<'EOF'
[connection]
wifi.powersave=2

[device]
wifi.scan-rand-mac-address=no
EOF

systemctl enable NetworkManager >/dev/null 2>&1

log "WiFi AP configured (SSID: ${AP_SSID}, band ${AP_BAND} ch${AP_CHANNEL}, ${AP_IP})."

# ============================================================
# First-boot reliability
# ============================================================
# The image build strips SSH host keys (unique per device). Regenerate them
# before sshd starts - otherwise ssh.service fails on first boot
# ("Connection refused" until a reboot).
cat > /etc/systemd/system/openastro-sshkeys.service <<'EOF'
[Unit]
Description=OpenAstro: generate SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/openastro-after-keys.conf <<'EOF'
[Unit]
After=openastro-sshkeys.service
Wants=openastro-sshkeys.service
EOF
systemctl enable openastro-sshkeys.service ssh >/dev/null 2>&1

# Persistent journal, so first-boot failures survive a power cycle and can
# actually be debugged.
install -d -m 2755 -g systemd-journal /var/log/journal

# ============================================================
# Astro-device permissions (present from first boot, so device
# access never depends on install order of AlpacaBridge)
# ============================================================
# ZWO EAF/EFW/CAA are USB HID devices; without this, /dev/hidraw* is
# root-only until AlpacaBridge's own udev rules land AND the device is
# replugged. Shipping the rule in the image removes that ordering trap.
cat > /etc/udev/rules.d/70-openastro-zwo-hid.rules <<'EOF'
# ZWO HID accessories (EAF focuser, EFW/EFWmini filter wheels, CAA rotator)
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="03c3", GROUP="users", MODE="0666"
KERNEL=="hiddev*", ATTRS{idVendor}=="03c3", GROUP="users", MODE="0666"
EOF

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
OA_GROUPS=""
for g in sudo dialout plugdev audio video netdev gpio i2c spi; do
    getent group "$g" >/dev/null && OA_GROUPS="${OA_GROUPS:+$OA_GROUPS,}$g"
done
id "$OA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G "$OA_GROUPS" "$OA_USER"
echo "${OA_USER}:${OA_PASS}" | chpasswd
# Disable Armbian's interactive first-login wizard (credentials are baked in).
systemctl disable armbian-firstlogin.service 2>/dev/null || true
rm -f /root/.not_logged_in_yet 2>/dev/null || true

# ============================================================
# GPIO enablement for the iMate PowerBox (libgpiod v2)
# ============================================================
# The image only provides the hardware plumbing so the PowerBox works the
# moment AlpacaBridge is installed: libgpiod v2 (libgpiod3 + the gpiod CLI,
# installed above), a gpio group, and a udev rule making the gpiochip char
# devices group-accessible.
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
# Temporarily off by default: waiting on the next AlpacaBridge release
# (new WiFi module). Flip to yes once it ships.
INSTALL_ALPACABRIDGE="${INSTALL_ALPACABRIDGE:-no}"
if [ "$INSTALL_ALPACABRIDGE" = yes ]; then
log "Installing AlpacaBridge from apt.openastro.net..."
curl -fsSL https://apt.openastro.net/repo/openastro-archive-keyring.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/openastro-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openastro-archive-keyring.gpg] https://apt.openastro.net trixie main" \
    > /etc/apt/sources.list.d/openastro.list
apt-get update -qq
apt-get install -y -qq alpacabridge >/dev/null
fi

log "OpenAstro OS layer complete (NM WiFi AP + GPIO + LEDs + eMMC auto-installer)."
