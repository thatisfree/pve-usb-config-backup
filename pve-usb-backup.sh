#!/usr/bin/env bash
set -euo pipefail

# =========================
# Proxmox USB host config backup
# - Detect USB disks
# - Ask which disk to use
# - Auto-pick largest filesystem partition
# - Temp mount -> backup -> sync -> umount
# =========================

BACKUP_ROOT_NAME="proxmox-backup"
TMP_MNT="/mnt/.pve-usb-backup"
DATE="$(date +%F)"
HOSTNAME="$(hostname)"

LANGUAGE="${LANGUAGE:-hu}"   # hu|en (default: hu)

# ---------- i18n ----------
msg() {
  # usage: msg <key> [args...]
  local key="$1"; shift || true
  case "${LANGUAGE}" in
    en) _msg_en "$key" "$@";;
    *)  _msg_hu "$key" "$@";;
  esac
}

_msg_hu() {
  local key="$1"; shift || true
  case "$key" in
    need_root)          echo "❌ Rootként futtasd (sudo).";;
    deps_missing)       echo "❌ Hiányzó parancs(ok): $*";;
    no_usb)             echo "❌ Nem találok USB-s típusú lemezt (TRAN=usb vagy udev ID_BUS=usb).";;
    found_usb)          echo "Talált USB lemezek:";;
    choose_disk)        echo -n "Melyikre mentsek? (1-$1): ";;
    invalid_choice)     echo "❌ Hibás választás.";;
    selected_disk)      echo "✅ Kiválasztva: /dev/$1";;
    no_mountable_part)  echo "❌ A /dev/$1 alatt nem találtam mountolható partíciót (nincs FSTYPE).";;
    tip_fs)             echo "   Tipp: legyen rajta pl. ext4/exfat/ntfs partíció fájlrendszerrel.";;
    using_part)         echo "➡️ Használt partíció: $1";;
    temp_mount)         echo "➡️ Ideiglenes mount: $1";;
    already_mounted)    echo "❌ A $1 már mountpoint. Előbb umountold.";;
    mount_fail)         echo "❌ Nem sikerült mountolni: $1 → $2";;
    backup_to)          echo "📦 Mentés ide: $1";;
    done_sync)          echo "✅ Kész. Sync + umount...";;
    safe_remove)        echo "✅ Le lehet húzni az USB-t.";;
    help)               cat <<'EOF'
Használat:
  sudo ./pve-usb-backup.sh [--lang hu|en]

Opciók:
  --lang, -l   Nyelv (hu vagy en). Alap: hu (vagy LANGUAGE env)
  --help, -h   Súgó

Példa:
  sudo ./pve-usb-backup.sh --lang en
  LANGUAGE=en sudo ./pve-usb-backup.sh
EOF
    ;;
    *) echo "[$key] $*";;
  esac
}

_msg_en() {
  local key="$1"; shift || true
  case "$key" in
    need_root)          echo "❌ Please run as root (sudo).";;
    deps_missing)       echo "❌ Missing command(s): $*";;
    no_usb)             echo "❌ No USB-type disks found (TRAN=usb or udev ID_BUS=usb).";;
    found_usb)          echo "Found USB disks:";;
    choose_disk)        echo -n "Which one should I use? (1-$1): ";;
    invalid_choice)     echo "❌ Invalid selection.";;
    selected_disk)      echo "✅ Selected: /dev/$1";;
    no_mountable_part)  echo "❌ No mountable partition found on /dev/$1 (no FSTYPE).";;
    tip_fs)             echo "   Tip: create a filesystem partition (ext4/exfat/ntfs) on the USB drive.";;
    using_part)         echo "➡️ Using partition: $1";;
    temp_mount)         echo "➡️ Temporary mount: $1";;
    already_mounted)    echo "❌ $1 is already a mountpoint. Please umount it first.";;
    mount_fail)         echo "❌ Failed to mount: $1 → $2";;
    backup_to)          echo "📦 Backing up to: $1";;
    done_sync)          echo "✅ Done. Sync + umount...";;
    safe_remove)        echo "✅ Safe to unplug the USB drive.";;
    help)               cat <<'EOF'
Usage:
  sudo ./pve-usb-backup.sh [--lang hu|en]

Options:
  --lang, -l   Language (hu or en). Default: hu (or LANGUAGE env)
  --help, -h   Help

Examples:
  sudo ./pve-usb-backup.sh --lang en
  LANGUAGE=en sudo ./pve-usb-backup.sh
EOF
    ;;
    *) echo "[$key] $*";;
  esac
}

# ---------- helpers ----------
usage() { msg help; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    msg need_root
    exit 1
  fi
}

require_deps() {
  local missing=()
  for c in lsblk udevadm mount umount tar awk sed grep cp rsync sync; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    msg deps_missing "${missing[*]}"
    exit 1
  fi
}

# Return lines: NAME|MODEL|SIZE
list_usb_disks() {
  # Use lsblk -P to safely parse MODEL with spaces.
  # Fallback to udev ID_BUS=usb if TRAN empty/unreliable.
  while IFS= read -r line; do
    # NAME="sdb" MODEL="SanDisk Ultra Fit" SIZE="57.3G" TRAN="usb" TYPE="disk"
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
  local disk="$1"   # e.g. sdc
  local best_part=""
  local best_size=0

  # Raw, numeric, bytes: no tree chars, stable parsing
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

  msg backup_to "$target"

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
  if mountpoint -q "$TMP_MNT"; then
    umount "$TMP_MNT"
  fi
}

# ---------- arg parsing ----------
parse_args() {
  while (($#)); do
    case "$1" in
      --lang|-l)
        shift
        LANGUAGE="${1:-hu}"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift || true
  done

  case "${LANGUAGE}" in
    hu|en) ;;
    *) echo "Invalid --lang. Use hu or en."; exit 1;;
  esac
}

main() {
  parse_args "$@"
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
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#disks[@]} )); then
    msg invalid_choice
    exit 1
  fi

  IFS='|' read -r disk _ _ <<<"${disks[$((choice-1))]}"
  msg selected_disk "$disk"

  part="$(pick_partition "$disk")"
  if [[ -z "$part" ]]; then
    msg no_mountable_part "$disk"
    msg tip_fs
    exit 1
  fi

  msg using_part "$part"
  msg temp_mount "$TMP_MNT"
  safe_mount "$part"

  do_backup

  msg done_sync
  msg safe_remove
}

main "$@"
