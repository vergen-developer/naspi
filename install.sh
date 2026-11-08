#!/bin/bash
# NASPI — NAS minimale per Raspberry Pi 1 (e successivi)
#
# Installazione (Raspberry Pi OS Lite, un solo comando, nessuna domanda):
#   curl -fsSL https://raw.githubusercontent.com/vergen-developer/naspi/main/install.sh | sudo bash
# oppure dal repo clonato:
#   sudo bash install.sh          # idempotente: rilancialo quando vuoi
#
# Opzioni (variabili d'ambiente, es. sudo NASPI_GUEST=1 bash install.sh):
#   NASPI_HOSTNAME=nome     nome di rete (default mariarosaria)
#   NASPI_PASSWORD=xxx      password Samba (default generata)
#   NASPI_GUEST=1           accesso senza password (sconsigliato)
#   NASPI_AUTOFORMAT=0      non formattare mai in automatico i dischi vuoti
#   TAILSCALE_AUTHKEY=tskey-...  login Tailscale automatico senza link
#
# Dopo:  sudo naspi | naspi login | naspi diag | naspi mount | naspi format
#
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
_src="${BASH_SOURCE[0]:-$0}"
if [ -f "$_src" ] && [ -z "${_NASPI_SRC_DIR:-}" ]; then
  _NASPI_SRC_DIR="$(cd "$(dirname "$_src")" && pwd)"
  export _NASPI_SRC_DIR
fi
if [ -f "$_src" ] && grep -q $'\r' "$_src" 2>/dev/null; then
  _tmp="$(mktemp)"
  tr -d '\r' < "$_src" > "$_tmp"
  chmod +x "$_tmp"
  exec /bin/bash "$_tmp" "$@"
fi

set -euo pipefail

HOST_NAME="${NASPI_HOSTNAME:-mariarosaria}"
SHARE_NAME="nas"
SHARE_PATH="/srv/nas"
NASPI_DIR="/etc/naspi"
CRED_FILE="${NASPI_DIR}/credentials"
TS_CACHE="/var/cache/naspi"
TS_ARMv6_PIN="1.62.0"
WAIT_LOGIN_SECS="${NASPI_WAIT_LOGIN:-15}"
REPO_RAW="${NASPI_REPO_RAW:-https://raw.githubusercontent.com/vergen-developer/naspi/main}"
BOOT_CHANGED=0

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }
skip() { printf '\n\033[1;36m[ok]\033[0m salto: %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFFOLD=1
export APT_LISTCHANGES_FRONTEND=none

run_to() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" </dev/null
  else
    "$@" </dev/null
  fi
}

trap 'warn "Errore alla riga $LINENO: $BASH_COMMAND"' ERR

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
  if [ "$(hostname -s 2>/dev/null || hostname)" = "$HOST_NAME" ] \
    && [ "$(tr -d ' \t\n' < /etc/hostname 2>/dev/null || true)" = "$HOST_NAME" ]; then
    skip "hostname ${HOST_NAME}"
    return 0
  fi
  log "Hostname di rete: ${HOST_NAME}  (\\${HOST_NAME}.local\\${SHARE_NAME})"
  if command -v hostnamectl >/dev/null 2>&1; then
    run_to 8 hostnamectl set-hostname "$HOST_NAME" >/dev/null 2>&1 || true
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
  local kb sw
  kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  [ -n "$kb" ] || return 0
  [ "$kb" -lt 700000 ] || return 0
  sw="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "${sw:-0}" -ge 200000 ]; then
    skip "swap già attiva"
    return 0
  fi
  [ -f /etc/dphys-swapfile ] || return 0
  log "RAM bassa (${kb} kB): swap 256 MB (attendi)"
  sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=256/' /etc/dphys-swapfile
  grep -q '^CONF_SWAPSIZE=' /etc/dphys-swapfile \
    || echo 'CONF_SWAPSIZE=256' >> /etc/dphys-swapfile
  run_to 90 dphys-swapfile setup >/dev/null 2>&1 || true
  dphys-swapfile swapon >/dev/null 2>&1 || true
}

lower_gpu_mem() {
  local cfg=""
  for f in /boot/firmware/config.txt /boot/config.txt; do
    [ -f "$f" ] && cfg="$f" && break
  done
  [ -n "$cfg" ] || return 0
  if dpkg -s raspberrypi-ui-mods >/dev/null 2>&1; then
    return 0
  fi
  grep -q '^gpu_mem=' "$cfg" || echo 'gpu_mem=16' >> "$cfg"
}

boot_file() {
  local f
  for f in "/boot/firmware/$1" "/boot/$1"; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

# Imposta key=value in config.txt (una sola riga, fuori da sezioni [pi4] ecc.)
config_set() {
  local cfg="$1" key="$2" val="$3"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$cfg"; then
    grep -qE "^${key}=${val}\$" "$cfg" && return 0
    sed -i -E "0,/^[[:space:]]*#?[[:space:]]*${key}=.*/s//${key}=${val}/" "$cfg"
  else
    # in testa, prima di qualsiasi filtro [xxx]
    sed -i "1i ${key}=${val}" "$cfg"
  fi
  BOOT_CHANGED=1
}

# Aggiunge/sostituisce un parametro kernel in cmdline.txt (riga unica)
cmdline_set() {
  local cmd="$1" key="$2" val="$3" line
  line="$(head -n1 "$cmd" | tr -d '\r')"
  case " $line " in
    *" ${key}=${val} "*) return 0 ;;
  esac
  line="$(printf '%s\n' "$line" | sed -E "s/(^| )${key//./\\.}=[^ ]*//g; s/  +/ /g; s/^ //; s/ \$//")"
  printf '%s %s=%s\n' "$line" "$key" "$val" > "$cmd"
  BOOT_CHANGED=1
}

pi_model() {
  tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "sconosciuto"
}

# Pi 1: le porte USB reggono poca corrente. Un SSD che assorbe troppo all'avvio
# fa crollare i 5V → il Pi si riavvia o il disco si stacca/riconnette.
# Qui riduciamo tutto ciò che è riducibile via software; il resto è hardware
# (alimentatore 5V ≥2.5A + hub USB alimentato o cavo Y).
usb_ssd_stable() {
  local cfg cmd d
  BOOT_CHANGED=0
  log "Stabilità USB/SSD per $(pi_model)"
  if cfg="$(boot_file config.txt)"; then
    [ -f "${cfg}.naspi.bak" ] || cp -a "$cfg" "${cfg}.naspi.bak"
    config_set "$cfg" max_usb_current 1          # B+/A+: 600mA → 1.2A sulle USB
    # overclock = più consumo = più brown-out con l'SSD: torna ai default
    sed -i -E 's/^(force_turbo|over_voltage|arm_freq|core_freq|sdram_freq)=/#naspi# \1=/' "$cfg"
  fi
  if cmd="$(boot_file cmdline.txt)"; then
    [ -f "${cmd}.naspi.bak" ] || cp -a "$cmd" "${cmd}.naspi.bak"
    # usbcore e usb-storage sono built-in nel kernel Raspberry: modprobe.d non basta
    cmdline_set "$cmd" usbcore.autosuspend -1
    cmdline_set "$cmd" usb-storage.quirks 13fd:0840:emnu
  fi
  mkdir -p /etc/modprobe.d
  cat > /etc/modprobe.d/naspi-usb.conf <<'EOF'
options usbcore autosuspend=-1
options usb-storage quirks=13fd:0840:emnu
EOF
  # subito, senza riavvio
  echo -1 >/sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
  for d in /sys/bus/usb/devices/*/power/control; do
    echo on >"$d" 2>/dev/null || true
  done
  rm -f /etc/udev/rules.d/98-naspi-usb-power.rules
  cat > /etc/udev/rules.d/90-naspi-usb-power.rules <<'EOF'
# NASPI: nessun autosuspend sui dispositivi USB (dischi che si staccano)
ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
EOF
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

# Pi 1 (256/512 MB): il driver USB dwc_otg fallisce le allocazioni se la RAM
# libera scende troppo → disco/rete USB che cadono sotto carico.
tune_system() {
  cat > /etc/sysctl.d/90-naspi.conf <<'EOF'
vm.min_free_kbytes = 8192
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.swappiness = 10
EOF
  sysctl -q -p /etc/sysctl.d/90-naspi.conf >/dev/null 2>&1 || true
  # log persistenti (piccoli): dopo un riavvio improvviso `journalctl -b -1` dice perché
  mkdir -p /etc/systemd/journald.conf.d /var/log/journal
  cat > /etc/systemd/journald.conf.d/naspi.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=32M
EOF
  systemctl restart systemd-journald >/dev/null 2>&1 || true
}

APT_OPTS=(-y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o Acquire::Retries=3)

preseed_debconf() {
  command -v debconf-set-selections >/dev/null 2>&1 || return 0
  debconf-set-selections <<'EOF' || true
samba-common samba-common/workgroup string WORKGROUP
samba-common samba-common/dhcp boolean false
samba-common samba-common/do_debconf boolean true
iptables-persistent iptables-persistent/autosave_v4 boolean false
iptables-persistent iptables-persistent/autosave_v6 boolean false
EOF
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

# Installa il primo pacchetto disponibile tra gli argomenti.
pkg_first() {
  local p rc=1
  set +e
  preseed_debconf
  for p in "$@"; do
    [ -n "$p" ] || continue
    if pkg_installed "$p"; then
      set -e
      return 0
    fi
    log "Installo $p — sul Pi 1 può richiedere diversi minuti, non è fermo"
    if DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" --fix-missing "$p" </dev/null; then
      log "ok $p"
      set -e
      return 0
    fi
    warn "$p non trovato, provo alternativa"
  done
  set -e
  return 1
}

http_get() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 180 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=20 --read-timeout=180 -O "$out" "$url"
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -q -O "$out" "$url"
  else
    return 1
  fi
}

http_pipe() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --tries=3 --timeout=20 --read-timeout=120 "$url"
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -q -O- "$url"
  else
    return 1
  fi
}

apt_prepare() {
  log "Indici apt + riparazione dpkg (attendi, niente domande)"
  preseed_debconf
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a </dev/null >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -f install -y </dev/null || true
  log "apt update in corso..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get update \
      -o Acquire::Check-Valid-Until=false \
      -o Acquire::AllowReleaseInfoChange=true \
      -o Acquire::Retries=3 </dev/null; then
    warn "apt update instabile, riprovo"
    DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Check-Valid-Until=false \
      -o Acquire::AllowReleaseInfoChange=true </dev/null \
      || warn "uso la cache apt già presente"
  fi
}

apt_ok() {
  if command -v smbd >/dev/null 2>&1 \
    && { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } \
    && command -v mkfs.ext4 >/dev/null 2>&1 \
    && command -v sfdisk >/dev/null 2>&1 \
    && command -v ntfs-3g >/dev/null 2>&1 \
    && { command -v mkfs.exfat >/dev/null 2>&1 || command -v fsck.exfat >/dev/null 2>&1; } \
    && command -v lsusb >/dev/null 2>&1; then
    skip "pacchetti apt (già installati)"
    return 0
  fi
  apt_prepare
  log "Pacchetti (con alternative se un nome manca)"

  pkg_first ca-certificates openssl || warn "certificati HTTPS assenti"
  pkg_first curl wget || die "Né curl né wget: impossibile scaricare Tailscale"

  if ! pkg_first samba; then
    pkg_first samba-common || true
    pkg_first samba-common-bin || true
    pkg_first samba-dsdb-modules || true
  fi
  pkg_first samba-common-bin samba-common || true

  if ! command -v smbd >/dev/null 2>&1 && ! command -v samba >/dev/null 2>&1; then
    die "Samba non installabile (pacchetto assente nei repo). Controlla: apt-cache search samba"
  fi

  pkg_first avahi-daemon avahi-utils libnss-mdns \
    || warn "Avahi assente: in LAN usa \\\\${HOST_NAME}\\${SHARE_NAME} (NetBIOS)"
  pkg_first libnss-mdns || true
  pkg_first iptables iptables-nft nftables \
    || warn "iptables/nftables assenti: Tailscale userà il fallback userspace se serve"
  pkg_first ntfs-3g ntfsprogs || warn "ntfs opzionale assente (ok)"
  pkg_first exfatprogs exfat-fuse exfat-utils fuse-exfat || warn "exfat opzionale assente (ok)"
  pkg_first iproute2 iproute || true
  pkg_first kmod || true
  pkg_first e2fsprogs || die "e2fsprogs (mkfs.ext4) mancante"
  pkg_first fdisk util-linux || true
  pkg_first dosfstools || true
  pkg_first usbutils || true
  pkg_first raspi-utils libraspberrypi-bin || true
  log "Pacchetti pronti, continuo"
}

install_usb_automount() {
  cat > /usr/local/sbin/naspi-usb-mount <<'USB'
#!/bin/bash
# NASPI: monta l'SSD/HDD USB su /srv/nas. Chiamato da udev (collega/scollega),
# al boot e da `sudo naspi mount`. Disco vuoto (senza partizioni né dati)
# → formattato ext4 in automatico. Un disco con dati non viene MAI cancellato.
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRED=/etc/naspi/credentials
SHARE_PATH=/srv/nas
NAS_USER=pi
NASPI_AUTOFORMAT=1
LABEL=nas
[ -f "$CRED" ] && . "$CRED"
NAS_GROUP="$(id -gn "$NAS_USER" 2>/dev/null || echo "$NAS_USER")"
WAIT="${1:-5}"   # secondi di attesa del disco (al boot di più)

say() { logger -t naspi-usb -- "$*" 2>/dev/null || true; echo "naspi-usb: $*"; }

exec 9>/run/naspi-usb.lock
flock -w 900 9 || exit 0
mkdir -p "$SHARE_PATH"

# Rimuove eventuali vecchie righe fstab di NASPI (causavano attese al boot)
if grep -qE "^[^#].*[[:space:]]${SHARE_PATH}[[:space:]]" /etc/fstab 2>/dev/null; then
  sed -i "\|^[^#].*[[:space:]]${SHARE_PATH}[[:space:]]|d" /etc/fstab
  systemctl daemon-reload 2>/dev/null || true
fi

root_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [ "$src" = "/dev/root" ] && src="$(readlink -f /dev/root 2>/dev/null || echo /dev/mmcblk0p2)"
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)"
  [ -n "$pk" ] && { basename "$pk"; return; }
  basename "$src" | sed -E 's/p?[0-9]+$//'
}

# Dischi USB = dischi il cui percorso sysfs passa per il bus USB (affidabile anche
# dove lsblk non riporta TRAN). Mai la microSD/disco di sistema.
usb_disks() {
  local b boot real
  boot="$(root_disk)"
  for b in /sys/block/*; do
    [ -e "$b/device" ] || continue
    real="$(readlink -f "$b")"
    case "$real" in */usb[0-9]*) ;; *) continue ;; esac
    [ "$(basename "$b")" = "$boot" ] && continue
    [ "$(cat "$b/size" 2>/dev/null || echo 0)" -gt 0 ] || continue
    echo "/dev/$(basename "$b")"
  done
}

fs_type() { blkid -p -o value -s TYPE "$1" 2>/dev/null | head -1; }
size_of() { lsblk -bdno SIZE "$1" 2>/dev/null || echo 0; }

# Miglior volume montabile: la partizione più grande con FS noto
# (salta la piccola EFI FAT dei dischi formattati da Windows/Mac).
best_volume() {
  local disk="$1" dev t s best="" best_s=0
  for dev in $(lsblk -lnpo NAME "$disk" 2>/dev/null); do
    t="$(fs_type "$dev")"
    case "$t" in ext4|ext3|ext2|btrfs|xfs|exfat|ntfs|vfat) ;; *) continue ;; esac
    s="$(size_of "$dev")"
    [ "${s:-0}" -gt "$best_s" ] || continue
    best_s="$s"; best="$dev $t"
  done
  [ -n "$best" ] && echo "$best"
}

# Vuoto = nessuna firma di partizioni/FS sul disco né sulle sue partizioni,
# e il disco si legge davvero (un disco che non risponde NON è "vuoto").
disk_is_blank() {
  local disk="$1" dev
  dd if="$disk" of=/dev/null bs=1M count=4 iflag=direct status=none 2>/dev/null || return 1
  for dev in $(lsblk -lnpo NAME "$disk" 2>/dev/null); do
    [ "$dev" = "$disk" ] && continue
    [ -n "$(blkid -p -o value -s TYPE "$dev" 2>/dev/null)" ] && return 1
  done
  [ -z "$(blkid -p -o value -s TYPE "$disk" 2>/dev/null)" ] || return 1
  [ -z "$(blkid -p -o value -s PTTYPE "$disk" 2>/dev/null)" ] && return 0
  # tabella partizioni presente ma partizioni tutte senza FS → vuoto
  return 0
}

format_blank() {
  local disk="$1" part
  say "Disco ${disk} vuoto: creo partizione ext4 '${LABEL}' (nessun dato presente)"
  wipefs -a "$disk" >/dev/null 2>&1 || true
  printf 'label: gpt\n,,L\n' | sfdisk -q -w always "$disk" >/dev/null 2>&1 || return 1
  partprobe "$disk" >/dev/null 2>&1 || blockdev --rereadpt "$disk" >/dev/null 2>&1 || true
  udevadm settle -t 20 >/dev/null 2>&1 || true
  sleep 2
  part="$(lsblk -lnpo NAME,TYPE "$disk" | awk '$2=="part"{print $1; exit}')"
  [ -b "${part:-}" ] || return 1
  mkfs.ext4 -q -F -L "$LABEL" -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$part" >/dev/null 2>&1 || return 1
  udevadm settle -t 20 >/dev/null 2>&1 || true
  say "Formattato ${part} (ext4)"
}

try_mount() {
  local dev="$1" t="$2" uid gid own
  uid="$(id -u "$NAS_USER")"; gid="$(id -g "$NAS_USER")"
  own="uid=${uid},gid=${gid},umask=0002"
  case "$t" in
    ext4|ext3|ext2)
      fsck."$t" -p "$dev" >/dev/null 2>&1   # ripara dopo spegnimenti bruschi
      mount -t "$t" -o noatime,commit=60 "$dev" "$SHARE_PATH" ;;
    btrfs|xfs)
      mount -t "$t" -o noatime "$dev" "$SHARE_PATH" ;;
    exfat)
      fsck.exfat -p "$dev" >/dev/null 2>&1 || true
      mount -t exfat -o "noatime,${own}" "$dev" "$SHARE_PATH" ;;
    vfat)
      fsck.vfat -a "$dev" >/dev/null 2>&1 || true
      mount -t vfat -o "noatime,utf8,${own}" "$dev" "$SHARE_PATH" ;;
    ntfs)
      # ntfs3 (kernel) è molto più veloce di ntfs-3g (FUSE) sul Pi 1
      mount -t ntfs3 -o "noatime,${own}" "$dev" "$SHARE_PATH" 2>/dev/null \
        || mount -t ntfs-3g -o "noatime,big_writes,${own}" "$dev" "$SHARE_PATH" ;;
    *) return 1 ;;
  esac
}

# 1) già montato da un disco ancora presente → niente da fare
cur="$(findmnt -n -o SOURCE "$SHARE_PATH" 2>/dev/null || true)"
if [ -n "$cur" ]; then
  if [ -b "$cur" ] && dd if="$cur" of=/dev/null bs=4k count=1 iflag=direct status=none 2>/dev/null; then
    exit 0
  fi
  say "Disco su ${SHARE_PATH} scollegato/non risponde: smonto"
  umount "$SHARE_PATH" 2>/dev/null || umount -l "$SHARE_PATH" 2>/dev/null || true
  systemctl reload smbd 2>/dev/null || true
fi

# 2) attendi il disco (gli SSD in box USB ci mettono qualche secondo)
disks=""
i=0
while [ "$i" -le "$WAIT" ]; do
  udevadm settle -t 5 >/dev/null 2>&1 || true
  disks="$(usb_disks)"
  [ -n "$disks" ] && break
  # nessun dispositivo di archiviazione USB nemmeno in enumerazione → inutile attendere
  if [ "$i" -ge 8 ] && ! ls /sys/bus/usb/drivers/usb-storage/ /sys/bus/usb/drivers/uas/ 2>/dev/null | grep -q ':'; then
    break
  fi
  sleep 1; i=$((i + 1))
done
if [ -z "$disks" ]; then
  say "Nessun disco USB: ${SHARE_PATH} resta sulla microSD"
  exit 0
fi

# 3) scegli il volume; disco vuoto → formatta
line=""
for d in $disks; do
  line="$(best_volume "$d" || true)"
  [ -n "$line" ] && break
done
if [ -z "$line" ]; then
  for d in $disks; do
    if [ "${NASPI_AUTOFORMAT:-1}" = "1" ] && disk_is_blank "$d"; then
      format_blank "$d" || { say "Formattazione di ${d} fallita (alimentazione? usa hub alimentato)"; continue; }
      line="$(best_volume "$d" || true)"
      [ -n "$line" ] && break
    fi
  done
fi
if [ -z "$line" ]; then
  say "Disco USB presente ma senza file system leggibile e non vuoto: non tocco nulla. Per cancellarlo: sudo naspi format"
  exit 0
fi

src="${line%% *}"
fstype="${line##* }"
findmnt -n "$src" >/dev/null 2>&1 && { umount "$src" 2>/dev/null || umount -l "$src" 2>/dev/null || true; }

ok=0
for i in 1 2 3; do
  if try_mount "$src" "$fstype"; then ok=1; break; fi
  sleep 3
done
if [ "$ok" -ne 1 ]; then
  say "Montaggio di ${src} (${fstype}) fallito. Vedi: dmesg | tail -30"
  exit 1
fi

case "$fstype" in
  ext*|btrfs|xfs)
    chown "${NAS_USER}:${NAS_GROUP}" "$SHARE_PATH" 2>/dev/null || true
    chmod 2775 "$SHARE_PATH" 2>/dev/null || true ;;
esac
systemctl reload smbd 2>/dev/null || true
say "SSD USB montato su ${SHARE_PATH} (${src} ${fstype})"
exit 0
USB
  chmod 755 /usr/local/sbin/naspi-usb-mount

  # vecchia unit (con sleep fisso) → sostituita
  systemctl disable naspi-usb.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/naspi-usb.service /etc/udev/rules.d/99-naspi-usb.rules

  cat > /etc/systemd/system/naspi-usb-boot.service <<'EOF'
[Unit]
Description=NASPI: monta SSD USB su /srv/nas al boot
After=local-fs.target systemd-udev-settle.service
Before=smbd.service samba.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/naspi-usb-mount 45
TimeoutStartSec=15min
[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/naspi-usb@.service <<'EOF'
[Unit]
Description=NASPI: evento USB %i
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/naspi-usb-mount 10
TimeoutStartSec=15min
EOF

  cat > /etc/udev/rules.d/91-naspi-usb-mount.rules <<'EOF'
# NASPI: disco USB collegato/scollegato → (s)monta /srv/nas
ACTION=="add|remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd*", RUN+="/bin/systemctl --no-block start naspi-usb@%k.service"
EOF

  systemctl daemon-reload || true
  systemctl enable naspi-usb-boot.service >/dev/null 2>&1 || true
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

setup_share_dir() {
  mkdir -p "$SHARE_PATH"
  install_usb_automount
  log "Cerco SSD/HDD USB (fino a 30s)"
  /usr/local/sbin/naspi-usb-mount 30 </dev/null || warn "SSD non montato: vedi 'sudo naspi diag'"
  if findmnt -n "$SHARE_PATH" >/dev/null 2>&1; then
    log "SSD su ${SHARE_PATH}: $(findmnt -n -o SOURCE,FSTYPE "$SHARE_PATH")"
  else
    warn "Nessun SSD ora: uso la microSD. Quando colleghi l'SSD si monta da solo."
  fi
  if ! findmnt -n "$SHARE_PATH" >/dev/null 2>&1; then
    chown "${NAS_USER}:${NAS_GROUP}" "$SHARE_PATH" 2>/dev/null || true
    chmod 2775 "$SHARE_PATH" 2>/dev/null || true
  fi
}

smb_password() {
  mkdir -p "$NASPI_DIR"
  chmod 700 "$NASPI_DIR"
  if [ -f "$CRED_FILE" ]; then
    local _keep_host="$HOST_NAME" _g="${NASPI_GUEST:-}" _a="${NASPI_AUTOFORMAT:-}"
    # shellcheck disable=SC1090
    . "$CRED_FILE"
    HOST_NAME="$_keep_host"
    [ -n "$_g" ] && NASPI_GUEST="$_g"
    [ -n "$_a" ] && NASPI_AUTOFORMAT="$_a"
  fi
  case "${NASPI_PASSWORD:-}" in *"'"*|*' '*) die "NASPI_PASSWORD: niente apici o spazi" ;; esac
  [ -n "${NASPI_PASSWORD:-}" ] && SMB_PASS="$NASPI_PASSWORD"
  if [ -z "${SMB_PASS:-}" ]; then
    # 12 caratteri da /dev/urandom (niente caratteri ambigui)
    SMB_PASS="$(LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789' </dev/urandom | head -c 12 || true)"
  fi
  [ ${#SMB_PASS} -ge 8 ] || die "Generazione password fallita"
  save_creds
}

save_creds() {
  mkdir -p "$NASPI_DIR"
  chmod 700 "$NASPI_DIR"
  cat > "$CRED_FILE" <<EOF
HOST_NAME=${HOST_NAME}
NAS_USER=${NAS_USER}
SMB_PASS='${SMB_PASS}'
SHARE_NAME=${SHARE_NAME}
SHARE_PATH=${SHARE_PATH}
NASPI_GUEST=${NASPI_GUEST:-0}
NASPI_AUTOFORMAT=${NASPI_AUTOFORMAT:-1}
EOF
  [ "${TS_USERSPACE:-0}" = "1" ] && echo "TS_USERSPACE=1" >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

write_smb_conf() {
  local guest="no" mapg="Never"
  if [ "${NASPI_GUEST:-0}" = "1" ]; then guest="yes"; mapg="Bad User"; fi
  local marker="# naspi-conf v3 guest=${guest}"
  if [ -f /etc/samba/smb.conf ] \
    && grep -qF "$marker" /etc/samba/smb.conf \
    && pdbedit -L 2>/dev/null | grep -q "^${NAS_USER}:"; then
    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -s "$NAS_USER" >/dev/null 2>&1 || true
    skip "Samba già configurato"
    return 0
  fi
  log "Configurazione Samba"
  if [ -f /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf.naspi.bak ]; then
    cp -a /etc/samba/smb.conf /etc/samba/smb.conf.naspi.bak
  fi

  cat > /etc/samba/smb.conf <<EOF
${marker}
# Generato da NASPI: rilancia install.sh per rigenerarlo (backup: smb.conf.naspi.bak)
[global]
   workgroup = WORKGROUP
   server string = ${HOST_NAME}
   netbios name = ${HOST_NAME}
   server role = standalone server
   security = user
   map to guest = ${mapg}
   dns proxy = no
   log file = /var/log/samba/log.%m
   max log size = 50
   logging = syslog@1 file
   server min protocol = SMB2_02
   deadtime = 15
   getwd cache = yes
   socket options = TCP_NODELAY IPTOS_LOWDELAY
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

[${SHARE_NAME}]
   path = ${SHARE_PATH}
   comment = ${HOST_NAME}
   browseable = yes
   read only = no
   writable = yes
   guest ok = ${guest}
   valid users = ${NAS_USER}$( [ "$guest" = "yes" ] && echo " nobody" )
   create mask = 0664
   directory mask = 0775
   force user = ${NAS_USER}
   force group = ${NAS_GROUP}
   hide files = /lost+found/
EOF

  if ! pdbedit -L 2>/dev/null | grep -q "^${NAS_USER}:"; then
    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -a -s "$NAS_USER" >/dev/null \
      || die "smbpasswd fallito per utente ${NAS_USER}"
  else
    printf '%s\n%s\n' "$SMB_PASS" "$SMB_PASS" | smbpasswd -s "$NAS_USER" >/dev/null || true
  fi

  testparm -s >/dev/null 2>&1 || warn "testparm ha avvisi, continuo"
}

write_avahi() {
  if [ -f /etc/avahi/services/naspi.service ] \
    && grep -q '_smb._tcp' /etc/avahi/services/naspi.service; then
    skip "Avahi già configurato"
    return 0
  fi
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
  if [ -f /etc/modules-load.d/tun.conf ] \
    && [ -f /etc/systemd/system/smbd.service.d/naspi.conf ]; then
    skip "servizi al boot"
    return 0
  fi
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
  systemctl daemon-reload || true
}

start_samba() {
  enable_boot
  systemctl enable smbd nmbd avahi-daemon >/dev/null 2>&1 || true
  systemctl enable samba >/dev/null 2>&1 || true
  if systemctl is-active --quiet smbd || systemctl is-active --quiet samba; then
    skip "Samba già avviato"
    return 0
  fi
  log "Avvio Samba"
  if ! run_to 60 systemctl restart smbd >/dev/null 2>&1; then
    run_to 60 systemctl restart samba >/dev/null 2>&1 \
      || die "Samba non parte. Log: $(journalctl -u smbd -n 15 --no-pager 2>/dev/null | tail -5)"
  fi
  run_to 20 systemctl restart nmbd >/dev/null 2>&1 || true
  run_to 20 systemctl restart avahi-daemon >/dev/null 2>&1 || true
}

bin_runs() {
  local bin="$1"
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "$bin" version >/dev/null 2>&1 \
      || timeout 5 "$bin" --version >/dev/null 2>&1 \
      || timeout 5 "$bin" -version >/dev/null 2>&1
  else
    "$bin" version >/dev/null 2>&1 \
      || "$bin" --version >/dev/null 2>&1 \
      || "$bin" -version >/dev/null 2>&1
  fi
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
      if http_get "$url" "$tgz"; then
        break
      fi
      rm -f "$tgz"
    done
    [ -f "$tgz" ] || return 1
  fi
  dir="$(mktemp -d)"
  tar -xzf "$tgz" -C "$dir"
  local unpacked
  unpacked="$(find "$dir" -maxdepth 1 -mindepth 1 -type d -name 'tailscale_*' -print -quit 2>/dev/null || true)"
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
  systemctl daemon-reload || true
}

latest_static_ver() {
  http_pipe "https://pkgs.tailscale.com/stable/" 2>/dev/null \
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
  systemctl daemon-reload || true
  systemctl enable tailscaled >/dev/null 2>&1 || true
  run_to 45 systemctl restart tailscaled || true
  sleep 2
  systemctl is-active --quiet tailscaled
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    if bin_runs tailscale; then
      if systemctl is-active --quiet tailscaled || start_tailscaled; then
        skip "Tailscale già installato"
        return 0
      fi
    fi
  fi

  run_to 8 timedatectl set-ntp true >/dev/null 2>&1 || true

  if ! is_armv6; then
    log "Installazione Tailscale (script ufficiale, max 3 min)"
    if http_get https://tailscale.com/install.sh /tmp/naspi-ts-install.sh \
      && run_to 180 sh /tmp/naspi-ts-install.sh; then
      if start_tailscaled; then
        return 0
      fi
    fi
    warn "Script ufficiale fallito, uso il binario statico"
    local latest
    latest="$(latest_static_ver || true)"
    [ -n "$latest" ] || latest="1.86.4"
    install_static_tailscale "$latest" "$(ts_arch)" || die "Download Tailscale fallito"
    if start_tailscaled; then
      return 0
    fi
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
  local state
  state="$(ts_state || true)"
  if [ "$state" = "Running" ]; then
    skip "Tailscale già connesso"
    return 0
  fi

  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    log "Tailscale: autenticazione con auth key"
    run_to 40 tailscale up --auth-key="$TAILSCALE_AUTHKEY" --accept-dns=false --hostname="$HOST_NAME" \
      || run_to 40 tailscale up --authkey="$TAILSCALE_AUTHKEY" --accept-dns=false --hostname="$HOST_NAME" \
      || warn "Auth key rifiutata: userai il link nel riepilogo"
    return 0
  fi

  log "Nuovo link Tailscale (il precedente scade in pochi minuti)"
  rm -f "${NASPI_DIR}/tailscale.url"
  run_to 15 tailscale logout >/dev/null 2>&1 || true
  run_to 25 tailscale up --accept-dns=false --hostname="$HOST_NAME" >/tmp/naspi-tailscale.up 2>&1 || true
}

wait_tailscale_login() {
  local state url i
  state="$(ts_state || true)"
  if [ "$state" = "Running" ]; then
    return 0
  fi
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    return 0
  fi

  url=""
  for i in 1 2 3 4; do
    url="$(ts_authurl || true)"
    if [ -z "$url" ] && [ -f /tmp/naspi-tailscale.up ]; then
      url="$(grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' /tmp/naspi-tailscale.up | head -1 || true)"
    fi
    [ -n "$url" ] && break
    sleep 1
  done

  if [ -z "$url" ]; then
    warn "Nessun URL di login: dopo l'installazione esegui: sudo tailscale up"
    return 0
  fi

  echo "$url" > "${NASPI_DIR}/tailscale.url"
  echo
  echo "----------------------------------------------"
  echo "  LOGIN TAILSCALE (apri questo link)"
  echo "  ${url}"
  echo "----------------------------------------------"
  log "Non resto in attesa. Se il link è scaduto: sudo naspi login"
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

if [ "${1:-}" = "login" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "Esegui: sudo naspi login"; exit 1; }
  echo
  echo "Genero un nuovo link Tailscale (il vecchio scade in pochi minuti)..."
  rm -f /etc/naspi/tailscale.url
  tailscale logout >/dev/null 2>&1 || true
  if command -v timeout >/dev/null 2>&1; then
    timeout 25 tailscale up --accept-dns=false --hostname="${HOST_NAME}" >/tmp/naspi-tailscale.up 2>&1 || true
  else
    tailscale up --accept-dns=false --hostname="${HOST_NAME}" >/tmp/naspi-tailscale.up 2>&1 || true
  fi
  url=""
  i=0
  while [ "$i" -lt 8 ]; do
    url="$(tailscale status --json 2>/dev/null | tr -d '\n' \
      | sed -n 's/.*"AuthURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
    if [ -z "$url" ] && [ -f /tmp/naspi-tailscale.up ]; then
      url="$(grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' /tmp/naspi-tailscale.up | head -1 || true)"
    fi
    [ -n "$url" ] && break
    sleep 1
    i=$((i + 1))
  done
  if [ -n "$url" ]; then
    echo "$url" > /etc/naspi/tailscale.url
    echo
    echo "----------------------------------------------"
    echo "  LOGIN TAILSCALE (apri questo link ORA)"
    echo "  ${url}"
    echo "----------------------------------------------"
  else
    echo "Nessun URL. Prova: sudo tailscale logout && sudo tailscale up"
  fi
  exit 0
fi

need_root() { [ "$(id -u)" -eq 0 ] || { echo "Esegui: sudo naspi $1"; exit 1; }; }

power_report() {
  local t
  if command -v vcgencmd >/dev/null 2>&1; then
    t="$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')"
    case "$t" in
      0x0|"") echo "  Alimentazione: OK (nessun sotto-tensione rilevato)" ;;
      *)
        if [ $(( t & 0x1 )) -ne 0 ]; then
          echo "  Alimentazione: SOTTO-TENSIONE ADESSO ($t) → disco instabile/riavvii"
        elif [ $(( t & 0x10000 )) -ne 0 ]; then
          echo "  Alimentazione: c'è stata SOTTO-TENSIONE dall'avvio ($t)"
        else
          echo "  Alimentazione: throttling ($t)"
        fi
        echo "    → alimentatore 5V ≥2.5A buono + SSD su hub USB ALIMENTATO o cavo Y"
        ;;
    esac
  fi
  if journalctl -k -b 0 --no-pager 2>/dev/null | grep -qiE 'under-?voltage'; then
    echo "  Kernel: segnalata sotto-tensione in questo avvio"
  fi
}

if [ "${1:-}" = "mount" ]; then
  need_root mount
  /usr/local/sbin/naspi-usb-mount 20
  findmnt "$SHARE_PATH" || echo "SSD non montato: sudo naspi diag"
  exit 0
fi

if [ "${1:-}" = "format" ]; then
  need_root format
  shift
  exec /usr/local/sbin/naspi-format "$@"
fi

if [ "${1:-}" = "diag" ]; then
  need_root diag
  echo
  echo "== Modello: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
  echo "== Uptime: $(uptime -p 2>/dev/null)"
  power_report
  echo
  echo "== Dischi"
  lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null
  echo
  echo "== /srv/nas"
  findmnt "$SHARE_PATH" || echo "  non montato (microSD)"
  df -h "$SHARE_PATH" | tail -1
  echo
  echo "== USB"
  lsusb 2>/dev/null || true
  echo
  echo "== Ultimi eventi NASPI USB"
  journalctl -t naspi-usb -n 15 --no-pager 2>/dev/null || true
  echo
  echo "== Kernel: USB/disco (reset, disconnessioni, errori I/O)"
  journalctl -k -b 0 --no-pager 2>/dev/null \
    | grep -iE 'usb [0-9-]+.*(disconnect|reset|new)|under-?voltage|I/O error|EXT4-fs error|over-current|uas|usb-storage' \
    | tail -20 || true
  if journalctl --list-boots --no-pager 2>/dev/null | grep -q '^ *-1'; then
    echo
    echo "== Fine dell'avvio precedente (se si è riavviato da solo, guarda qui)"
    journalctl -b -1 -n 8 --no-pager 2>/dev/null || true
  fi
  echo
  echo "== Servizi"
  for s in smbd nmbd avahi-daemon tailscaled; do
    printf '  %-14s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  exit 0
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
echo "  SSD USB: collegalo e si monta da solo su /srv/nas (ext4/exFAT/NTFS/FAT)."
echo "  Disco nuovo/vuoto: formattato ext4 in automatico. Con dati: mai toccato."
echo "  Pi 1: SSD su hub USB ALIMENTATO (o cavo Y) + alimentatore 5V ≥2.5A,"
echo "  altrimenti il Pi si riavvia o perde il disco (limite hardware)."
if [ "$(id -u)" -eq 0 ]; then power_report; fi
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
    echo "    Apri questo link SUBITO (scade in pochi minuti):"
    echo "         ${ts_url}"
    echo "    Se dice Session expired:  sudo naspi login"
    echo "    Poi sul PC: https://tailscale.com/download (stesso account)"
    echo "    Percorso:  \\\\${HOST_NAME}\\${SHARE_NAME}"
    echo "    Alla fine:  sudo naspi"
  else
    echo "    Sul Pi:  sudo naspi login"
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
echo "  Nuovo link Tailscale:     sudo naspi login"
echo "  Problemi SSD/riavvii:     sudo naspi diag"
echo "  Rimonta SSD:              sudo naspi mount"
echo "  Cancella e formatta SSD:  sudo naspi format"
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

install_format_tool() {
  local here="" tmp
  [ -n "${_NASPI_SRC_DIR:-}" ] && here="${_NASPI_SRC_DIR}/format-usb.sh"
  if [ -n "$here" ] && [ -f "$here" ]; then
    tr -d '\r' < "$here" > /usr/local/sbin/naspi-format
  else
    tmp="$(mktemp)"
    if http_get "${REPO_RAW}/format-usb.sh" "$tmp"; then
      tr -d '\r' < "$tmp" > /usr/local/sbin/naspi-format
    else
      warn "format-usb.sh non scaricabile: 'sudo naspi format' non disponibile"
    fi
    rm -f "$tmp"
  fi
  [ -f /usr/local/sbin/naspi-format ] && chmod 755 /usr/local/sbin/naspi-format
  return 0
}

print_report() {
  /usr/local/bin/naspi
  if [ "${BOOT_CHANGED:-0}" = "1" ]; then
    echo
    warn "Impostazioni USB di avvio aggiornate: riavvia una volta il Pi (sudo reboot)"
    warn "per applicarle del tutto. Dopo il riavvio tutto riparte da solo."
  fi
}

main() {
  need_root
  detect_user
  set_hostname
  log "Utente Samba: ${NAS_USER}  (i passi già fatti vengono saltati)"
  ensure_swap
  lower_gpu_mem
  usb_ssd_stable
  tune_system
  apt_ok
  smb_password
  setup_share_dir
  save_creds
  write_smb_conf
  write_avahi
  start_samba
  write_cli
  install_format_tool
  install_tailscale
  systemctl enable tailscaled >/dev/null 2>&1 || true
  bring_up_tailscale
  wait_tailscale_login
  print_report
  log "Fatto. Riepilogo: sudo naspi    Link nuovo: sudo naspi login"
}

main "$@"
