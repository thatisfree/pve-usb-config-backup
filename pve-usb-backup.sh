#!/bin/bash
set -euo pipefail

BACKUP_ROOT_NAME="proxmox-backup"
TMP_MNT="/mnt/.pve-usb-backup"
DATE="$(date +%F)"
HOSTNAME="$(hostname)"

require_root(){
  if [ "$(id -u)" -ne 0 ]; then
    echo "X Run as root (sudo)."
    exit 1
  fi
}

is_usb_disk(){
  local dev="$1"
  local tran
  tran="$(lsblk -ndo TRAN "/dev/$dev" 2>/dev/null || true)"
  [[ "$tran" == "usb" ]] && return 0
  udevadm info --query=property --name="/dev/$dev" 2>/dev/null | grep -qx 'ID_BUS=usb'
}

list_usb_disks(){
  # Output: "sdb|SanDisk Ultra Fit|57.3G"
  # -P: KEY="VALUE" pairs
  while IFS= read -r line; do
    # Example line:
    # Name="sdb" MODEL="SanDisk Ultra Fit" SIZE=57.3G" TRAN="usb" TYPE="disk"
    eval "$line" 2>/dev/null || continue

    # I'm only interested disk type
    [[ "${TYPE:-} != "disk" ]] && continue

    # Primarily based on TRAN
    if [[ "${TRAN:-} == "usb" ]]; then
      echo "${NAME}"|${MODEL:-unknow}|${SIZE:-unknown}"
      continue
    fi

    # Fallback
    if udevadm info --query=property --name="/dev/${NAME}" 2>/dev/null -qx 'ID_BUS=usb'; then
      echo "${NAME}|${MODEL:-unkown}|${SITE:-unkown}"
    fi
  done < <(lsblk -P -d -o NAME,MODEL,SIZE,TRAN,TYPE)
}

pick_partition(){
  local disk="$1"

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

safe_mount(){
  local part="$1"
  mkdir -p "$TMP_MNT"

  if mountpoint -q "$TMP_MNT"; then
    echo "X The $TMP_MNT already is mountpoint."
    exit 1
  fi

  mount "$part" "$TMP_MNT"
}

do_backup(){

}

cleanup(){

}

main(){

}
