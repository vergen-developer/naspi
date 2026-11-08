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
INSTALL_LOG=/var/log/naspi-install.log

# Libreria grafica VERGEN: usata qui e installata in /usr/local/lib/naspi/ui.sh
# (comando naspi, schermata di login SSH)
NASPI_UI=""
IFS= read -r -d '' NASPI_UI <<'NASPIUI' || true
# NASPI · VERGEN TECHNOLOGY — libreria grafica terminale (condivisa)
NASPI_VERSION="6.0"
NASPI_BRAND="VERGEN TECHNOLOGY"
NASPI_W=60
if { [ -t 1 ] || [ "${NASPI_FORCE_COLOR:-0}" = "1" ]; } && [ -z "${NO_COLOR:-}" ] \
  && { [ "${NASPI_FORCE_COLOR:-0}" = "1" ] || [ "${TERM:-dumb}" != "dumb" ]; }; then
  _e=$'\033'
  C0="${_e}[0m"; CB="${_e}[1m"
  CA1="${_e}[38;5;27m"; CA2="${_e}[38;5;33m"; CA3="${_e}[38;5;39m"; CA4="${_e}[38;5;45m"; CA5="${_e}[38;5;51m"
  CA="$CA3"; COK="${_e}[38;5;42m"; CW="${_e}[38;5;214m"; CE="${_e}[38;5;203m"; CM="${_e}[38;5;245m"
  unset _e
else
  C0=""; CB=""; CA1=""; CA2=""; CA3=""; CA4=""; CA5=""; CA=""; COK=""; CW=""; CE=""; CM=""
fi

# ripete un carattere (anche multibyte) n volte, indipendente dal locale
ui_rep() { local i=0 s=""; while [ "$i" -lt "$2" ]; do s="$s$1"; i=$((i + 1)); done; printf '%s' "$s"; }

ui_cols() {
  local c
  c="$( (stty size </dev/tty) 2>/dev/null | awk '{print $2}')"
  echo "${c:-80}"
}

ui_banner() {
  local sub="${1:-NAS per Raspberry Pi}"
  printf '\n'
  if [ "$(ui_cols)" -ge 58 ]; then
    printf '  %s%s%s\n' "$CA1" '██╗   ██╗███████╗██████╗  ██████╗ ███████╗███╗   ██╗' "$C0"
    printf '  %s%s%s\n' "$CA2" '██║   ██║██╔════╝██╔══██╗██╔════╝ ██╔════╝████╗  ██║' "$C0"
    printf '  %s%s%s\n' "$CA3" '██║   ██║█████╗  ██████╔╝██║  ███╗█████╗  ██╔██╗ ██║' "$C0"
    printf '  %s%s%s\n' "$CA4" '╚██╗ ██╔╝██╔══╝  ██╔══██╗██║   ██║██╔══╝  ██║╚██╗██║' "$C0"
    printf '  %s%s%s\n' "$CA5" ' ╚████╔╝ ███████╗██║  ██║╚██████╔╝███████╗██║ ╚████║' "$C0"
    printf '  %s%s%s\n' "$CM"  '  ╚═══╝  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝' "$C0"
    printf '  %s                T E C H N O L O G Y%s\n' "$CB" "$C0"
  else
    printf '  %s%sV E R G E N%s\n' "$CB" "$CA" "$C0"
    printf '  %sT E C H N O L O G Y%s\n' "$CB" "$C0"
  fi
  printf '\n  %sNASPI%s %sv%s%s  %s·%s  %s\n' "$CB$CA" "$C0" "$CM" "$NASPI_VERSION" "$C0" "$CM" "$C0" "$sub"
  printf '  %s%s%s\n' "$CA1" "$(ui_rep '━' "$NASPI_W")" "$C0"
}

ui_header() {   # intestazione compatta (login SSH)
  printf '\n  %s▌%s %sVERGEN%s %sTECHNOLOGY%s  %s·%s  %sNASPI%s %s%s%s\n' \
    "$CA" "$C0" "$CB" "$C0" "$CM" "$C0" "$CM" "$C0" "$CB$CA" "$C0" "$CM" "${1:-}" "$C0"
}

ui_section() {
  local t="$1" n=$(( NASPI_W - ${#1} - 3 ))
  [ "$n" -lt 4 ] && n=4
  printf '\n  %s▌%s %s%s%s %s%s%s\n' "$CA" "$C0" "$CB" "$t" "$C0" "$CM" "$(ui_rep '─' "$n")" "$C0"
}

ui_step() {     # ui_step 2 6 "Titolo"
  printf '\n  %s%s %s/%s %s  %s%s%s\n' "$CB$CA" "■" "$1" "$2" "$C0" "$CB" "$3" "$C0"
}

ui_kv() {       # ui_kv "Etichetta" "valore" [colore]
  printf '    %s%-13s%s %s%s%s\n' "$CM" "$1" "$C0" "${3:-}" "$2" "$C0"
}

ui_dot() {      # ui_dot ok|warn|err "testo"
  local c="$COK"
  case "$1" in warn) c="$CW" ;; err) c="$CE" ;; off) c="$CM" ;; esac
  printf '%s●%s %s' "$c" "$C0" "$2"
}

ui_bar() {      # ui_bar percentuale [larghezza]
  local p="${1:-0}" w="${2:-30}" f c="$COK"
  case "$p" in ''|*[!0-9]*) p=0 ;; esac
  [ "$p" -gt 100 ] && p=100
  f=$(( p * w / 100 ))
  [ "$p" -ge 75 ] && c="$CW"
  [ "$p" -ge 90 ] && c="$CE"
  printf '%s%s%s%s%s' "$c" "$(ui_rep '█' "$f")" "$CM" "$(ui_rep '░' $(( w - f )))" "$C0"
}

ui_footer() {
  printf '\n  %s%s%s\n' "$CM" "$(ui_rep '─' "$NASPI_W")" "$C0"
  printf '  %s%s%s %s· NASPI v%s · vergen.it%s\n\n' "$CB" "$NASPI_BRAND" "$C0" "$CM" "$NASPI_VERSION" "$C0"
}

log()  { printf '    %s›%s %s\n' "$CA" "$C0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$COK" "$C0" "$*"; }
skip() { printf '    %s✓%s %s%s (già fatto)%s\n' "$COK" "$C0" "$CM" "$*" "$C0"; }
warn() { printf '    %s!%s %s%s%s\n' "$CW" "$C0" "$CW" "$*" "$C0"; }
die()  { printf '\n    %s✗ %s%s\n\n' "$CE$CB" "$*" "$C0" >&2; exit 1; }
NASPIUI
eval "$NASPI_UI"

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
  tr -d '\0' 2>/dev/null </proc/device-tree/model || echo "sconosciuto"
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
    log "Installo ${CB}$p${C0} ${CM}(sul Pi 1 anche qualche minuto)${C0}"
    if DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" --fix-missing "$p" </dev/null >>"$INSTALL_LOG" 2>&1; then
      ok "$p"
      set -e
      return 0
    fi
    warn "$p non disponibile, provo un'alternativa (dettagli: $INSTALL_LOG)"
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
  log "Aggiorno l'elenco dei pacchetti (attendi)"
  preseed_debconf
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a </dev/null >>"$INSTALL_LOG" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -f install -y </dev/null >>"$INSTALL_LOG" 2>&1 || true
  local opts=(-o Acquire::Check-Valid-Until=false -o Acquire::AllowReleaseInfoChange=true -o Acquire::Retries=3)
  if ! DEBIAN_FRONTEND=noninteractive apt-get update "${opts[@]}" </dev/null >>"$INSTALL_LOG" 2>&1; then
    warn "Rete instabile, riprovo"
    DEBIAN_FRONTEND=noninteractive apt-get update "${opts[@]}" </dev/null >>"$INSTALL_LOG" 2>&1       || warn "Uso l'elenco pacchetti gia presente"
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
  ok "Pacchetti pronti"
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
  local marker="# naspi-conf v4 guest=${guest}"
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
   server string = ${HOST_NAME} - NASPI by VERGEN TECHNOLOGY
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
    && grep -q '_http._tcp' /etc/avahi/services/naspi.service; then
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
    <type>_http._tcp</type>
    <port>80</port>
    <txt-record>path=/</txt-record>
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
      && run_to 180 sh /tmp/naspi-ts-install.sh >>"$INSTALL_LOG" 2>&1; then
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
  ok "Link di accesso pronto: è nel riepilogo qui sotto (scaduto? sudo naspi login)"
}

write_ui_lib() {
  mkdir -p /usr/local/lib/naspi
  printf '%s' "$NASPI_UI" > /usr/local/lib/naspi/ui.sh
  chmod 644 /usr/local/lib/naspi/ui.sh
}

write_cli() {
  cat > /usr/local/bin/naspi <<'CLI'
#!/bin/bash
# NASPI · VERGEN TECHNOLOGY — comando di gestione del NAS
set -uo pipefail
CRED=/etc/naspi/credentials
HOST_NAME=mariarosaria
SHARE_NAME=nas
SHARE_PATH=/srv/nas
NAS_USER=pi
SMB_PASS=""
WWW=/var/lib/naspi/www
[ -r "$CRED" ] && . "$CRED"
. /usr/local/lib/naspi/ui.sh 2>/dev/null || { echo "NASPI: libreria grafica mancante, rilancia install.sh"; exit 1; }
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
BS='\'
WIN_PATH="${BS}${BS}${HOST_NAME}${BS}${SHARE_NAME}"

need_root() { [ "$IS_ROOT" = "1" ] || die "Serve root: sudo naspi ${1:-}"; }
to() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }

# ---------------------------------------------------------------- stato
collect() {
  S_MODEL="$(tr -d '\0' 2>/dev/null </proc/device-tree/model || uname -m)"
  S_LANIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  S_UP="$(uptime -p 2>/dev/null | sed 's/^up //; s/ hours\?/ h/; s/ minutes\?/ min/; s/ days\?/ g/; s/ weeks\?/ sett/')"
  local t
  t="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)"
  S_TEMP=""; [ -n "$t" ] && S_TEMP="$((t / 1000))"
  S_MEM="$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d / %d MB", $3, $2}')"

  S_SIZE="?"; S_USED="?"; S_AVAIL="?"; S_PCT=0
  read -r S_SIZE S_USED S_AVAIL S_PCT < <(df -Ph "$SHARE_PATH" 2>/dev/null \
    | awk 'NR==2{gsub("%","",$5); print $2, $3, $4, $5}') || true
  case "${S_PCT:-}" in ''|*[!0-9]*) S_PCT=0 ;; esac
  S_SIZE="${S_SIZE:-?}"; S_USED="${S_USED:-?}"; S_AVAIL="${S_AVAIL:-?}"
  S_SRC="$(findmnt -n -o SOURCE "$SHARE_PATH" 2>/dev/null || true)"
  S_FS="$(findmnt -n -o FSTYPE "$SHARE_PATH" 2>/dev/null || true)"
  S_DISKNAME=""
  if [ -n "$S_SRC" ]; then
    local pk
    pk="$(lsblk -no PKNAME "$S_SRC" 2>/dev/null | head -1)"
    S_DISKNAME="$(lsblk -dno VENDOR,MODEL "/dev/${pk:-$(basename "$S_SRC")}" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
  fi

  S_SMB="$(systemctl is-active smbd 2>/dev/null || true)"
  [ "$S_SMB" = "active" ] || S_SMB="$(systemctl is-active samba 2>/dev/null || echo inactive)"
  local j
  j="$(to 4 tailscale status --json 2>/dev/null | tr -d '\n' || true)"
  S_TS="$(printf '%s' "$j" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  S_TSURL="$(printf '%s' "$j" | sed -n 's/.*"AuthURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  S_TSDNS="$(printf '%s' "$j" | sed -n 's/.*"Self"[[:space:]]*:[[:space:]]*{[^}]*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  S_TSDNS="${S_TSDNS%.}"
  S_TSIP="$(to 4 tailscale ip -4 2>/dev/null | head -1 || true)"
  [ -n "$S_TSURL" ] || S_TSURL="$(cat /etc/naspi/tailscale.url 2>/dev/null || true)"

  S_PWR="na"
  if command -v vcgencmd >/dev/null 2>&1; then
    t="$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')"
    case "$t" in
      0x0) S_PWR="ok" ;;
      0x*) if [ $(( t & 0x1 )) -ne 0 ]; then S_PWR="now"
           elif [ $(( t & 0x10000 )) -ne 0 ]; then S_PWR="past"
           else S_PWR="thr"; fi ;;
    esac
  fi
  if [ "$S_PWR" != "now" ] && journalctl -k -b 0 --no-pager 2>/dev/null | grep -qiE 'under-?voltage'; then
    S_PWR="past"
  fi
}

pwr_text() {
  case "$S_PWR" in
    ok)   echo "ok|stabile" ;;
    now)  echo "err|SOTTO-TENSIONE ora: alimentatore/cavo Y" ;;
    past) echo "warn|cali di tensione dall'avvio: controlla alimentatore/cavo Y" ;;
    thr)  echo "warn|CPU rallentata (temperatura)" ;;
    *)    echo "off|non misurabile su questo modello" ;;
  esac
}

ts_text() {
  case "$S_TS" in
    Running)   echo "ok|connesso${S_TSIP:+ · $S_TSIP}" ;;
    NeedsLogin|NoState) echo "warn|da collegare: sudo naspi login" ;;
    Stopped)   echo "warn|fermo: sudo tailscale up" ;;
    "")        echo "err|non attivo" ;;
    *)         echo "warn|$S_TS" ;;
  esac
}

disk_text() {
  if [ -n "$S_SRC" ]; then
    echo "ok|SSD esterno${S_DISKNAME:+ $S_DISKNAME} · ${S_FS}"
  else
    echo "warn|microSD (SSD non collegato)"
  fi
}

dot_line() { local x="$1"; ui_dot "${x%%|*}" "${x#*|}"; }

# ---------------------------------------------------------------- comandi
cmd_login() {
  need_root login
  ui_header "Accesso remoto"
  log "Genero un nuovo link Tailscale (il precedente scade in pochi minuti)"
  rm -f /etc/naspi/tailscale.url
  tailscale logout >/dev/null 2>&1 || true
  to 25 tailscale up --accept-dns=false --hostname="${HOST_NAME}" </dev/null >/tmp/naspi-tailscale.up 2>&1 || true
  local url="" i=0
  while [ "$i" -lt 8 ]; do
    url="$(tailscale status --json 2>/dev/null | tr -d '\n' \
      | sed -n 's/.*"AuthURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -z "$url" ] && url="$(grep -oE 'https://login\.tailscale\.com/[^[:space:]]+' /tmp/naspi-tailscale.up 2>/dev/null | head -1 || true)"
    [ -n "$url" ] && break
    sleep 1; i=$((i + 1))
  done
  if [ -n "$url" ]; then
    echo "$url" > /etc/naspi/tailscale.url
    ui_section "Apri questo link ORA"
    printf '\n    %s%s%s\n\n' "$CB$CA" "$url" "$C0"
    log "Accedi e approva, poi installa Tailscale sul PC con lo stesso account"
  elif [ "$(tailscale status --json 2>/dev/null | tr -d '\n' | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" = "Running" ]; then
    ok "Tailscale già connesso"
  else
    warn "Nessun link ricevuto. Prova: sudo tailscale logout && sudo tailscale up"
  fi
  ui_footer
}

cmd_summary() {
  collect
  ui_banner "${HOST_NAME}"
  ui_section "Stato"
  printf '    '; dot_line "ok|online"; printf '   %s%s%s\n' "$CM" "${S_LANIP:-senza rete}" "$C0"
  ui_kv "Disco" "$(dot_line "$(disk_text)")"
  printf '    %-13s %s  %s%s%%%s  %s%s usati di %s · %s liberi%s\n' "" "$(ui_bar "$S_PCT" 24)" "$CB" "$S_PCT" "$C0" "$CM" "$S_USED" "$S_SIZE" "$S_AVAIL" "$C0"
  ui_kv "Condivisione" "$(if [ "$S_SMB" = active ]; then ui_dot ok attiva; else ui_dot err "ferma: sudo systemctl restart smbd"; fi)"
  ui_kv "Fuori casa" "$(dot_line "$(ts_text)")"
  ui_kv "Alimentazione" "$(dot_line "$(pwr_text)")"

  ui_section "Credenziali"
  ui_kv "Utente" "$NAS_USER" "$CB"
  if [ "$IS_ROOT" = "1" ] && [ -n "$SMB_PASS" ]; then
    ui_kv "Password" "$SMB_PASS" "$CB"
  else
    ui_kv "Password" "visibile con: sudo naspi" "$CM"
  fi

  ui_section "Collegati dalla stessa rete"
  ui_kv "Windows" "$WIN_PATH" "$CB$CA"
  ui_kv "Mac" "smb://${HOST_NAME}.local/${SHARE_NAME}" "$CB$CA"
  ui_kv "Pannello web" "http://${HOST_NAME}.local" "$CB$CA"
  ui_kv "Unita Z:" "net use Z: ${WIN_PATH} /user:${NAS_USER} * /persistent:yes" "$CM"

  ui_section "Collegati da fuori casa"
  if [ "$S_TS" = "Running" ]; then
    ui_kv "1." "installa Tailscale sul PC: tailscale.com/download"
    ui_kv "2." "accedi con lo STESSO account del NAS"
    ui_kv "3. Windows" "$WIN_PATH" "$CB$CA"
    [ -n "$S_TSDNS" ] && ui_kv "   oppure" "${BS}${BS}${S_TSDNS}${BS}${SHARE_NAME}" "$CA"
  elif [ -n "$S_TSURL" ]; then
    ui_kv "Link login" "$S_TSURL" "$CB$CA"
    ui_kv "" "scaduto? sudo naspi login" "$CM"
  else
    ui_kv "Attiva" "sudo naspi login" "$CB"
  fi
  if grep -q 'TS_USERSPACE=1' "$CRED" 2>/dev/null; then
    ui_kv "Nota" "modalita userspace: se non apre usa ${HOST_NAME}.local in LAN" "$CM"
  fi

  ui_section "Comandi"
  ui_kv "sudo naspi" "questo riepilogo"
  ui_kv "naspi login" "nuovo link per l'accesso da fuori casa"
  ui_kv "naspi diag" "diagnosi SSD, alimentazione, servizi"
  ui_kv "naspi mount" "rimonta l'SSD"
  ui_kv "naspi format" "cancella e formatta l'SSD"
  ui_footer
}

cmd_motd() {
  collect
  ui_header "${HOST_NAME}"
  printf '    %s  %s%s%%%s %s(%s liberi)%s   %s\n' "$(ui_bar "$S_PCT" 20)" "$CB" "$S_PCT" "$C0" "$CM" "$S_AVAIL" "$C0" "$(dot_line "$(disk_text)")"
  printf '    %s   %s   %s\n' \
    "$(if [ "$S_SMB" = active ]; then ui_dot ok "Condivisione"; else ui_dot err "Condivisione ferma"; fi)" \
    "$(x="$(ts_text)"; ui_dot "${x%%|*}" "Tailscale")" \
    "$(x="$(pwr_text)"; ui_dot "${x%%|*}" "Alimentazione")"
  printf '    %s%s  ·  http://%s.local  ·  sudo naspi%s\n\n' "$CM" "$WIN_PATH" "$HOST_NAME" "$C0"
}

cmd_mount() {
  need_root mount
  ui_header "SSD"
  /usr/local/sbin/naspi-usb-mount 20 </dev/null | sed 's/^naspi-usb: /    › /'
  if findmnt -n "$SHARE_PATH" >/dev/null 2>&1; then
    ok "SSD montato: $(findmnt -n -o SOURCE,FSTYPE "$SHARE_PATH")"
  else
    warn "SSD non montato: sudo naspi diag"
  fi
  echo
}

cmd_diag() {
  need_root diag
  collect
  ui_banner "Diagnosi"
  ui_section "Sistema"
  ui_kv "Modello" "$S_MODEL"
  ui_kv "Acceso da" "${S_UP:-?}"
  ui_kv "Temperatura" "${S_TEMP:-?} °C"
  ui_kv "Memoria" "${S_MEM:-?}"
  ui_kv "Alimentazione" "$(dot_line "$(pwr_text)")"
  case "$S_PWR" in now|past)
    ui_kv "" "alimentatore 5V ≥2.5A + SSD con cavo Y su caricatore a parte" "$CW" ;;
  esac
  ui_section "Dischi"
  lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
  ui_section "Cartella condivisa"
  ui_kv "Disco" "$(dot_line "$(disk_text)")"
  ui_kv "Spazio" "$(ui_bar "$S_PCT" 24) ${S_PCT}%  (${S_USED} / ${S_SIZE})"
  ui_section "USB"
  (lsusb 2>/dev/null || echo "lsusb non disponibile") | sed 's/^/    /'
  ui_section "Eventi SSD (NASPI)"
  journalctl -t naspi-usb -n 12 --no-pager -o short 2>/dev/null | sed 's/^/    /' || true
  ui_section "Kernel: USB / disco"
  local k
  k="$(journalctl -k -b 0 --no-pager -o short 2>/dev/null \
    | grep -iE 'usb [0-9-]+.*(disconnect|reset)|under-?voltage|I/O error|EXT4-fs error|over-current|blk_update_request' \
    | tail -15 || true)"
  if [ -n "$k" ]; then printf '%s\n' "$k" | sed 's/^/    /'; else ok "nessun errore USB/disco in questo avvio"; fi
  if journalctl --list-boots --no-pager 2>/dev/null | grep -qE '^[[:space:]]*-1'; then
    ui_section "Fine dell'avvio precedente"
    journalctl -b -1 -n 6 --no-pager -o short 2>/dev/null | sed 's/^/    /' || true
    log "Righe normali di spegnimento = riavvio voluto; righe a caso = blackout/calo di tensione"
  fi
  ui_section "Servizi"
  local s st
  for s in smbd nmbd avahi-daemon tailscaled naspi-web naspi-usb-boot; do
    st="$(systemctl is-active "$s" 2>/dev/null || true)"
    case "$st" in
      active) ui_kv "$s" "$(ui_dot ok attivo)" ;;
      inactive) if [ "$s" = naspi-usb-boot ]; then ui_kv "$s" "$(ui_dot ok eseguito)"; else ui_kv "$s" "$(ui_dot err fermo)"; fi ;;
      *) ui_kv "$s" "$(ui_dot warn "${st:-?}")" ;;
    esac
  done
  ui_footer
}

h() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

cmd_web() {
  need_root web
  collect
  mkdir -p "$WWW"
  local d sm ts pw dk overall overall_c tsrow
  d="$(date '+%d/%m/%Y %H:%M')"
  local temp_txt="–"; [ -n "$S_TEMP" ] && temp_txt="${S_TEMP} °C"
  dk="$(disk_text)"; ts="$(ts_text)"; pw="$(pwr_text)"
  sm="ok|attiva"; [ "$S_SMB" = active ] || sm="err|ferma"
  overall="Tutto funziona"; overall_c="ok"
  for x in "$dk" "$ts" "$pw" "$sm"; do
    case "${x%%|*}" in
      err) overall="Attenzione richiesta"; overall_c="err" ;;
      warn) [ "$overall_c" = ok ] && { overall="Funziona, con avvisi"; overall_c="warn"; } ;;
    esac
  done
  tsrow=""
  if [ "$S_TS" = "Running" ] && [ -n "$S_TSDNS" ]; then
    tsrow="<div class=\"path\"><code>$(h "${BS}${BS}${S_TSDNS}${BS}${SHARE_NAME}")</code><button onclick=\"cp(this)\">Copia</button></div>"
  fi
  cat > "$WWW/index.html.tmp" <<HTML
<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>$(h "$HOST_NAME") · NASPI</title>
<style>
:root{--bg:#f3f6fb;--card:#fff;--ink:#0d1526;--mute:#62708a;--line:#e3e9f2;--track:#e7edf6;--acc:#0a63f0;--acc2:#00b3e6;--ok:#12a150;--warn:#d98a04;--err:#dc2f2f;--off:#94a0b4}
@media (prefers-color-scheme:dark){:root{--bg:#0a1020;--card:#111a2c;--ink:#e7eef9;--mute:#8d9bb5;--line:#1e2a42;--track:#1b2740;--acc:#3d8bff;--acc2:#2dd4f5;--ok:#2ec66d;--warn:#f5a524;--err:#ff6b6b;--off:#5d6b85}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
header{background:radial-gradient(1200px 400px at 85% -40%,#18b4ff55,transparent),linear-gradient(125deg,#050d1f 0%,#0a2a6b 55%,#0a63f0 100%);color:#fff;padding:26px 16px 78px}
.wrap{max-width:980px;margin:0 auto}
.brand{display:flex;align-items:center;gap:12px}
.logo{width:38px;height:38px;border-radius:10px;background:linear-gradient(135deg,#2dd4f5,#0a63f0);display:grid;place-items:center;font-weight:900;font-size:20px;box-shadow:0 6px 18px #0a63f066}
.brand b{display:block;font-size:17px;letter-spacing:.34em;font-weight:800;line-height:1.1}
.brand small{display:block;font-size:10px;letter-spacing:.52em;opacity:.75}
h1{margin:26px 0 6px;font-size:clamp(26px,5vw,36px);font-weight:750;letter-spacing:-.01em}
.sub{opacity:.82}
.pill{display:inline-flex;align-items:center;gap:8px;margin-top:14px;padding:6px 12px;border-radius:99px;background:#ffffff1f;border:1px solid #ffffff33;font-weight:600;font-size:13px}
main{margin-top:-52px;padding:0 16px 24px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:20px 22px;box-shadow:0 1px 2px #0000000a,0 10px 30px #0a2a6b14}
.card h2{margin:0 0 14px;font-size:11.5px;letter-spacing:.16em;text-transform:uppercase;color:var(--mute);font-weight:700}
.big{font-size:44px;font-weight:800;line-height:1;letter-spacing:-.02em}
.big span{font-size:18px;color:var(--mute);font-weight:600;margin-left:8px;letter-spacing:0}
.bar{height:12px;background:var(--track);border-radius:99px;overflow:hidden;margin:14px 0 8px}
.bar i{display:block;height:100%;width:${S_PCT}%;background:linear-gradient(90deg,var(--acc),var(--acc2));border-radius:99px}
.muted{color:var(--mute);font-size:13.5px}
.row{display:flex;justify-content:space-between;align-items:center;gap:14px;padding:9px 0;border-top:1px solid var(--line)}
.row:first-of-type{border-top:0;padding-top:0}
.k{color:var(--mute)}
.v{font-weight:600;text-align:right;overflow-wrap:anywhere}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;vertical-align:1px}
.ok{background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 22%,transparent)}
.warn{background:var(--warn)}.err{background:var(--err)}.off{background:var(--off)}
.lbl{font-size:12px;color:var(--mute);margin:12px 0 4px;font-weight:600}
.lbl:first-of-type{margin-top:0}
.path{display:flex;align-items:center;gap:8px;background:var(--bg);border:1px solid var(--line);border-radius:11px;padding:7px 7px 7px 13px}
.path code{flex:1;font:600 14px ui-monospace,SFMono-Regular,Consolas,monospace;overflow-wrap:anywhere}
button{border:0;background:var(--acc);color:#fff;border-radius:8px;padding:7px 12px;font:700 12px system-ui,sans-serif;cursor:pointer}
button:hover{filter:brightness(1.1)}
.note{margin-top:14px;font-size:13px;color:var(--mute)}
footer{text-align:center;color:var(--mute);font-size:12px;padding:6px 16px 30px;letter-spacing:.02em}
footer b{letter-spacing:.2em;color:var(--ink)}
</style>
</head>
<body>
<header><div class="wrap">
  <div class="brand"><div class="logo">V</div><div><b>VERGEN</b><small>TECHNOLOGY</small></div></div>
  <h1>$(h "$HOST_NAME")</h1>
  <div class="sub">Cartella di rete NASPI · $(h "$S_MODEL")</div>
  <div class="pill"><span class="dot ${overall_c}"></span>${overall}</div>
</div></header>
<main><div class="wrap grid">
  <section class="card">
    <h2>Spazio</h2>
    <div class="big">${S_PCT}%<span>usato</span></div>
    <div class="bar"><i></i></div>
    <div class="muted">$(h "$S_USED") usati di $(h "$S_SIZE") · <b>$(h "$S_AVAIL") liberi</b></div>
    <div class="note"><span class="dot ${dk%%|*}"></span>$(h "${dk#*|}")</div>
  </section>
  <section class="card">
    <h2>Stato</h2>
    <div class="row"><span class="k">Cartella condivisa</span><span class="v"><span class="dot ${sm%%|*}"></span>$(h "${sm#*|}")</span></div>
    <div class="row"><span class="k">Accesso da fuori</span><span class="v"><span class="dot ${ts%%|*}"></span>$(h "${ts#*|}")</span></div>
    <div class="row"><span class="k">Alimentazione</span><span class="v"><span class="dot ${pw%%|*}"></span>$(h "${pw#*|}")</span></div>
    <div class="row"><span class="k">Temperatura</span><span class="v">${temp_txt}</span></div>
    <div class="row"><span class="k">Acceso da</span><span class="v">$(h "${S_UP:-–}")</span></div>
    <div class="row"><span class="k">Indirizzo</span><span class="v">$(h "${S_LANIP:-–}")</span></div>
  </section>
  <section class="card">
    <h2>Collegati</h2>
    <div class="lbl">Windows · Esplora file</div>
    <div class="path"><code>$(h "$WIN_PATH")</code><button onclick="cp(this)">Copia</button></div>
    <div class="lbl">Mac · Finder › Vai › Connetti al server</div>
    <div class="path"><code>smb://$(h "$HOST_NAME").local/$(h "$SHARE_NAME")</code><button onclick="cp(this)">Copia</button></div>
    <div class="lbl">Fuori casa · con Tailscale, stesso account</div>
    <div class="path"><code>$(h "$WIN_PATH")</code><button onclick="cp(this)">Copia</button></div>
    ${tsrow}
    <div class="note">Utente <b>$(h "$NAS_USER")</b> · la password la trovi sul NAS con <code>sudo naspi</code></div>
  </section>
</div></main>
<footer><b>VERGEN TECHNOLOGY</b> · NASPI v${NASPI_VERSION} · aggiornato ${d}</footer>
<script>
function cp(b){var t=b.previousElementSibling.textContent,a=document.createElement("textarea");a.value=t;a.style.position="fixed";a.style.opacity="0";document.body.appendChild(a);a.select();try{document.execCommand("copy");b.textContent="Copiato";setTimeout(function(){b.textContent="Copia"},1600)}catch(e){}document.body.removeChild(a)}
</script>
</body>
</html>
HTML
  chmod 644 "$WWW/index.html.tmp"
  mv -f "$WWW/index.html.tmp" "$WWW/index.html"
}

cmd_help() {
  ui_header "comandi"
  ui_kv "sudo naspi" "riepilogo: percorsi, utente, password, stato"
  ui_kv "naspi login" "nuovo link Tailscale"
  ui_kv "naspi diag" "diagnosi SSD / alimentazione / servizi"
  ui_kv "naspi mount" "rimonta l'SSD"
  ui_kv "naspi format" "cancella e formatta l'SSD (ext4)"
  ui_kv "naspi web" "aggiorna il pannello http://${HOST_NAME}.local"
  echo
}

case "${1:-}" in
  "")              cmd_summary ;;
  login)           cmd_login ;;
  diag)            cmd_diag ;;
  mount)           cmd_mount ;;
  format)          need_root format; shift; exec /usr/local/sbin/naspi-format "$@" ;;
  motd)            cmd_motd ;;
  web)             cmd_web ;;
  help|-h|--help)  cmd_help ;;
  *)               cmd_help; exit 1 ;;
esac
CLI
  chmod 755 /usr/local/bin/naspi
  mkdir -p "$SHARE_PATH"
  cat > "${SHARE_PATH}/LEGGIMI.txt" <<EOF
  VERGEN TECHNOLOGY  ·  NASPI
  ===========================

  Cartella di rete: ${HOST_NAME}

  Windows   \\\\${HOST_NAME}\\${SHARE_NAME}
  Mac       smb://${HOST_NAME}.local/${SHARE_NAME}
  Pannello  http://${HOST_NAME}.local
  Utente    ${NAS_USER}

  Fuori casa: installa Tailscale e accedi con lo stesso account,
  poi apri \\\\${HOST_NAME}\\${SHARE_NAME}
EOF
  chown "${NAS_USER}:${NAS_GROUP}" "${SHARE_PATH}/LEGGIMI.txt" 2>/dev/null || true
}

write_motd() {
  # schermata di benvenuto al login SSH
  if [ -f /etc/motd ] && [ ! -f /etc/motd.naspi.bak ]; then
    cp -a /etc/motd /etc/motd.naspi.bak
  fi
  : > /etc/motd
  mkdir -p /etc/update-motd.d
  cat > /etc/update-motd.d/90-naspi <<'EOF'
#!/bin/sh
NASPI_FORCE_COLOR=1 timeout 8 /usr/local/bin/naspi motd 2>/dev/null || true
EOF
  chmod 755 /etc/update-motd.d/90-naspi
}

install_web() {
  mkdir -p /var/lib/naspi/www
  chmod 755 /var/lib/naspi /var/lib/naspi/www
  pkg_installed busybox || pkg_first busybox || true
  cat > /usr/local/sbin/naspi-httpd <<'EOF'
#!/bin/sh
# Pannello NASPI: server minimo (busybox httpd, ~1 MB RAM sul Pi 1)
DIR=/var/lib/naspi/www
if busybox --list 2>/dev/null | grep -qx httpd; then
  exec busybox httpd -f -p 80 -h "$DIR"
fi
exec python3 -m http.server 80 --bind 0.0.0.0 --directory "$DIR"
EOF
  chmod 755 /usr/local/sbin/naspi-httpd
  cat > /etc/systemd/system/naspi-web.service <<'EOF'
[Unit]
Description=NASPI · VERGEN TECHNOLOGY: pannello web
After=network.target
[Service]
ExecStart=/usr/local/sbin/naspi-httpd
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=always
RestartSec=5
MemoryMax=32M
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/naspi-web-update.service <<'EOF'
[Unit]
Description=NASPI: aggiorna pannello web
[Service]
Type=oneshot
Nice=10
ExecStart=/usr/local/bin/naspi web
EOF
  cat > /etc/systemd/system/naspi-web-update.timer <<'EOF'
[Unit]
Description=NASPI: aggiorna pannello web ogni minuto
[Timer]
OnBootSec=20
OnUnitActiveSec=60
AccuracySec=10
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload || true
  /usr/local/bin/naspi web >/dev/null 2>&1 || warn "pannello web: prima generazione fallita"
  systemctl enable --now naspi-web.service naspi-web-update.timer >/dev/null 2>&1 \
    || warn "pannello web non avviato (porta 80 occupata?)"
  if systemctl is-active --quiet naspi-web; then
    ok "Pannello web: http://${HOST_NAME}.local"
  fi
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
  local t0=$SECONDS
  ui_banner "Installazione NAS"
  printf '    %sNiente domande: puoi lasciarlo lavorare. Sul Pi 1 servono 10-30 minuti.%s
' "$CM" "$C0"

  ui_step 1 6 "Sistema"
  detect_user
  set_hostname
  log "Utente della cartella: ${NAS_USER}"
  ensure_swap
  lower_gpu_mem

  ui_step 2 6 "Stabilita USB e SSD"
  usb_ssd_stable
  tune_system
  ok "USB senza risparmio energetico, memoria per il driver USB, log persistenti"

  ui_step 3 6 "Pacchetti"
  apt_ok

  ui_step 4 6 "Disco e cartella condivisa"
  smb_password
  setup_share_dir
  save_creds
  write_smb_conf
  write_avahi
  start_samba

  ui_step 5 6 "Comandi e pannello VERGEN"
  write_ui_lib
  write_cli
  install_format_tool
  write_motd
  install_web
  ok "Comando: sudo naspi   ·   pannello: http://${HOST_NAME}.local"

  ui_step 6 6 "Accesso da fuori casa (Tailscale)"
  install_tailscale
  systemctl enable tailscaled >/dev/null 2>&1 || true
  bring_up_tailscale
  wait_tailscale_login

  print_report
  ok "Installazione completata in $(( (SECONDS - t0) / 60 )) min $(( (SECONDS - t0) % 60 )) s"
  echo
}

main "$@"
