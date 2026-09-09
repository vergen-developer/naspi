#!/bin/bash
# NASPI — NAS minimale per Raspberry Pi 1 (e successivi)
#
# Sul Pi (da SSH o console):
#   sudo bash install.sh
#
# Login Tailscale automatico (opzionale):
#   sudo TAILSCALE_AUTHKEY=tskey-auth-XXXX bash install.sh
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

HOST_NAME="${NASPI_HOSTNAME:-mariarosaria}"
SHARE_NAME="nas"
SHARE_PATH="/srv/nas"
NASPI_DIR="/etc/naspi"
CRED_FILE="${NASPI_DIR}/credentials"
TS_CACHE="/var/cache/naspi"
TS_ARMv6_PIN="1.62.0"
WAIT_LOGIN_SECS="${NASPI_WAIT_LOGIN:-300}"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Esegui: sudo bash install.sh"
}

detect_user() {
  local u="${SUDO_USER:-}"
  if [ -n "$u" ] && [ "$u" != "root" ]; then
    NAS_USER="$u"
  elif id -u pi >/dev/null 2>&1; then
    NAS_USER="pi"
  else
    NAS_USER="$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1; exit}')"
  fi
  [ -n "${NAS_USER:-}" ] || die "Nessun utente locale trovato"
  NAS_GROUP="$(id -gn "$NAS_USER")"
}

set_hostname() {
  log "Hostname di rete: ${HOST_NAME}  (\\${HOST_NAME}.local\\${SHARE_NAME})"
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$HOST_NAME" >/dev/null 2>&1 || true
  fi
  hostname "$HOST_NAME" >/dev/null 2>&1 || true
  echo "$HOST_NAME" > /etc/hostname
  if grep -qE '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1\t${HOST_NAME}/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$HOST_NAME" >> /etc/hosts
  fi
}

is_armv6() {
  grep -qE 'CPU architecture:[[:space:]]*6\b|ARMv6' /proc/cpuinfo \
    || grep -qi 'CPU part[[:space:]]*:[[:space:]]*0xb76' /proc/cpuinfo
}

ts_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    armv6*|armv7*|arm) echo arm ;;
    x86_64) echo amd64 ;;
    i686|i386) echo 386 ;;
    *) echo arm ;;
  esac
}

ensure_swap() {
  local kb
  kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  [ "$kb" -lt 700000 ] || return 0
  [ -f /etc/dphys-swapfile ] || return 0
  log "RAM bassa (${kb} kB): swap 256 MB"
  sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=256/' /etc/dphys-swapfile
  grep -q '^CONF_SWAPSIZE=' /etc/dphys-swapfile \
    || echo 'CONF_SWAPSIZE=256' >> /etc/dphys-swapfile
  dphys-swapfile setup >/dev/null 2>&1 || true
  dphys-swapfile swapon >/dev/null 2>&1 || true
}

lower_gpu_mem() {
  local cfg=""
  for f in /boot/firmware/config.txt /boot/config.txt; do
    [ -f "$f" ] && cfg="$f" && break
  done
  [ -n "$cfg" ] || return 0
  dpkg -s raspberrypi-ui-mods >/dev/null 2>&1 && return 0
  grep -q '^gpu_mem=' "$cfg" || echo 'gpu_mem=16' >> "$cfg"
}

apt_ok() {
  log "Installazione pacchetti minimi (Samba + Avahi)"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl samba samba-common-bin avahi-daemon iptables
  apt-get install -y -qq --no-install-recommends ntfs-3g || true
  apt-get install -y -qq --no-install-recommends exfatprogs \
    || apt-get install -y -qq --no-install-recommends exfat-fuse \
    || true
}

install_fs_helper() {
  case "${1:-}" in
    ntfs|ntfs-3g)
      apt-get install -y -qq --no-install-recommends ntfs-3g || true
      ;;
    exfat)
      apt-get install -y -qq --no-install-recommends exfatprogs \
        || apt-get install -y -qq --no-install-recommends exfat-fuse || true
      ;;
  esac
}

root_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / || true)"
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
  if [ -n "$pk" ]; then
    echo "$pk"
    return
  fi
  echo "$src" | sed 's|^/dev/||; s/p\?[0-9]\+$//'
}

usb_share_source() {
  local boot name type tran pk fstype parent_tran
  boot="$(root_disk)"
  while read -r name type tran pk fstype; do
    [ "$type" = "part" ] || [ "$type" = "disk" ] || continue
    [ -n "$fstype" ] || continue
    parent_tran="$tran"
    if [ -z "$parent_tran" ] && [ -n "$pk" ]; then
      parent_tran="$(lsblk -no TRAN "/dev/$pk" 2>/dev/null | head -1 || true)"
    fi
    [ "$parent_tran" = "usb" ] || continue
    case "$name" in
      *"${boot}"*) continue ;;
    esac
    echo "$name $fstype"
    return 0
  done < <(lsblk -rpn -o NAME,TYPE,TRAN,PKNAME,FSTYPE)
  return 1
}

fstab_opts() {
  local fstype="$1" uid gid
  uid="$(id -u "$NAS_USER")"
  gid="$(id -g "$NAS_USER")"
  case "$fstype" in
    vfat|fat|fat32|exfat|ntfs|ntfs-3g)
      echo "defaults,nofail,noatime,uid=${uid},gid=${gid},umask=0002,x-systemd.device-timeout=15"
      ;;
    *)
      echo "defaults,nofail,noatime,x-systemd.device-timeout=15"
      ;;
  esac
}

install_usb_automount() {
  cat > /usr/local/sbin/naspi-usb-mount <<'USB'
#!/bin/bash
set -euo pipefail
CRED=/etc/naspi/credentials
SHARE_PATH=/srv/nas
NAS_USER=pi
if [ -f "$CRED" ]; then
  # shellcheck disable=SC1090
  . "$CRED"
fi
NAS_GROUP="$(id -gn "$NAS_USER" 2>/dev/null || echo "$NAS_USER")"
mkdir -p "$SHARE_PATH"

root_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / || true)"
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
  if [ -n "$pk" ]; then
    echo "$pk"
    return
  fi
  echo "$src" | sed 's|^/dev/||; s/p\?[0-9]\+$//'
}

usb_share_source() {
  local boot name type tran pk fstype parent_tran
  boot="$(root_disk)"
  while read -r name type tran pk fstype; do
    [ "$type" = "part" ] || [ "$type" = "disk" ] || continue
    [ -n "$fstype" ] || continue
    parent_tran="$tran"
    if [ -z "$parent_tran" ] && [ -n "$pk" ]; then
      parent_tran="$(lsblk -no TRAN "/dev/$pk" 2>/dev/null | head -1 || true)"
    fi
    [ "$parent_tran" = "usb" ] || continue
    case "$name" in
      *"${boot}"*) continue ;;
    esac
    echo "$name $fstype"
    return 0
  done < <(lsblk -rpn -o NAME,TYPE,TRAN,PKNAME,FSTYPE)
  return 1
}

cur="$(findmnt -n -o SOURCE "$SHARE_PATH" 2>/dev/null || true)"
if [ -n "$cur" ]; then
  pk="$(lsblk -no PKNAME "$cur" 2>/dev/null || true)"
  tran="$(lsblk -no TRAN "$cur" 2>/dev/null | head -1 || true)"
  [ -z "$tran" ] && [ -n "$pk" ] && tran="$(lsblk -no TRAN "/dev/$pk" 2>/dev/null | head -1 || true)"
  if [ "$tran" = "usb" ]; then
    exit 0
  fi
fi

line="$(usb_share_source || true)"
if [ -z "$line" ]; then
  logger -t naspi-usb "Nessun SSD USB formattato. Formattalo exFAT o NTFS sul PC e ricollega."
  exit 0
fi

src="${line%% *}"
fstype="${line##* }"
uuid="$(blkid -s UUID -o value "$src" || true)"
[ -n "$uuid" ] || exit 0

uid="$(id -u "$NAS_USER")"
gid="$(id -g "$NAS_USER")"
fstab_type="$fstype"
opts="defaults,nofail,noatime,x-systemd.device-timeout=15"
case "$fstype" in
  vfat|fat|fat32|exfat|ntfs|ntfs-3g)
    [ "$fstype" = "ntfs" ] && fstab_type="ntfs-3g"
    opts="defaults,nofail,noatime,uid=${uid},gid=${gid},umask=0002,x-systemd.device-timeout=15"
    ;;
esac

if findmnt "$src" >/dev/null 2>&1; then
  umount "$src" 2>/dev/null || umount -l "$src" 2>/dev/null || true
fi
if findmnt "$SHARE_PATH" >/dev/null 2>&1; then
  umount "$SHARE_PATH" 2>/dev/null || true
fi
if grep -q " ${SHARE_PATH} " /etc/fstab; then
  sed -i "\| ${SHARE_PATH} |d" /etc/fstab
fi
echo "UUID=${uuid} ${SHARE_PATH} ${fstab_type} ${opts} 0 0" >> /etc/fstab
mount "$SHARE_PATH" || exit 0
chown "${NAS_USER}:${NAS_GROUP}" "$SHARE_PATH" 2>/dev/null || true
chmod 775 "$SHARE_PATH" 2>/dev/null || true
systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
logger -t naspi-usb "SSD USB montato su ${SHARE_PATH} (${src} ${fstype})"
USB
  chmod 755 /usr/local/sbin/naspi-usb-mount

  cat > /etc/systemd/system/naspi-usb.service <<'EOF'
[Unit]
Description=NASPI mount SSD USB su /srv/nas
After=local-fs.target
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/sbin/naspi-usb-mount
RemainAfterExit=no
[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/udev/rules.d/99-naspi-usb.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="/bin/systemctl --no-block start naspi-usb.service"
EOF

  systemctl daemon-reload
  systemctl enable naspi-usb.service >/dev/null 2>&1 || true
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

setup_share_dir() {
  mkdir -p "$SHARE_PATH"
  local line uuid fstype src opts fstab_type
  if line="$(usb_share_source)"; then
    src="${line%% *}"
    fstype="${line##* }"
    log "Trovato disco USB ${src} (${fstype}) → ${SHARE_PATH}"
    install_fs_helper "$fstype"
    uuid="$(blkid -s UUID -o value "$src" || true)"
    if [ -n "$uuid" ]; then
      if findmnt "$src" >/dev/null 2>&1; then
        umount "$src" 2>/dev/null || umount -l "$src" 2>/dev/null || true
      fi
      if findmnt "$SHARE_PATH" >/dev/null 2>&1; then
        umount "$SHARE_PATH" 2>/dev/null || true
      fi
      fstab_type="$fstype"
      [ "$fstype" = "ntfs" ] && fstab_type="ntfs-3g"
      opts="$(fstab_opts "$fstype")"
      if grep -q " ${SHARE_PATH} " /etc/fstab; then
        sed -i "\| ${SHARE_PATH} |d" /etc/fstab
      fi
      echo "UUID=${uuid} ${SHARE_PATH} ${fstab_type} ${opts} 0 0" >> /etc/fstab
      if ! mount "$SHARE_PATH"; then
        warn "USB non montato, uso la microSD"
      fi
    fi
  else
    log "Nessun USB ora: userò la microSD. Quando colleghi l'SSD parte da solo."
  fi
  install_usb_automount
  chown "${NAS_USER}:${NAS_GROUP}" "$SHARE_PATH" 2>/dev/null || true
  chmod 775 "$SHARE_PATH" 2>/dev/null || true
}

smb_password() {
  mkdir -p "$NASPI_DIR"
  chmod 700 "$NASPI_DIR"
  if [ -f "$CRED_FILE" ]; then
    _keep_host="$HOST_NAME"
    # shellcheck disable=SC1090
    . "$CRED_FILE"
    HOST_NAME="$_keep_host"
    unset _keep_host
  fi
  if [ -z "${SMB_PASS:-}" ]; then
    SMB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
  fi
  save_creds
}

save_creds() {
  mkdir -p "$NASPI_DIR"
  chmod 700 "$NASPI_DIR"
  cat > "$CRED_FILE" <<EOF
HOST_NAME=${HOST_NAME}
NAS_USER=${NAS_USER}
SMB_PASS=${SMB_PASS}
SHARE_NAME=${SHARE_NAME}
SHARE_PATH=${SHARE_PATH}
EOF
  chmod 600 "$CRED_FILE"
}

write_smb_conf() {
  log "Configurazione Samba"
  [ -f /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf.naspi.bak ] \
    && cp -a /etc/samba/smb.conf /etc/samba/smb.conf.naspi.bak

  cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = ${HOST_NAME}
   netbios name = ${HOST_NAME}
   mdns name = mdns
   server role = standalone server
   security = user
   map to guest = Bad User
   dns proxy = no
   logging = systemd
   max log size = 50
   server min protocol = SMB2
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   show add printer wizard = no
   multicast dns register = yes
   local master = yes
   preferred master = yes
   domain master = no
   wins support = no
   hostname lookups = no
   use sendfile = yes
   aio read size = 0
   aio write size = 0
   socket options = TCP_NODELAY IPTOS_LOWDELAY
   getwd cache = yes

[${SHARE_NAME}]
   path = ${SHARE_PATH}
   comment = ${HOST_NAME}
   browseable = yes
   read only = no
   writable = yes
   guest ok = yes
   create mask = 0664
   directory mask = 0775
   force user = ${NAS_USER}
   force group = ${NAS_GROUP}
EOF

  if ! pdbedit -L 2>/dev/null | grep -q "^${NAS_USER}:"; then
    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -a -s "$NAS_USER" >/dev/null
  else
    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -s "$NAS_USER" >/dev/null || true
  fi

  testparm -s >/dev/null
}

write_avahi() {
  mkdir -p /etc/avahi/services
  if [ -f /etc/avahi/avahi-daemon.conf ]; then
    if grep -qE '^#?host-name=' /etc/avahi/avahi-daemon.conf; then
      sed -i "s/^#\\?host-name=.*/host-name=${HOST_NAME}/" /etc/avahi/avahi-daemon.conf
    else
      sed -i "/^\\[server\\]/a host-name=${HOST_NAME}" /etc/avahi/avahi-daemon.conf
    fi
  fi
  cat > /etc/avahi/services/naspi.service <<EOF
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_device-info._tcp</type>
    <port>0</port>
    <txt-record>model=RackMac</txt-record>
  </service>
</service-group>
EOF
}

enable_boot() {
  mkdir -p /etc/modules-load.d
  echo tun > /etc/modules-load.d/tun.conf
  modprobe tun 2>/dev/null || true

  mkdir -p /etc/systemd/system/smbd.service.d /etc/systemd/system/nmbd.service.d
  cat > /etc/systemd/system/smbd.service.d/naspi.conf <<'EOF'
[Unit]
After=network-online.target local-fs.target
Wants=network-online.target
[Service]
Restart=on-failure
RestartSec=5
EOF
  cat > /etc/systemd/system/nmbd.service.d/naspi.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Restart=on-failure
RestartSec=5
EOF

  local w
  for w in NetworkManager-wait-online systemd-networkd-wait-online; do
    systemctl enable "${w}.service" >/dev/null 2>&1 || true
  done
  systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
  systemctl daemon-reload
}

start_samba() {
  enable_boot
  systemctl enable smbd nmbd avahi-daemon >/dev/null 2>&1 || true
  systemctl restart nmbd >/dev/null 2>&1 || true
  systemctl restart smbd
  systemctl restart avahi-daemon >/dev/null 2>&1 || true
}

bin_runs() {
  timeout 5 "$1" version >/dev/null 2>&1 \
    || timeout 5 "$1" --version >/dev/null 2>&1 \
    || timeout 5 "$1" -version >/dev/null 2>&1
}

install_static_tailscale() {
  local ver="$1" arch="$2" tgz dir url
  mkdir -p "$TS_CACHE"
  tgz="${TS_CACHE}/tailscale_${ver}_${arch}.tgz"
  if [ ! -f "$tgz" ]; then
    url=""
    for url in \
      "https://pkgs.tailscale.com/stable/tailscale_${ver}_${arch}.tgz" \
      "https://dl.tailscale.com/stable/tailscale_${ver}_${arch}.tgz"; do
      log "Download Tailscale ${ver} (${arch})"
      if curl -fsSL --retry 3 -o "$tgz" "$url"; then
        break
      fi
      rm -f "$tgz"
    done
    [ -f "$tgz" ] || return 1
  fi
  dir="$(mktemp -d)"
  tar -xzf "$tgz" -C "$dir"
  local unpacked
  unpacked="$(find "$dir" -maxdepth 1 -type d -name 'tailscale_*' | head -1)"
  [ -n "$unpacked" ] || { rm -rf "$dir"; return 1; }
  install -m 755 "${unpacked}/tailscale" /usr/sbin/tailscale
  install -m 755 "${unpacked}/tailscaled" /usr/sbin/tailscaled
  if [ -f "${unpacked}/systemd/tailscaled.service" ]; then
    install -m 644 "${unpacked}/systemd/tailscaled.service" /etc/systemd/system/tailscaled.service
    sed -i 's|/usr/sbin/tailscaled|/usr/sbin/tailscaled|g' /etc/systemd/system/tailscaled.service
  fi
  if [ -f "${unpacked}/systemd/tailscaled.defaults" ]; then
    [ -f /etc/default/tailscaled ] || install -m 644 "${unpacked}/systemd/tailscaled.defaults" /etc/default/tailscaled
  fi
  rm -rf "$dir"
  mkdir -p /var/lib/tailscale /run/tailscale /var/cache/tailscale
  grep -q '^FLAGS=' /etc/default/tailscaled 2>/dev/null \
    || printf 'FLAGS=""\nPORT="41641"\n' > /etc/default/tailscaled
  systemctl daemon-reload
}

latest_static_ver() {
  curl -fsSL "https://pkgs.tailscale.com/stable/" 2>/dev/null \
    | grep -oE 'tailscale_[0-9]+\.[0-9]+\.[0-9]+_arm\.tgz' \
    | head -1 \
    | sed -E 's/tailscale_([0-9.]+)_arm\.tgz/\1/'
}

set_ts_flags() {
  local flags="$1"
  mkdir -p "$(dirname /etc/default/tailscaled)"
  if [ -f /etc/default/tailscaled ]; then
    if grep -q '^FLAGS=' /etc/default/tailscaled; then
      sed -i "s|^FLAGS=.*|FLAGS=\"${flags}\"|" /etc/default/tailscaled
    else
      echo "FLAGS=\"${flags}\"" >> /etc/default/tailscaled
    fi
  else
    printf 'FLAGS="%s"\nPORT="41641"\n' "$flags" > /etc/default/tailscaled
  fi
}

start_tailscaled() {
  modprobe tun 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable tailscaled >/dev/null 2>&1 || true
  systemctl restart tailscaled || true
  sleep 3
  systemctl is-active --quiet tailscaled
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    if bin_runs tailscale && systemctl is-active --quiet tailscaled; then
      log "Tailscale già presente"
      return 0
    fi
  fi

  timedatectl set-ntp true >/dev/null 2>&1 || true

  if ! is_armv6; then
    log "Installazione Tailscale (script ufficiale)"
    if curl -fsSL https://tailscale.com/install.sh | sh; then
      start_tailscaled && return 0
    fi
    warn "Script ufficiale fallito, uso il binario statico"
    local latest
    latest="$(latest_static_ver || true)"
    [ -n "$latest" ] || latest="1.86.4"
    install_static_tailscale "$latest" "$(ts_arch)" || die "Download Tailscale fallito"
    start_tailscaled && return 0
  fi

  log "Pi ARMv6: Tailscale ${TS_ARMv6_PIN} (compatibile BCM2835)"
  install_static_tailscale "$TS_ARMv6_PIN" "arm" || die "Download Tailscale ${TS_ARMv6_PIN} fallito"
  bin_runs /usr/sbin/tailscale || die "Il binario Tailscale non parte (SIGILL/segfault)"

  set_ts_flags ""
  if ! start_tailscaled; then
    warn "TUN/kernel non ok, fallback userspace (SMB remoto via Tailscale può non funzionare)"
    set_ts_flags "--tun=userspace-networking"
    start_tailscaled || die "tailscaled non parte"
    echo "TS_USERSPACE=1" >> "$CRED_FILE"
  fi
}

ts_field() {
  local key="$1"
  tailscale status --json 2>/dev/null \
    | tr -d '\n' \
    | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    | head -1
}

ts_state() { ts_field BackendState; }
ts_authurl() { ts_field AuthURL; }

bring_up_tailscale() {
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    log "Tailscale: autenticazione con auth key"
    tailscale up --auth-key="$TAILSCALE_AUTHKEY" --accept-dns=false --hostname="$HOST_NAME" \
      || tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-dns=false --hostname="$HOST_NAME" \
      || warn "Auth key rifiutata: userai il link nel riepilogo"
    return 0
  fi

  log "Avvio Tailscale (login nel browser)"
  timeout 25 tailscale up --accept-dns=false --hostname="$HOST_NAME" >/tmp/naspi-tailscale.up 2>&1 || true
}

wait_tailscale_login() {
  local state url elapsed=0 i
  state="$(ts_state || true)"
  [ "$state" = "Running" ] && return 0
  [ -n "${TAILSCALE_AUTHKEY:-}" ] && return 0

  url=""
  for i in 1 2 3 4 5 6; do
    url="$(ts_authurl || true)"
    [ -z "$url" ] && [ -f /tmp/naspi-tailscale.up ] \
      && url="$(grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' /tmp/naspi-tailscale.up | head -1 || true)"
    [ -n "$url" ] && break
    sleep 2
  done

  if [ -z "$url" ]; then
    warn "Nessun URL di login: dopo l'installazione esegui: sudo tailscale up"
    return 0
  fi

  echo "$url" > "${NASPI_DIR}/tailscale.url"
  printf '\n\033[1;36m----------------------------------------------\n'
  printf '  LOGIN TAILSCALE (apri questo link)\n'
  printf '  %s\n' "$url"
  printf '----------------------------------------------\033[0m\n'
  printf 'Attendo il login (max %ss). Da un altro PC apri il link e approva.\n' "$WAIT_LOGIN_SECS"

  while [ "$elapsed" -lt "$WAIT_LOGIN_SECS" ]; do
    state="$(ts_state || true)"
    if [ "$state" = "Running" ]; then
      log "Tailscale connesso"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "Login non completato ora: apri il link e poi esegui: sudo naspi"
}

write_cli() {
  cat > /usr/local/bin/naspi <<'CLI'
#!/bin/bash
set -euo pipefail
CRED=/etc/naspi/credentials
HOST_NAME=mariarosaria
SHARE_NAME=nas
SHARE_PATH=/srv/nas
NAS_USER=pi
SMB_PASS="(vedi /etc/naspi/credentials)"
if [ -f "$CRED" ]; then
  # shellcheck disable=SC1090
  . "$CRED"
fi

hn="${HOST_NAME}.local"
ts_json="$(tailscale status --json 2>/dev/null | tr -d '\n' || true)"
ts_state="$(printf '%s' "$ts_json" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
ts_url="$(printf '%s' "$ts_json" | sed -n 's/.*"AuthURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
ts_dns="$(printf '%s' "$ts_json" | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
ts_dns="${ts_dns%.}"
[ -n "$ts_url" ] || ts_url="$(cat /etc/naspi/tailscale.url 2>/dev/null || true)"
disk="$(findmnt -n -o SOURCE,FSTYPE "$SHARE_PATH" 2>/dev/null || echo "microSD ${SHARE_PATH}")"

echo
echo "=========================================================="
echo "  NASPI pronto — cartella condivisa"
echo "=========================================================="
echo
echo "  Hostname:     ${HOST_NAME}"
echo "  Percorso:     \\\\${HOST_NAME}\\${SHARE_NAME}"
echo "  Sul Pi:       ${SHARE_PATH}"
echo "  Disco:        ${disk}"
echo "  Utente:       ${NAS_USER}"
echo "  Password:     ${SMB_PASS}"
echo
echo "  Al spegnimento/riavvio Samba e Tailscale partono da soli."
echo
echo "----------------------------------------------------------"
echo "  1) STESSA RETE (WiFi / cavo di casa)"
echo "----------------------------------------------------------"
echo "  WINDOWS"
echo "    1. Apri Esplora file"
echo "    2. Nella barra indirizzi incolla:"
echo "         \\\\${HOST_NAME}\\${SHARE_NAME}"
echo "    3. Invio"
echo "    4. Utente: ${NAS_USER}"
echo "       Password: ${SMB_PASS}"
echo "    Unità permanente (CMD):"
echo "         net use Z: \\\\${HOST_NAME}\\${SHARE_NAME} /user:${NAS_USER} ${SMB_PASS} /persistent:yes"
echo
echo "  MAC"
echo "    Finder → Vai → Connetti al server…"
echo "         smb://${HOST_NAME}.local/${SHARE_NAME}"
echo "    Connetti → utente ${NAS_USER} / password ${SMB_PASS}"
echo
echo "  LINUX"
echo "         smb://${HOST_NAME}.local/${SHARE_NAME}"
echo
echo "  (se non apre: \\\\${HOST_NAME}.local\\${SHARE_NAME})"
echo
echo "  SSD USB: collegalo (già formattato exFAT/NTFS/ext4), si monta da solo"
echo "  su /srv/nas. Pi 1: meglio hub USB alimentato. Poi resta al riavvio."
echo
echo "----------------------------------------------------------"
echo "  2) FUORI CASA (Tailscale)"
echo "----------------------------------------------------------"
if [ "${ts_state:-}" = "Running" ]; then
  echo "  Tailscale:    connesso"
  echo "    1. Sul PC: https://tailscale.com/download"
  echo "    2. Accedi con lo STESSO account del Raspberry"
  echo "    3. Apri (hostname, non IP):"
  echo "         Windows:  \\\\${HOST_NAME}\\${SHARE_NAME}"
  echo "         Mac:      smb://${HOST_NAME}/${SHARE_NAME}"
  if [ -n "${ts_dns}" ]; then
    echo "         Windows:  \\\\${ts_dns}\\${SHARE_NAME}"
    echo "         Mac:      smb://${ts_dns}/${SHARE_NAME}"
  fi
else
  echo "  Tailscale:    da collegare (${ts_state:-n/d})"
  if [ -n "${ts_url:-}" ]; then
    echo "    Apri questo link, accedi e approva il Pi:"
    echo "         ${ts_url}"
    echo "    Poi sul PC: https://tailscale.com/download (stesso account)"
    echo "    Percorso:  \\\\${HOST_NAME}\\${SHARE_NAME}"
    echo "    Alla fine:  sudo naspi"
  else
    echo "    Sul Pi:  sudo tailscale up"
    echo "    Poi apri l'URL, approva, e sul PC installa Tailscale."
    echo "    Percorso:  \\\\${HOST_NAME}\\${SHARE_NAME}"
  fi
fi
if grep -q 'TS_USERSPACE=1' "$CRED" 2>/dev/null; then
  echo
  echo "  Nota: modalità userspace — da remoto usa ${HOST_NAME},"
  echo "  se non apre usa ${hn} in LAN."
fi
echo
echo "  Rivedi questo riepilogo:  sudo naspi"
echo "=========================================================="
echo
CLI
  chmod 755 /usr/local/bin/naspi
  mkdir -p "$SHARE_PATH"
  cat > "${SHARE_PATH}/LEGGIMI.txt" <<EOF
Cartella condivisa

Windows:  \\\\${HOST_NAME}\\${SHARE_NAME}
Mac:      smb://${HOST_NAME}.local/${SHARE_NAME}
Utente:   ${NAS_USER}
Password: ${SMB_PASS}

Fuori casa (Tailscale, stesso account):
  \\\\${HOST_NAME}\\${SHARE_NAME}
EOF
  chown "${NAS_USER}:${NAS_GROUP}" "${SHARE_PATH}/LEGGIMI.txt" 2>/dev/null || true
}

print_report() {
  /usr/local/bin/naspi
}

main() {
  need_root
  detect_user
  set_hostname
  log "Utente Samba: ${NAS_USER}"
  ensure_swap
  lower_gpu_mem
  apt_ok
  smb_password
  setup_share_dir
  save_creds
  write_smb_conf
  write_avahi
  start_samba
  write_cli
  install_tailscale
  systemctl enable tailscaled >/dev/null 2>&1 || true
  bring_up_tailscale
  wait_tailscale_login
  print_report
  log "Fatto. Riepilogo in qualsiasi momento:  sudo naspi"
}

main "$@"
