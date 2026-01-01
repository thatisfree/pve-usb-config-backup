#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT_NAME="proxmox-backup"
TMP_MNT="/mnt/.pve-usb-backup"
DATE="$(date +%F)"
HOSTNAME="$(hostname)"

LANGUAGE="${LANGUAGE:-hu}"   # hu|en

# -------- i18n --------
msg() {
  local key="$1"; shift || true
  case "${LANGUAGE}" in
    en) _msg_en "$key" "$@";;
    *)  _msg_hu "$key" "$@";;
  esac
}

_msg_hu() {
  local k="$1"; shift || true
  case "$k" in
    need_root) echo "❌ Rootként futtasd (sudo).";;
    no_usb) echo "❌ Nem találok USB-s lemezt (TRAN=usb vagy udev ID_BUS=usb).";;
    found_usb) echo "Talált USB lemezek:";;
    choose_disk) echo -n "Melyikre mentsek? (1-$1): ";;
    invalid_choice) echo "❌ Hibás választás.";;
    selected_disk) echo "✅ Kiválasztva: /dev/$1";;
    no_part) echo "❌ A /dev/$1 alatt nem találtam mountolható partíciót (nincs FSTYPE).";;
    tip_fs) echo "   Tipp: legyen rajta pl. ext4/exfat/ntfs partíció fájlrendszerrel.";;
    using_part) echo "➡️ Használt partíció: $1";;
    temp_mount) echo "➡️ Ideiglenes mount: $1";;
    already_mounted) echo "❌ A $1 már mountpoint. Előbb umountold.";;
    mount_fail) echo "❌ Nem sikerült mountolni: $1 → $2";;
    backing_up) echo "📦 Mentés ide: $1";;
    done) echo "✅ Kész. Sync + umount...";;
    safe_remove) echo "✅ Le lehet húzni az USB-t.";;
    *) echo "[$k] $*";;
  esac
}

_msg_en() {
  local k="$1"; shift || true
  case "$k" in
    need_root) echo "❌ Please run as root."; ;
    no_usb) echo "❌ No USB disks found (TRAN=usb or udev ID_BUS=usb).";;
    found_usb) echo "Found USB disks:";;
    choose_disk) echo -n "Which disk to backup to? (1-$1): ";;
    invalid_choice) echo "❌ Invalid selection.";;
    selected_disk) echo "✅ Selected: /dev/$1";;
    no_part) echo "❌ No mountable partition found on /dev/$1 (no FSTYPE).";;
    tip_fs) echo "   Tip: create a filesystem partition (ext4/exfat/ntfs) on the USB drive.";;
    using_part) echo "➡️ Using partition: $1";;
    temp_mount) echo "➡️ Temporary mount: $1";;
    already_mounted) echo "❌ $1 is already a mountpoint. Please umount it first.";;
    mount_fail) echo "❌ Failed to mount: $1 → $2";;
    backing_up) echo "📦 Backing up to: $1";;
    done) echo "✅ Done. Sync + umount...";;
    safe_remove) echo "✅ Safe to remove USB drive.";;
    *) echo "[$k] $*";;
  esac
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    msg need_root
    exit 1
  fi
}

require_deps() {
  local missing=()
  for c in lsblk udevadm mount umount tar awk sed grep cp sync date hostname pveversion uptime; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    echo "Missing commands: ${missing[*]}"
    exit 1
  fi
}

list_usb_disks() {
  while IFS= read -r line; do
    eval "$line" 2>/dev/null || continue
    [[ "${TYPE:-}" != "disk" ]] && continue

    if [[ "${TRAN:-}" == "usb" ]]; then
      echo "${NAME}|${MODEL:-unknown}|${SIZE:-unknown}"
      continue
    fi

    if udevadm info --query=property --name="/dev/${NAME}" 2>/dev/null | grep -qx 'ID_BUS=usb'; then
      echo "${NAME}|${MODEL:-unknown}|${SIZE:-unknown}"
    fi
  done < <(lsblk -P -d -o NAME,MODEL,SIZE,TRAN,TYPE)
}

pick_partition() {
  local disk="$1"
  local best_part=""
  local best_size=0

  while IFS= read -r line; do
    local name fstype size
    name="$(awk '{print $1}' <<<"$line")"
    fstype="$(awk '{print $2}' <<<"$line")"
    size="$(awk '{print $3}' <<<"$line")"

    [[ -z "${fstype:-}" || "${fstype:-}" == "-" ]] && continue
    if (( size > best_size )); then
      best_size="$size"
      best_part="$name"
    fi
  done < <(lsblk -rnb -o NAME,FSTYPE,SIZE "/dev/$disk" | tail -n +2)

  [[ -n "$best_part" ]] && echo "/dev/$best_part" || echo ""
}

safe_mount() {
  local part="$1"
  mkdir -p "$TMP_MNT"

  if mountpoint -q "$TMP_MNT"; then
    msg already_mounted "$TMP_MNT"
    exit 1
  fi

  if ! mount "$part" "$TMP_MNT"; then
    msg mount_fail "$part" "$TMP_MNT"
    exit 1
  fi
}

do_backup() {
  local target="$TMP_MNT/$BACKUP_ROOT_NAME/host"
  mkdir -p \
    "$target/etc-pve" \
    "$target/network" \
    "$target/fstab" \
    "$target/meta"

  msg backing_up "$target"

  # /etc/pve FUSE: stabilabb így, és nem ijeszt meg ha "változott olvasás közben"
  tar --warning=no-file-changed -C /etc -czf "$target/etc-pve/pve-etc-$DATE.tar.gz" pve

  cp -a /etc/network/interfaces "$target/network/interfaces-$DATE" 2>/dev/null || true
  cp -a /etc/fstab "$target/fstab/fstab-$DATE" 2>/dev/null || true

  cat > "$target/meta/host-info-$DATE.txt" <<EOF
Hostname: $HOSTNAME
Date: $DATE
Proxmox version:
$(pveversion 2>/dev/null || true)
Uptime:
$(uptime 2>/dev/null || true)
Disks:
$(lsblk -dno NAME,MODEL,SIZE,TRAN | sed 's/^/  /')
EOF
}

cleanup() {
  set +e
  sync
  if mountpoint -q "$TMP_MNT"; then
    umount "$TMP_MNT" 2>/dev/null || true
  fi
  rmdir "$TMP_MNT" 2>/dev/null || true
}

main() {
  require_root
  require_deps
  trap cleanup EXIT

  mapfile -t disks < <(list_usb_disks)
  if (( ${#disks[@]} == 0 )); then
    msg no_usb
    exit 1
  fi

  msg found_usb
  for i in "${!disks[@]}"; do
    IFS='|' read -r name model size <<<"${disks[$i]}"
    echo "  [$((i+1))] /dev/$name  (${model})  ${size}"
  done

  msg choose_disk "${#disks[@]}"
  read -r choice < /dev/tty

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#disks[@]} )); then
    msg invalid_choice
    exit 1
  fi

  IFS='|' read -r disk _ _ <<<"${disks[$((choice-1))]}"
  msg selected_disk "$disk"

  local part
  part="$(pick_partition "$disk")"
  if [[ -z "$part" ]]; then
    msg no_part "$disk"
    msg tip_fs
    exit 1
  fi

  msg using_part "$part"
  msg temp_mount "$TMP_MNT"
  safe_mount "$part"

  do_backup

  msg done
  msg safe_remove
}

main
