#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT_NAME="proxmox-backup"
TMP_MNT="/mnt/.pve-usb-restore"
RESTORE_TMP="/root/.pve-restore-tmp"

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
    need_root) echo "❌ Root jogosultsággal futtasd.";;
    no_usb) echo "❌ Nem találok USB-s lemezt (TRAN=usb vagy udev ID_BUS=usb).";;
    found_usb) echo "Talált USB lemezek:";;
    choose_disk) echo -n "Melyik USB lemezt használjam? (1-$1): ";;
    invalid_choice) echo "❌ Hibás választás.";;
    selected_disk) echo "✅ Kiválasztva: /dev/$1";;
    no_part) echo "❌ A /dev/$1 alatt nem találtam mountolható partíciót (nincs FSTYPE).";;
    tip_fs) echo "   Tipp: legyen rajta ext4/exfat/ntfs fájlrendszeres partíció.";;
    using_part) echo "➡️ Használt partíció: $1";;
    temp_mount) echo "➡️ Ideiglenes mount: $1";;
    already_mounted) echo "❌ A $1 már mountpoint. Előbb umountold.";;
    mount_fail) echo "❌ Nem sikerült mountolni: $1 → $2";;
    no_backups) echo "❌ Nem találok mentéseket itt: $1";;
    found_backups) echo "Elérhető mentések:";;
    choose_backup) echo -n "Melyik mentést állítsam vissza? (1-$1): ";;
    selected_backup) echo "✅ Kiválasztva: $1";;
    warn_overwrite) echo "⚠️ FIGYELEM: Ez felülírhat meglévő VM/LXC configokat és cluster-wide fájlokat (/etc/pve).";;
    confirm) echo -n "Biztosan folytassam? Írd be: YES : ";;
    abort) echo "❌ Megszakítva.";;
    extracting) echo "📦 Kicsomagolás: $1";;
    oldnode) echo "ℹ️ Régi node a mentésben: $1";;
    newnode) echo "ℹ️ Jelenlegi node: $1";;
    restore_global) echo "🔧 Cluster-wide configok visszaállítása (datacenter/users/firewall/domains + storage okosan)";;
    restore_vms) echo "🧠 VM/LXC configok visszaállítása a jelenlegi node alá";;
    restore_net_prompt) echo -n "Visszaállítsam a network/interfaces fájlt is? (y/N): ";;
    restore_fstab_prompt) echo -n "Visszaállítsam az fstab fájlt is? (y/N): ";;
    net_applied) echo "✅ Network config visszaállítva. (Lehet, hogy újraindítás kell!)";;
    fstab_applied) echo "✅ fstab visszaállítva. (mount -a ajánlott)";;

    zfs_detected) echo "🧷 storage.cfg-ben talált zfspool(ok): $1";;
    zfs_try_import) echo "🔎 ZFS pool import próbálkozás: $1";;
    zfs_already) echo "✅ ZFS pool már importálva: $1";;
    zfs_import_ok) echo "✅ ZFS pool import sikerült: $1";;
    zfs_import_skip) echo "⏭️ ZFS pool nem látszik importálhatónak, kihagyom: $1";;
    zfs_import_fail) echo "⚠️ ZFS pool import nem sikerült, storage tiltva: $1";;
    storage_applied) echo "✅ storage.cfg visszaállítva (szükség esetén zfspool blokkok tiltva).";;

    restart_prompt) echo -n "Újraindítsam a Proxmox service-eket (pvedaemon, pveproxy)? (y/N): ";;
    restart_skipped) echo "⏭️ Service restart kihagyva.";;
    restart_services) echo "🔄 Proxmox service restart (pvedaemon, pveproxy, pve-cluster)";;

    validating_backup) echo "🔍 Backup validálása...";;
    backup_not_readable) echo "❌ Backup file nem olvasható: $1";;
    backup_invalid_gzip) echo "❌ Backup file nem érvényes gzip archívum";;
    backup_invalid_tar) echo "❌ Backup file nem érvényes tar archívum";;
    backup_no_etcpve) echo "❌ Backup nem tartalmazza az etc/pve könyvtárat";;
    backup_corrupted) echo "❌ A backup file sérült vagy érvénytelen.";;
    backup_valid) echo "✅ Backup file érvényes";;

    vm_conflicts_warning) echo "⚠️ FIGYELEM: A következő VM/LXC ID-k már léteznek és felül lesznek írva:";;
    vm_conflicts_confirm) echo -n "Biztosan folytatod? (yes/NO): ";;

    done) echo "✅ Restore kész.";;
    safe_remove) echo "✅ USB leválasztva, kihúzhatod.";;

    help) cat <<'EOF'
Használat:
  ./pve-usb-restore.sh [--lang hu|en]

Példa:
  LANGUAGE=en ./pve-usb-restore.sh
EOF
    ;;
    *) echo "[$k] $*";;
  esac
}

_msg_en() {
  local k="$1"; shift || true
  case "$k" in
    need_root) echo "❌ Please run as root.";;
    no_usb) echo "❌ No USB disks found (TRAN=usb or udev ID_BUS=usb).";;
    found_usb) echo "Found USB disks:";;
    choose_disk) echo -n "Which USB disk should I use? (1-$1): ";;
    invalid_choice) echo "❌ Invalid selection.";;
    selected_disk) echo "✅ Selected: /dev/$1";;
    no_part) echo "❌ No mountable partition found on /dev/$1 (no FSTYPE).";;
    tip_fs) echo "   Tip: create a filesystem partition (ext4/exfat/ntfs) on the USB drive.";;
    using_part) echo "➡️ Using partition: $1";;
    temp_mount) echo "➡️ Temporary mount: $1";;
    already_mounted) echo "❌ $1 is already a mountpoint. Please umount it first.";;
    mount_fail) echo "❌ Failed to mount: $1 → $2";;
    no_backups) echo "❌ No backups found under: $1";;
    found_backups) echo "Available backups:";;
    choose_backup) echo -n "Which backup should I restore? (1-$1): ";;
    selected_backup) echo "✅ Selected: $1";;
    warn_overwrite) echo "⚠️ WARNING: This may overwrite VM/LXC configs and cluster-wide files under /etc/pve.";;
    confirm) echo -n "Are you sure? Type: YES : ";;
    abort) echo "❌ Aborted.";;
    extracting) echo "📦 Extracting: $1";;
    oldnode) echo "ℹ️ Old node in backup: $1";;
    newnode) echo "ℹ️ Current node: $1";;
    restore_global) echo "🔧 Restoring cluster-wide configs (datacenter/users/firewall/domains + smart storage)";;
    restore_vms) echo "🧠 Restoring VM/LXC configs into current node";;
    restore_net_prompt) echo -n "Restore network/interfaces too? (y/N): ";;
    restore_fstab_prompt) echo -n "Restore fstab too? (y/N): ";;
    net_applied) echo "✅ Network config restored. (May require restart!)";;
    fstab_applied) echo "✅ fstab restored. (Consider running mount -a)";;

    zfs_detected) echo "🧷 zfspool(s) found in storage.cfg: $1";;
    zfs_try_import) echo "🔎 Trying to import ZFS pool: $1";;
    zfs_already) echo "✅ ZFS pool already imported: $1";;
    zfs_import_ok) echo "✅ ZFS pool import OK: $1";;
    zfs_import_skip) echo "⏭️ ZFS pool not listed as importable, skipping: $1";;
    zfs_import_fail) echo "⚠️ ZFS pool import failed, disabling storage: $1";;
    storage_applied) echo "✅ storage.cfg restored (zfspool blocks disabled if needed).";;

    restart_prompt) echo -n "Restart Proxmox services (pvedaemon, pveproxy, pve-cluster)? (y/N): ";;
    restart_skipped) echo "⏭️ Skipped service restart.";;
    restart_services) echo "🔄 Restarting Proxmox services (pvedaemon, pveproxy, pve-cluster)";;

    validating_backup) echo "🔍 Validating backup...";;
    backup_not_readable) echo "❌ Backup file not readable: $1";;
    backup_invalid_gzip) echo "❌ Backup file is not a valid gzip archive";;
    backup_invalid_tar) echo "❌ Backup file is not a valid tar archive";;
    backup_no_etcpve) echo "❌ Backup does not contain etc/pve directory";;
    backup_corrupted) echo "❌ Backup file is corrupted or invalid.";;
    backup_valid) echo "✅ Backup file is valid";;

    vm_conflicts_warning) echo "⚠️ WARNING: The following VM/LXC IDs already exist and will be overwritten:";;
    vm_conflicts_confirm) echo -n "Are you sure to continue? (yes/NO): ";;

    done) echo "✅ Restore completed.";;
    safe_remove) echo "✅ USB unmounted, safe to unplug.";;
    help) cat <<'EOF'
Usage:
  ./pve-usb-restore.sh [--lang hu|en]

Example:
  LANGUAGE=en ./pve-usb-restore.sh
EOF
    ;;
    *) echo "[$k] $*";;
  esac
}

usage(){ msg help; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    msg need_root
    exit 1
  fi
}

require_deps() {
  local missing=()
  for c in lsblk udevadm mount umount tar awk sed grep cp rsync sync zpool; do
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

cleanup() {
  set +e
  sync
  
  # Umount USB
  if mountpoint -q "$TMP_MNT"; then
    umount "$TMP_MNT" 2>/dev/null || true
  fi
  
  # Remove temp directories
  rm -rf "$RESTORE_TMP" 2>/dev/null || true
  rmdir "$TMP_MNT" 2>/dev/null || true
}

parse_args() {
  while (($#)); do
    case "$1" in
      --lang|-l) shift; LANGUAGE="${1:-hu}";;
      --help|-h) usage; exit 0;;
      *) echo "Unknown option: $1"; usage; exit 1;;
    esac
    shift || true
  done
  case "${LANGUAGE}" in hu|en) ;; *) echo "Invalid --lang (hu|en)"; exit 1;; esac
}

# -------- restore logic --------

find_backups() {
  local etcdir="$1"  # $TMP_MNT/$BACKUP_ROOT_NAME/host/etc-pve
  ls -1 "$etcdir"/pve-etc-*.tar.gz 2>/dev/null || true
}

# Validate that a tar.gz file is valid and contains expected structure
validate_backup() {
  local tarfile="$1"
  
  # Check if file exists and is readable
  if [ ! -r "$tarfile" ]; then
    msg backup_not_readable "$tarfile"
    return 1
  fi
  
  # Check if it's a valid gzip file
  if ! gzip -t "$tarfile" 2>/dev/null; then
    msg backup_invalid_gzip
    return 1
  fi
  
  # Check if tar can list contents
  if ! tar tzf "$tarfile" >/dev/null 2>&1; then
    msg backup_invalid_tar
    return 1
  fi
  
  # Check if it contains etc/pve directory
  if ! tar tzf "$tarfile" 2>/dev/null | grep -q '^etc/pve/'; then
    msg backup_no_etcpve
    return 1
  fi
  
  return 0
}

# Check for VM/LXC ID conflicts
check_vm_conflicts() {
  local src_pve_dir="$1"
  local oldnode="$2"
  local newnode="$3"
  
  local conflicts=()
  
  # Check QEMU VMs
  if [ -d "$src_pve_dir/nodes/$oldnode/qemu-server" ]; then
    for conf in "$src_pve_dir/nodes/$oldnode/qemu-server/"*.conf 2>/dev/null; do
      [ -f "$conf" ] || continue
      local vmid
      vmid="$(basename "$conf" .conf)"
      if [ -f "/etc/pve/nodes/$newnode/qemu-server/$vmid.conf" ]; then
        conflicts+=("VM $vmid")
      fi
    done
  fi
  
  # Check LXC containers
  if [ -d "$src_pve_dir/nodes/$oldnode/lxc" ]; then
    for conf in "$src_pve_dir/nodes/$oldnode/lxc/"*.conf 2>/dev/null; do
      [ -f "$conf" ] || continue
      local ctid
      ctid="$(basename "$conf" .conf)"
      if [ -f "/etc/pve/nodes/$newnode/lxc/$ctid.conf" ]; then
        conflicts+=("LXC $ctid")
      fi
    done
  fi
  
  if (( ${#conflicts[@]} > 0 )); then
    msg vm_conflicts_warning
    printf '  - %s\n' "${conflicts[@]}"
    echo ""
    msg vm_conflicts_confirm
    read -r answer < /dev/tty
    [[ "$answer" == "yes" ]] || return 1
  fi
  
  return 0
}

# Parse zfspool pools from a Proxmox storage.cfg (very common format)
# returns: newline separated pool names
extract_zfspool_pools() {
  local cfg="$1"
  # POSIX-compatible awk (works with mawk on Debian/Proxmox)
  awk '
    /^[[:space:]]*zfspool:[[:space:]]+/ {in_zfs=1; pool=""; next}
    in_zfs==1 && /^[[:space:]]*pool[[:space:]]+/ {pool=$2}
    in_zfs==1 && /^[^[:space:]]/ { if (pool!="") print pool; in_zfs=0; pool="" }
    END{ if (in_zfs==1 && pool!="") print pool }
  ' "$cfg" | awk 'NF' | sort -u
}

pool_is_imported() {
  local pool="$1"
  zpool list -H "$pool" >/dev/null 2>&1
}

pool_is_importable() {
  local pool="$1"
  # zpool import lists importable pools; match exact pool name at line start
  zpool import 2>/dev/null | awk -v p="$pool" '$1=="pool:" && $2==p {found=1} END{exit(found?0:1)}'
}

try_import_pool() {
  local pool="$1"
  if pool_is_imported "$pool"; then
    msg zfs_already "$pool"
    return 0
  fi

  if ! pool_is_importable "$pool"; then
    msg zfs_import_skip "$pool"
    return 2
  fi

  msg zfs_try_import "$pool"
  # -f because pool could be "in use" from previous host; -N to avoid auto-mount surprises
  # Show output to help debug import failures
  if zpool import -f -N "$pool" 2>&1; then
    msg zfs_import_ok "$pool"
    return 0
  else
    echo "⚠️ ZFS import error details shown above"
    return 1
  fi
}

# Disable (comment out) a zfspool stanza by storage ID (zfspool: <id>)
disable_zfspool_stanza_by_id() {
  local cfg_in="$1"
  local zfs_id="$2"
  local cfg_out="$3"

  awk -v id="$zfs_id" '
    BEGIN{in=0}
    {
      line=$0
      if ($0 ~ "^[[:space:]]*zfspool:[[:space:]]+"id"([[:space:]]|$)") {in=1; print "# DISABLED_BY_RESTORE " line; next}
      if (in==1 && $0 ~ "^[^[:space:]]") {in=0}   # new stanza begins
      if (in==1) {print "# DISABLED_BY_RESTORE " line; next}
      print line
    }
  ' "$cfg_in" > "$cfg_out"
}

# Map pool->zfspool IDs that reference it (so we can disable the right stanza(s))
# output lines: "<pool> <id>"
map_zfspool_ids() {
  local cfg="$1"
  # POSIX-compatible awk (works with mawk on Debian/Proxmox)
  awk '
    /^[[:space:]]*zfspool:[[:space:]]+/ {
      in_zfs=1; id=$2; pool=""; next
    }
    in_zfs==1 && /^[[:space:]]*pool[[:space:]]+/ {pool=$2}
    in_zfs==1 && /^[^[:space:]]/ {
      if (pool!="" && id!="") print pool, id
      in_zfs=0; id=""; pool=""
    }
    END{
      if (in_zfs==1 && pool!="" && id!="") print pool, id
    }
  ' "$cfg"
}

restore_cluster_wide_files_smart() {
  local src_pve_dir="$1"  # extracted: .../etc/pve
  msg restore_global

  # always restore these (safe-ish)
  local files=("datacenter.cfg" "user.cfg" "domains.cfg" "firewall.cfg")
  for f in "${files[@]}"; do
    if [ -f "$src_pve_dir/$f" ]; then
      cp -a "$src_pve_dir/$f" "/etc/pve/$f"
    fi
  done

  # storage.cfg: smart restore
  if [ -f "$src_pve_dir/storage.cfg" ]; then
    local tmp_cfg="$RESTORE_TMP/storage.cfg.to_apply"
    cp -a "$src_pve_dir/storage.cfg" "$tmp_cfg"

    # detect pools
    local pools
    pools="$(extract_zfspool_pools "$tmp_cfg" || true)"

    if [[ -n "${pools:-}" ]]; then
      msg zfs_detected "$(tr '\n' ' ' <<<"$pools" | sed 's/[[:space:]]\+$//')"

      # build pool->id map once
      local mapfile_path="$RESTORE_TMP/zfspool.map"
      map_zfspool_ids "$tmp_cfg" > "$mapfile_path" || true

      # for each pool attempt import; if fails => disable all stanzas referencing that pool
      while IFS= read -r pool; do
        [[ -z "${pool:-}" ]] && continue

        if try_import_pool "$pool"; then
          : # ok
        else
          # disable all IDs that reference this pool
          while read -r mp mid; do
            [[ "$mp" != "$pool" ]] && continue
            local tmp2="$RESTORE_TMP/storage.cfg.tmp2"
            disable_zfspool_stanza_by_id "$tmp_cfg" "$mid" "$tmp2"
            mv -f "$tmp2" "$tmp_cfg"
          done < "$mapfile_path"

          msg zfs_import_fail "$pool"
        fi
      done <<< "$pools"
    fi

    cp -a "$tmp_cfg" "/etc/pve/storage.cfg"
    msg storage_applied
  fi
}

restore_vm_lxc_confs() {
  local src_pve_dir="$1"    # extracted: .../etc/pve
  local oldnode="$2"
  local newnode="$3"

  msg restore_vms

  mkdir -p "/etc/pve/nodes/$newnode/qemu-server" "/etc/pve/nodes/$newnode/lxc"

  if [ -d "$src_pve_dir/nodes/$oldnode/qemu-server" ]; then
    cp -a "$src_pve_dir/nodes/$oldnode/qemu-server/"*.conf "/etc/pve/nodes/$newnode/qemu-server/" 2>/dev/null || true
  fi

  if [ -d "$src_pve_dir/nodes/$oldnode/lxc" ]; then
    cp -a "$src_pve_dir/nodes/$oldnode/lxc/"*.conf "/etc/pve/nodes/$newnode/lxc/" 2>/dev/null || true
  fi
}

restore_optional_file_for_date() {
  local kind="$1"          # network|fstab
  local date="$2"          # YYYY-MM-DD
  local base="$3"          # $TMP_MNT/$BACKUP_ROOT_NAME/host

  case "$kind" in
    network)
      local f="$base/network/interfaces-$date"
      if [ -f "$f" ]; then
        cp -a "$f" /etc/network/interfaces
        msg net_applied
      else
        echo "(no network backup for $date)"
      fi
      ;;
    fstab)
      local f="$base/fstab/fstab-$date"
      if [ -f "$f" ]; then
        cp -a "$f" /etc/fstab
        msg fstab_applied
      else
        echo "(no fstab backup for $date)"
      fi
      ;;
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
  read -r choice < /dev/tty

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

  local base="$TMP_MNT/$BACKUP_ROOT_NAME/host"
  local etcdir="$base/etc-pve"

  if [ ! -d "$etcdir" ]; then
    msg no_backups "$etcdir"
    exit 1
  fi

  mapfile -t backups < <(find_backups "$etcdir")
  if (( ${#backups[@]} == 0 )); then
    msg no_backups "$etcdir"
    exit 1
  fi

  msg found_backups
  for i in "${!backups[@]}"; do
    echo "  [$((i+1))] $(basename "${backups[$i]}")"
  done

  msg choose_backup "${#backups[@]}"
  read -r bchoice < /dev/tty

  if ! [[ "$bchoice" =~ ^[0-9]+$ ]] || (( bchoice < 1 || bchoice > ${#backups[@]} )); then
    msg invalid_choice
    exit 1
  fi

  local backup_file="${backups[$((bchoice-1))]}"
  local backup_name
  backup_name="$(basename "$backup_file")"
  msg selected_backup "$backup_name"
  
  # Validate backup file
  msg validating_backup
  if ! validate_backup "$backup_file"; then
    msg backup_corrupted
    exit 1
  fi
  msg backup_valid
  echo ""

  msg warn_overwrite
  msg confirm
  read -r confirm < /dev/tty
  [[ "$confirm" == "YES" ]] || { msg abort; exit 1; }

  rm -rf "$RESTORE_TMP"
  mkdir -p "$RESTORE_TMP"

  msg extracting "$backup_name"
  tar xzf "$backup_file" -C "$RESTORE_TMP"

  # Find old/new node
  local newnode oldnode
  newnode="$(hostname)"
  if [ -d "$RESTORE_TMP/etc/pve/nodes" ]; then
    oldnode="$(ls -1 "$RESTORE_TMP/etc/pve/nodes" | head -n 1 || true)"
  else
    oldnode=""
  fi

  msg oldnode "${oldnode:-unknown}"
  msg newnode "$newnode"

  if [ -z "$oldnode" ]; then
    echo "❌ Can't determine OLDNODE from backup (missing etc/pve/nodes)."
    exit 1
  fi
  
  # Check for VM/LXC conflicts
  echo ""
  if ! check_vm_conflicts "$RESTORE_TMP/etc/pve" "$oldnode" "$newnode"; then
    msg abort
    exit 1
  fi
  echo ""

  # Restore cluster-wide files (smart storage) + VM/LXC confs
  restore_cluster_wide_files_smart "$RESTORE_TMP/etc/pve"
  restore_vm_lxc_confs "$RESTORE_TMP/etc/pve" "$oldnode" "$newnode"

  # Optional: network + fstab matching the backup date in filename
  local date="${backup_name#pve-etc-}"
  date="${date%.tar.gz}"

  msg restore_net_prompt
  read -r yn < /dev/tty
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    restore_optional_file_for_date "network" "$date" "$base"
  fi

  msg restore_fstab_prompt
  read -r yn2 < /dev/tty
  if [[ "$yn2" =~ ^[Yy]$ ]]; then
    restore_optional_file_for_date "fstab" "$date" "$base"
  fi

  # -------- OPTIONAL restart (only at the end) --------
  msg restart_prompt
  read -r yn3 < /dev/tty
  if [[ "$yn3" =~ ^[Yy]$ ]]; then
    msg restart_services
    systemctl restart pvedaemon pveproxy pve-cluster >/dev/null 2>&1 || true
    # Wait a bit for services to stabilize
    sleep 2
  else
    msg restart_skipped
  fi

  msg done
  msg safe_remove
}

main "$@"
