#!/bin/bash
# Cancella e formatta l'SSD/HDD USB in ext4 (nativo, veloce sul Pi) per \\mariarosaria\nas
#
# Sul Pi, con il disco collegato (dopo install.sh è anche: sudo naspi format):
#   sudo bash format-usb.sh
#
# Senza conferma (ATTENZIONE: cancella tutto):
#   sudo bash format-usb.sh --yes
#
# NB: non serve per un disco nuovo/vuoto: NASPI lo formatta da solo.
#
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
_src="${BASH_SOURCE[0]:-$0}"
if [ -f "$_src" ] && grep -q $'\r' "$_src" 2>/dev/null; then
  _tmp="$(mktemp)"
  tr -d '\r' < "$_src" > "$_tmp"
  chmod +x "$_tmp"
  exec /bin/bash "$_tmp" "$@"
fi

set -euo pipefail

SHARE_PATH="/srv/nas"
LABEL="nas"
AUTO_YES=0
[ "${1:-}" = "--yes" ] && AUTO_YES=1
[ -f /etc/naspi/credentials ] && . /etc/naspi/credentials

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Esegui: sudo bash format-usb.sh"

root_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [ "$src" = "/dev/root" ] && src="$(readlink -f /dev/root 2>/dev/null || echo /dev/mmcblk0p2)"
  pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)"
  [ -n "$pk" ] && { basename "$pk"; return; }
  basename "$src" | sed -E 's/p?[0-9]+$//'
}

# Solo dischi collegati via USB (percorso sysfs sul bus USB), mai la microSD.
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

wait_usb() {
  local i d best="" bs=0 s
  for i in $(seq 1 30); do
    for d in $(usb_disks); do
      s="$(lsblk -bdno SIZE "$d" 2>/dev/null || echo 0)"
      [ "${s:-0}" -gt "$bs" ] && { bs="$s"; best="$d"; }
    done
    [ -n "$best" ] && { echo "$best"; return 0; }
    sleep 1
  done
  return 1
}

unmount_disk() {
  local dev="$1" p
  if findmnt "$SHARE_PATH" >/dev/null 2>&1; then
    umount "$SHARE_PATH" 2>/dev/null || umount -l "$SHARE_PATH" 2>/dev/null || true
  fi
  for p in $(lsblk -lnpo NAME "$dev" | tac); do
    findmnt "$p" >/dev/null 2>&1 && { umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true; }
  done
}

format_disk() {
  local dev="$1" part
  log "Pulisco ${dev}" >&2
  unmount_disk "$dev"
  wipefs -a "$dev" >/dev/null 2>&1 || true
  dd if=/dev/zero of="$dev" bs=1M count=8 status=none conv=fsync 2>/dev/null \
    || die "Scrittura su ${dev} fallita: disco/alimentazione instabili (usa hub USB alimentato)"

  log "Tabella GPT + partizione unica" >&2
  printf 'label: gpt\n,,L\n' | sfdisk -q -w always "$dev" >/dev/null \
    || die "Partizionamento fallito su ${dev}"
  partprobe "$dev" >/dev/null 2>&1 || blockdev --rereadpt "$dev" >/dev/null 2>&1 || true
  udevadm settle -t 20 >/dev/null 2>&1 || true
  sleep 2

  part="$(lsblk -lnpo NAME,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
  [ -n "$part" ] && [ -b "$part" ] || die "Partizione non creata su ${dev}"

  log "Formattazione ext4 (può richiedere qualche minuto)" >&2
  mkfs.ext4 -q -F -L "$LABEL" -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$part" >/dev/null \
    || die "mkfs.ext4 fallito"
  udevadm settle -t 20 >/dev/null 2>&1 || true
  echo "$part"
}

attach_nas() {
  local part="$1" owner="${NAS_USER:-${SUDO_USER:-pi}}"
  mkdir -p "$SHARE_PATH"
  # vecchie righe fstab di NASPI: il montaggio ora lo fa naspi-usb-mount
  if grep -qE "^[^#].*[[:space:]]${SHARE_PATH}[[:space:]]" /etc/fstab; then
    sed -i "\|^[^#].*[[:space:]]${SHARE_PATH}[[:space:]]|d" /etc/fstab
    systemctl daemon-reload 2>/dev/null || true
  fi
  if [ -x /usr/local/sbin/naspi-usb-mount ]; then
    /usr/local/sbin/naspi-usb-mount 20 || true
  fi
  if ! findmnt "$SHARE_PATH" >/dev/null 2>&1; then
    mount -t ext4 -o noatime,commit=60 "$part" "$SHARE_PATH" || die "Montaggio fallito"
  fi
  chown "${owner}:$(id -gn "$owner" 2>/dev/null || echo "$owner")" "$SHARE_PATH" 2>/dev/null || true
  chmod 2775 "$SHARE_PATH" 2>/dev/null || true
  systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
}

main() {
  command -v sfdisk >/dev/null && command -v mkfs.ext4 >/dev/null \
    || { apt-get install -y --no-install-recommends fdisk e2fsprogs </dev/null || die "Mancano sfdisk/mkfs.ext4"; }
  local dev model size part
  log "Cerco disco USB (escludo la microSD $(root_disk), attendo fino a 30s)"
  lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,MOUNTPOINT,MODEL || true

  dev="$(wait_usb || true)"
  [ -n "$dev" ] || die "Nessun disco USB. Collega l'SSD (Pi 1: hub USB alimentato) e rilancia. Diagnosi: sudo naspi diag"
  dd if="$dev" of=/dev/null bs=1M count=1 iflag=direct status=none 2>/dev/null \
    || die "${dev} non risponde in lettura: alimentazione insufficiente o cavo/box difettoso"

  model="$(lsblk -ndo MODEL "$dev" | tr -s ' ' | sed 's/[[:space:]]*$//')"
  size="$(lsblk -ndo SIZE "$dev")"
  printf '\n\033[1;31m  CANCELLA TUTTO su %s  (%s, %s)\033[0m\n' "$dev" "${size}" "${model:-USB}"
  printf '  La microSD NON viene toccata.\n\n'

  if [ "$AUTO_YES" -ne 1 ]; then
    [ -t 0 ] || die "Serve conferma da terminale (oppure --yes)"
    printf 'Scrivi FORMATTA per confermare: '
    read -r ans
    [ "$ans" = "FORMATTA" ] || die "Annullato"
  fi

  # stesso lock del montaggio automatico: niente interferenze durante la formattazione
  exec 9>/run/naspi-usb.lock
  flock -w 900 9 || die "Montaggio automatico occupato, riprova"
  part="$(format_disk "$dev")"
  exec 9>&-
  attach_nas "$part"

  log "Fatto. ${dev} → ${part} (ext4, etichetta ${LABEL})"
  findmnt "$SHARE_PATH" || true
  echo
  echo "  Cartella NAS:  ${SHARE_PATH}"
  echo "  Windows:       \\\\${HOST_NAME:-mariarosaria}\\${SHARE_NAME:-nas}"
  echo
}

main "$@"
