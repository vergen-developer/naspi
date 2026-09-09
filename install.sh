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
    return
  fi
  if id -u pi >/dev/null 2>&1; then
    NAS_USER="pi"
    return
  fi
  NAS_USER="$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1; exit}')"
  [ -n "${NAS_USER:-}" ] || die "Nessun utente locale trovato"
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
  log "Aggiornamento pacchetti (sul Pi 1 può richiedere diversi minuti)"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl samba samba-common-bin avahi-daemon \
    iptables iproute2
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
  local boot name type tran pk fstype
  boot="$(root_disk)"
  while read -r name type tran pk fstype; do
    [ "$type" = "part" ] || [ "$type" = "disk" ] || continue
    [ "$tran" = "usb" ] || [ "$(lsblk -no TRAN "/dev/${pk:-$name}" 2>/dev/null | head -1)" = "usb" ] || continue
    [ -n "$fstype" ] || continue
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
    log "Nessun USB formattato: cartella sulla microSD ${SHARE_PATH}"
  fi
  chown "${NAS_USER}:${NAS_USER}" "$SHARE_PATH" 2>/dev/null || true
  chmod 775 "$SHARE_PATH" 2>/dev/null || true
}

smb_password() {
  mkdir -p "$NASPI_DIR"
  chmod 700 "$NASPI_DIR"
  if [ -f "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CRED_FILE"
    [ -n "${SMB_PASS:-}" ] && return 0
  fi
  SMB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
  cat > "$CRED_FILE" <<EOF
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
   server string = NASPI
   netbios name = NASPI
   server role = standalone server
   security = user
   map to guest = Bad User
   dns proxy = no
   logging = systemd
   max log size = 200
   server min protocol = SMB2
   smb ports = 445
   disable netbios = yes
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   show add printer wizard = no
   multicast dns register = yes
   hostname lookups = no
   use sendfile = yes
   aio read size = 0
   aio write size = 0
   socket options = TCP_NODELAY IPTOS_LOWDELAY
   getwd cache = yes

[${SHARE_NAME}]
   path = ${SHARE_PATH}
   comment = NASPI
   browseable = yes
   read only = no
   writable = yes
   guest ok = yes
   create mask = 0664
   directory mask = 0775
   force user = ${NAS_USER}
   force group = ${NAS_USER}
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
  cat > /etc/avahi/services/naspi.service <<EOF
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h NAS</name>
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

start_samba() {
  systemctl disable --now nmbd >/dev/null 2>&1 || true
  systemctl enable smbd avahi-daemon >/dev/null
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

  log "Tentativo aggiornamento Tailscale"
  if timeout 180 /usr/sbin/tailscale update --yes >/dev/null 2>&1 \
    || timeout 180 /usr/sbin/tailscale update >/dev/null 2>&1; then
    sleep 3
    if ! systemctl is-active --quiet tailscaled || ! bin_runs /usr/sbin/tailscale; then
      warn "Update instabile, ripristino ${TS_ARMv6_PIN}"
      install_static_tailscale "$TS_ARMv6_PIN" "arm"
      start_tailscaled || true
    fi
  else
    warn "Update saltato, resto su ${TS_ARMv6_PIN}"
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
  local host args
  host="$(hostname -s 2>/dev/null || hostname)"
  args=(up --accept-dns=false --ssh=false --hostname="$host" --timeout=20s)
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    log "Tailscale: autenticazione con auth key"
    tailscale up --auth-key="$TAILSCALE_AUTHKEY" --accept-dns=false --ssh=false --hostname="$host" \
      || tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-dns=false --ssh=false --hostname="$host" \
      || warn "Auth key rifiutata: userai il link nel riepilogo"
    return 0
  fi

  log "Avvio Tailscale (login nel browser)"
  timeout 25 tailscale "${args[@]}" >/tmp/naspi-tailscale.up 2>&1 || true
}

wait_tailscale_login() {
  local state url elapsed=0
  state="$(ts_state || true)"
  [ "$state" = "Running" ] && return 0
  [ -n "${TAILSCALE_AUTHKEY:-}" ] && return 0

  url="$(ts_authurl || true)"
  if [ -z "$url" ] && [ -f /tmp/naspi-tailscale.up ]; then
    url="$(grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' /tmp/naspi-tailscale.up | head -1 || true)"
  fi

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

lan_ips() {
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '$2 != "tailscale0" && $2 !~ /^docker/ { gsub(/\/.*/, "", $4); print $4 }' \
    | sort -u
}

hostname_local() {
  local h
  h="$(hostname -s 2>/dev/null || hostname)"
  printf '%s.local' "$h"
}

write_cli() {
  cat > /usr/local/bin/naspi <<'CLI'
#!/bin/bash
set -euo pipefail
CRED=/etc/naspi/credentials
SHARE_NAME=nas
SHARE_PATH=/srv/nas
NAS_USER=pi
SMB_PASS="(vedi /etc/naspi/credentials)"
if [ -f "$CRED" ]; then
  # shellcheck disable=SC1090
  . "$CRED"
fi

lan_ips() {
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '$2 != "tailscale0" && $2 !~ /^docker/ { gsub(/\/.*/, "", $4); print $4 }' \
    | sort -u
}

ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
ts_json="$(tailscale status --json 2>/dev/null | tr -d '\n' || true)"
ts_state="$(printf '%s' "$ts_json" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
ts_url="$(printf '%s' "$ts_json" | sed -n 's/.*"AuthURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
[ -n "$ts_url" ] || ts_url="$(cat /etc/naspi/tailscale.url 2>/dev/null || true)"
host_local="$(hostname -s 2>/dev/null || hostname).local"
disk="$(findmnt -n -o SOURCE,FSTYPE ${SHARE_PATH} 2>/dev/null || echo "microSD ${SHARE_PATH}")"

echo
echo "=============================================="
echo "  NASPI — come collegarti"
echo "=============================================="
echo
echo "  Cartella sul Pi:  ${SHARE_PATH}"
echo "  Disco:            ${disk}"
echo "  Share SMB:        ${SHARE_NAME}"
echo "  Utente:           ${NAS_USER}"
echo "  Password:         ${SMB_PASS}"
echo
echo "  --- Rete locale (stesso WiFi / cavo) ---"
first=""
while read -r ip; do
  [ -z "$ip" ] && continue
  [ -z "$first" ] && first="$ip"
  echo "  Windows:  \\\\${ip}\\${SHARE_NAME}"
  echo "  Mac/iOS:  smb://${ip}/${SHARE_NAME}"
  echo "  Linux:    smb://${ip}/${SHARE_NAME}"
  echo
done < <(lan_ips)
echo "  Nome locale:  \\\\${host_local}\\${SHARE_NAME}"
echo "                smb://${host_local}/${SHARE_NAME}"
echo
echo "  --- Tailscale (da fuori casa / altro PC) ---"
if [ "${ts_state:-}" = "Running" ] && [ -n "${ts_ip:-}" ]; then
  echo "  Stato:     connesso"
  echo "  IP Tailscale: ${ts_ip}"
  echo "  Windows:  \\\\${ts_ip}\\${SHARE_NAME}"
  echo "  Mac/iOS:  smb://${ts_ip}/${SHARE_NAME}"
  echo "  Linux:    smb://${ts_ip}/${SHARE_NAME}"
  echo
  echo "  1. Installa Tailscale sul PC/telefono: https://tailscale.com/download"
  echo "  2. Accedi con lo STESSO account usato per il Pi"
  echo "  3. Apri il percorso qui sopra"
else
  echo "  Stato:     non collegato (${ts_state:-n/d})"
  if [ -n "${ts_url:-}" ]; then
    echo "  Login:     ${ts_url}"
    echo "  Apri il link, approva il dispositivo, poi rilancia: sudo naspi"
  else
    echo "  Sul Pi esegui:  sudo tailscale up"
    echo "  Poi apri l'URL che stampa e approva."
  fi
  echo "  Poi sul PC: https://tailscale.com/download  (stesso account)"
fi
if grep -q 'TS_USERSPACE=1' "$CRED" 2>/dev/null; then
  echo
  echo "  Nota: Tailscale è in userspace. Lo share via IP 100.x può non"
  echo "  funzionare: usa l'IP locale in LAN, oppure un subnet router."
fi
echo
echo "  Esplora risorse Windows: \\\\IP\\${SHARE_NAME}"
echo "  macOS Finder → Vai → Connessione al server"
echo "=============================================="
echo
CLI
  chmod 755 /usr/local/bin/naspi
}

print_report() {
  /usr/local/bin/naspi
}

main() {
  need_root
  detect_user
  log "Utente NAS: ${NAS_USER}"
  ensure_swap
  lower_gpu_mem
  apt_ok
  smb_password
  setup_share_dir
  # riallinea path nel file credenziali
  sed -i "s|^SHARE_PATH=.*|SHARE_PATH=${SHARE_PATH}|" "$CRED_FILE" 2>/dev/null || true
  sed -i "s|^NAS_USER=.*|NAS_USER=${NAS_USER}|" "$CRED_FILE" 2>/dev/null || true
  write_smb_conf
  write_avahi
  start_samba
  write_cli
  install_tailscale
  bring_up_tailscale
  wait_tailscale_login
  print_report
  log "Fatto. Per rivedere IP e istruzioni:  sudo naspi"
}

main "$@"
