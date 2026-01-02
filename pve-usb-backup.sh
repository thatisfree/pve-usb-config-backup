#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT_NAME="proxmox-backup"
DATE="$(date +%F)"
HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
LANGUAGE="${LANGUAGE:-hu}"   # hu|en

TMP_MNT="" # futás közben kap értéket (mktemp)

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
    need_cmd) echo "❌ Hiányzó parancs: $1";;
    no_usb) echo "❌ Nem találok USB-s lemezt (TRAN=usb vagy udev ID_BUS=usb).";;
    found_usb) echo "Talált USB lemezek:";;
    choose_disk) echo -n "Melyikre mentsek? (1-$1): ";;
    invalid_choice) echo "❌ Hibás választás.";;
    selected_disk) echo "✅ Kiválasztva: /dev/$1";;
    no_part) echo "❌ A /dev/$1 alatt nem találtam mountolható partíciót (nincs FSTYPE / mind mountolva van).";;
    tip_fs) echo "   Tipp: legyen rajta pl. ext4/exfat/ntfs partíció fájlrendszerrel (és ne legyen felcsatolva).";;
    using_part) echo "➡️ Használt partíció: $1";;
    temp_mount) echo "➡️ Ideiglenes mount: $1";;
    already_mounted) echo "❌ A $1 már mountpoint. Előbb umountold.";;
    part_mounted_elsewhere) echo "❌ A partíció már fel van csatolva máshova: $1 -> $2";;
    backing_up) echo "📦 Mentés ide: $1";;
    fs_no_xattr) echo "ℹ️ Fájlrendszer ($1) nem támogatja az xattrs-t, alapértelmezett mentés.";;
    done) echo "✅ Kész. Sync + umount...";;
    safe_remove) echo "✅ Le lehet húzni az USB-t.";;
    *) echo "[$k] $*";;
  esac
}

_msg_en() {
  local k="$1"; shift || true
  case "$k" in
    need_root) echo "❌ Please run as root (sudo).";;
    need_cmd) echo "❌ Missing command: $1";;
    no_usb) echo "❌ No USB disks found (TRAN=usb or udev ID_BUS=usb).";;
    found_usb) echo "Found USB disks:";;
    choose_disk) echo -n "Which disk to backup to? (1-$1): ";;
    invalid_choice) echo "❌ Invalid selection.";;
    selected_disk) echo "✅ Selected: /dev/$1";;
    no_part) echo "❌ No mountable partition found on /dev/$1 (no FSTYPE / all mounted).";;
    tip_fs) echo "   Tip: create a filesystem partition (ext4/exfat/ntfs) on the USB drive (and ensure it's not mounted).";;
    using_part) echo "➡️ Using partition: $1";;
    temp_mount) echo "➡️ Temporary mount: $1";;
    already_mounted) echo "❌ $1 is already a mountpoint. Please umount it first.";;
    part_mounted_elsewhere) echo "❌ Partition is already mounted elsewhere: $1 -> $2";;
    backing_up) echo "📦 Backing up to: $1";;
    fs_no_xattr) echo "ℹ️ Filesystem ($1) doesn't support xattrs, using basic backup.";;
    done) echo "✅ Done. Sync + umount...";;
    safe_remove) echo "✅ Safe to remove USB drive.";;
    *) echo "[$k] $*";;
  esac
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg need_root
    exit 1
  fi
}

require_cmds() {
  local c
  for c in lsblk udevadm mount umount mountpoint tar awk sed date hostname sync; do
    command -v "$c" >/dev/null 2>&1 || { msg need_cmd "$c"; exit 1; }
  done
}

# KEY="VALUE" parser eval nélkül
get_kv() {
  local key="$1" line="$2"
  sed -nE "s/.*(^|[[:space:]])${key}=\"([^\"]*)\".*/\2/p" <<<"$line"
}

list_usb_disks() {
  # Kimenet: "sdb|SanDisk Ultra Fit|57.3G"
  while IFS= read -r line; do
    local NAME MODEL SIZE TRAN TYPE
    NAME="$(get_kv NAME "$line")"
    MODEL="$(get_kv MODEL "$line")"
    SIZE="$(get_kv SIZE "$line")"
    TRAN="$(get_kv TRAN "$line")"
    TYPE="$(get_kv TYPE "$line")"

    [[ "${TYPE:-}" != "disk" ]] && continue
    [[ -z "${NAME:-}" ]] && continue

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
  local disk="$1"   # pl. sdc

  # A disk alatti partíciók közül választunk:
  # - legyen FSTYPE (ne üres / -)
  # - ne legyen mountolva (MOUNTPOINT üres)
  # - a legnagyobb legyen
  local best_part=""
  local best_size=0

  # NAME FSTYPE SIZE MOUNTPOINT
  while IFS= read -r line; do
    local name fstype size mnt
    name="$(awk '{print $1}' <<<"$line")"
    fstype="$(awk '{print $2}' <<<"$line")"
    size="$(awk '{print $3}' <<<"$line")"
    mnt="$(awk '{print $4}' <<<"$line")"

    [[ -z "${fstype:-}" || "${fstype:-}" == "-" ]] && continue
    [[ -n "${mnt:-}" && "${mnt:-}" != "-" ]] && continue

    if (( size > best_size )); then
      best_size="$size"
      best_part="$name"
    fi
  done < <(lsblk -rnb -o NAME,FSTYPE,SIZE,MOUNTPOINT "/dev/$disk" | tail -n +2)

  if [[ -z "$best_part" ]]; then
    echo ""
  else
    echo "/dev/$best_part"
  fi
}

safe_mount() {
  local part="$1"

  # ideiglenes, ütközésmentes mountpoint
  TMP_MNT="$(mktemp -d /mnt/.pve-usb-backup.XXXXXX)"

  if mountpoint -q "$TMP_MNT"; then
    msg already_mounted "$TMP_MNT"
    exit 1
  fi

  # extra védelem: ha a part már fel van csatolva máshova, ne nyúljunk hozzá
  local existing_mnt=""
  existing_mnt="$(lsblk -no MOUNTPOINT "$part" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${existing_mnt:-}" ]]; then
    msg part_mounted_elsewhere "$part" "$existing_mnt"
    exit 1
  fi

  # Auto-detect: a mount próbálkozik a fstype alapján (ntfs/exfat esetén kellhet csomag).
  mount "$part" "$TMP_MNT"
}

do_backup() {
  local target="$TMP_MNT/$BACKUP_ROOT_NAME/hosts/$HOSTNAME"
  mkdir -p \
    "$target/etc-pve" \
    "$target/network" \
    "$target/fstab" \
    "$target/meta"

  msg backing_up "$target"

  # Detektáljuk a filesystem típust
  local fs_type=""
  fs_type="$(findmnt -no FSTYPE "$TMP_MNT" 2>/dev/null || echo "unknown")"
  
  local tar_opts="--numeric-owner"
  
  # Csak ext4/xfs/btrfs támogatja az xattrs-t és ACL-eket
  case "$fs_type" in
    ext4|xfs|btrfs)
      tar_opts="--xattrs --acls $tar_opts"
      ;;
    *)
      # FAT32/exFAT/NTFS → skip xattrs
      msg fs_no_xattr "$fs_type"
      ;;
  esac

  # /etc/pve mentés (PVE-specifikus)
  tar $tar_opts -czf \
    "$target/etc-pve/pve-etc-$DATE.tar.gz" \
    /etc/pve

  # Ezek nem minden rendszeren léteznek -> ne álljon meg a script
  cp /etc/network/interfaces "$target/network/interfaces-$DATE" 2>/dev/null || true
  cp /etc/fstab "$target/fstab/fstab-$DATE" 2>/dev/null || true

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

  if [[ -n "${TMP_MNT:-}" ]] && mountpoint -q "$TMP_MNT"; then
    umount "$TMP_MNT" 2>/dev/null || true
  fi

  if [[ -n "${TMP_MNT:-}" ]]; then
    rmdir "$TMP_MNT" 2>/dev/null || true
  fi
}

main() {
  require_root
  require_cmds

  # A safe_remove üzenet csak a cleanup (umount) után menjen ki
  trap 'cleanup; msg safe_remove' EXIT

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

  local part=""
  part="$(pick_partition "$disk")"
  if [[ -z "$part" ]]; then
    msg no_part "$disk"
    msg tip_fs
    exit 1
  fi

  msg using_part "$part"
  safe_mount "$part"
  msg temp_mount "$TMP_MNT"

  do_backup
  msg done
}

main
