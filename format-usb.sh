#!/bin/bash
# Formatta l'hard disk / SSD USB in ext4 (nativo Raspberry) e lo prepara per \\mariarosaria\nas
#
# Sul Pi, con il disco già collegato:
#   sudo bash format-usb.sh
#
# Senza conferma (ATTENZIONE: cancella tutto):
#   sudo bash format-usb.sh --yes
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

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Esegui: sudo bash format-usb.sh"

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

is_usb_disk() {
  local dev="$1" boot="$2" name type tran pk
  name="$(basename "$dev")"
  [ "$name" = "$boot" ] && return 1
  type="$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)"
  [ "$type" = "disk" ] || return 1
  tran="$(lsblk -ndo TRAN "$dev" 2>/dev/null || true)"
  if [ -z "$tran" ]; then
    pk="$(lsblk -ndo PKNAME "$dev" 2>/dev/null || true)"
    [ -n "$pk" ] && tran="$(lsblk -ndo TRAN "/dev/$pk" 2>/dev/null || true)"
  fi
  [ "$tran" = "usb" ]
}

pick_usb() {
  local boot best="" best_bytes=0 name type tran size bytes
  boot="$(root_disk)"
  while read -r name type tran size; do
    [ "$type" = "disk" ] || continue
    [ "$tran" = "usb" ] || continue
    case "$name" in
      *"${boot}"*) continue ;;
    esac
    bytes="$(lsblk -bdno SIZE "$name" 2>/dev/null || echo 0)"
    [ -n "$bytes" ] || bytes=0
    [ "$bytes" -gt "$best_bytes" ] || continue
    best_bytes="$bytes"
    best="$name"
  done < <(lsblk -rpn -o NAME,TYPE,TRAN,SIZE 2>/dev/null || true)
  [ -n "$best" ] || return 1
  echo "$best"
}

need_tools() {
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v parted >/dev/null 2>&1; then
    log "Installo parted + e2fsprogs"
    apt-get update -qq || true
    apt-get install -y --no-install-recommends parted e2fsprogs util-linux \
      || die "Non riesco a installare parted/e2fsprogs"
  fi
}

unmount_disk() {
  local dev="$1" p
  while read -r p; do
    [ -n "$p" ] || continue
    if findmnt "$p" >/dev/null 2>&1; then
      umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null || true
    fi
  done < <(lsblk -lnpo NAME "$dev" | tac)
  if findmnt "$SHARE_PATH" >/dev/null 2>&1; then
    umount "$SHARE_PATH" 2>/dev/null || umount -l "$SHARE_PATH" 2>/dev/null || true
  fi
}

part_name() {
  local dev="$1"
  case "$dev" in
    *[0-9]) echo "${dev}p1" ;;
    *) echo "${dev}1" ;;
  esac
}

format_disk() {
  local dev="$1" part
  log "Pulisco ${dev}"
  unmount_disk "$dev"
  wipefs -a "$dev" >/dev/null 2>&1 || true
  dd if=/dev/zero of="$dev" bs=1M count=8 status=none conv=fsync 2>/dev/null || true
  partprobe "$dev" >/dev/null 2>&1 || true
  sleep 1

  log "Tabella GPT + partizione unica ext4"
  parted -s "$dev" mklabel gpt
  parted -s "$dev" mkpart "${LABEL}" ext4 1MiB 100%
  partprobe "$dev" >/dev/null 2>&1 || true
  sleep 2
  udevadm settle >/dev/null 2>&1 || true

  part="$(part_name "$dev")"
  if [ ! -b "$part" ]; then
    part="$(lsblk -lnpo NAME,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
  fi
  [ -n "$part" ] && [ -b "$part" ] || die "Partizione non creata su ${dev}"

  log "Formattazione ext4 (può richiedere alcuni minuti)"
  mkfs.ext4 -F -L "$LABEL" -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$part" >/dev/null
  partprobe "$dev" >/dev/null 2>&1 || true
  echo "$part"
}

attach_nas() {
  local part="$1"
  mkdir -p "$SHARE_PATH"
  if [ -x /usr/local/sbin/naspi-usb-mount ]; then
    /usr/local/sbin/naspi-usb-mount || true
    if findmnt "$SHARE_PATH" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if grep -q " ${SHARE_PATH} " /etc/fstab; then
    sed -i "\| ${SHARE_PATH} |d" /etc/fstab
  fi
  local uuid
  uuid="$(blkid -s UUID -o value "$part")"
  echo "UUID=${uuid} ${SHARE_PATH} ext4 defaults,nofail,noatime,x-systemd.device-timeout=15 0 0" >> /etc/fstab
  mount "$SHARE_PATH"
}

main() {
  need_tools
  local boot dev model size part
  boot="$(root_disk)"
  log "Cerco hard disk USB (escludo microSD ${boot})"
  lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,MOUNTPOINT,MODEL

  dev="$(pick_usb || true)"
  [ -n "$dev" ] || die "Nessun disco USB trovato. Collega l'SSD e rilancia."
  is_usb_disk "$dev" "$boot" || die "${dev} non è un disco USB (protezione microSD)"

  model="$(lsblk -ndo MODEL "$dev" | tr -s ' ' | sed 's/[[:space:]]*$//')"
  size="$(lsblk -ndo SIZE "$dev")"
  printf '\n\033[1;31m  CANCELLA TUTTO su %s  (%s, %s)\033[0m\n' "$dev" "${size}" "${model:-USB}"
  printf '  La microSD / NON viene toccata.\n\n'

  if [ "$AUTO_YES" -ne 1 ]; then
    printf 'Scrivi FORMATTA per confermare: '
    read -r ans
    [ "$ans" = "FORMATTA" ] || die "Annullato"
  fi

  part="$(format_disk "$dev")"
  attach_nas "$part"

  local owner="pi"
  if [ -f /etc/naspi/credentials ]; then
    # shellcheck disable=SC1091
    . /etc/naspi/credentials
    owner="${NAS_USER:-pi}"
  elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    owner="$SUDO_USER"
  fi
  chown "${owner}:${owner}" "$SHARE_PATH" 2>/dev/null || true
  chmod 775 "$SHARE_PATH" 2>/dev/null || true
  systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true

  log "Fatto. Disco ${dev} → ${part} (ext4, etichetta ${LABEL})"
  findmnt "$SHARE_PATH" || true
  echo
  echo "  Cartella NAS:  ${SHARE_PATH}"
  echo "  Windows:       \\\\mariarosaria\\nas"
  echo
}

main "$@"
