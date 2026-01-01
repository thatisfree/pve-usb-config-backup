#!/bin/bash
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
    backing_up) echo "📦 Mentés ide: $1";; 
    done) echo "✅ Kész. Sync + umount...";; 
    safe_remove) echo "✅ Le lehet húzni az USB-t.";; 
    *) echo "[$k] $*";; 
  esac
}

_msg_en() {
  local k="$1"; shift || true
  case "$k" in
    need_root) echo "❌ Please run as root.";; 
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

is_usb_disk() {
  local dev="$1"  # pl. sdb
  local tran
  tran="$(lsblk -ndo TRAN "/dev/$dev" 2>/dev/null || true)"
  [[ "$tran" == "usb" ]] && return 0
  udevadm info --query=property --name="/dev/$dev" 2>/dev/null | grep -qx 'ID_BUS=usb'
}

list_usb_disks() {
  # Kimenet: "sdb|SanDisk Ultra Fit|57.3G"
  # -P: KEY="VALUE" párok, jól pars-olható szóközös MODEL-nél is
  while IFS= read -r line; do
    # Példa line:
    # NAME="sdb" MODEL="SanDisk Ultra Fit" SIZE="57.3G" TRAN="usb" TYPE="disk"
    eval "$line" 2>/dev/null || continue

    # Csak disk típus érdekel
    [[ "${TYPE:-}" != "disk" ]] && continue

    # Elsődlegesen TRAN alapján
    if [[ "${TRAN:-}" == "usb" ]]; then
      echo "${NAME}|${MODEL:-unknown}|${SIZE:-unknown}"
      continue
    fi

    # Fallback: ha TRAN üres / megbízhatatlan, udev alapján nézzük
    if udevadm info --query=property --name="/dev/${NAME}" 2>/dev/null | grep -qx 'ID_BUS=usb'; then
      echo "${NAME}|${MODEL:-unknown}|${SIZE:-unknown}"
    fi
  done < <(lsblk -P -d -o NAME,MODEL,SIZE,TRAN,TYPE)
}

pick_partition() {
  local disk="$1"   # pl. sdc

  # Keressük a disk alatti partíciókat "raw" listában (fa karakterek nélkül),
  # és csak olyat választunk, amin van fájlrendszer (FSTYPE).
  # A legnagyobb partíciót választjuk.
  local best_part=""
  local best_size=0

  while IFS= read -r line; do
    # NAME FSTYPE SIZE
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

  if [[ -z "$best_part" ]]; then
    echo ""
  else
    echo "/dev/$best_part"
  fi
}


safe_mount() {
  local part="$1"
  mkdir -p "$TMP_MNT"

  if mountpoint -q "$TMP_MNT"; then
    msg already_mounted "$TMP_MNT"
    exit 1
  fi

  # Auto-detect opciók: a mount próbálkozik a fstype alapján.
  # ntfs esetén lehet ntfs-3g kell, exfat esetén exfatprogs, de PVE-n gyakran megvan.
  mount "$part" "$TMP_MNT"
}

do_backup() {
  local target="$TMP_MNT/$BACKUP_ROOT_NAME/host"
  mkdir -p \
    "$target/etc-pve" \
    "$target/network" \
    "$target/fstab" \
    "$target/meta"

  msg backing_up "$target"

  tar czf "$target/etc-pve/pve-etc-$DATE.tar.gz" /etc/pve

  cp /etc/network/interfaces \
     "$target/network/interfaces-$DATE"

  cp /etc/fstab \
     "$target/fstab/fstab-$DATE"

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
  
  # Umount USB
  if mountpoint -q "$TMP_MNT"; then
    umount "$TMP_MNT" 2>/dev/null || true
  fi
  
  # Remove temp mount directory
  rmdir "$TMP_MNT" 2>/dev/null || true
}

main() {
  require_root
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
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#disks[@]} )); then
    msg invalid_choice
    exit 1
  fi

  IFS='|' read -r disk _ _ <<<"${disks[$((choice-1))]}"
  msg selected_disk "$disk"

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
  # cleanup trap intézi
  msg safe_remove
}

main
