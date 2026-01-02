#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT_NAME="proxmox-backup"

# futás közben generáljuk (ütközésmentes)
TMP_MNT=""
RESTORE_TMP=""

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
    need_root) echo "❌ Root jogosultsággal futtasd (sudo).";;
    need_cmd) echo "❌ Hiányzó parancs: $1";;

    no_usb) echo "❌ Nem találok USB-s lemezt (TRAN=usb vagy udev ID_BUS=usb).";;
    found_usb) echo "Talált USB lemezek:";;
    choose_disk) echo -n "Melyik USB lemezt használjam? (1-$1): ";;
    invalid_choice) echo "❌ Hibás választás.";;
    selected_disk) echo "✅ Kiválasztva: /dev/$1";;

    no_part) echo "❌ A /dev/$1 alatt nem találtam mountolható partíciót (nincs FSTYPE / mind mountolva van).";;
    tip_fs) echo "   Tipp: legyen rajta ext4/exfat/ntfs fájlrendszeres partíció (és ne legyen felcsatolva).";;
    using_part) echo "➡️ Használt partíció: $1";;

    temp_mount) echo "➡️ Ideiglenes mount: $1";;
    already_mounted) echo "❌ A $1 már mountpoint. Előbb umountold.";;
    part_mounted_elsewhere) echo "❌ A partíció már fel van csatolva máshova: $1 -> $2";;
    mount_fail) echo "❌ Nem sikerült mountolni: $1 → $2";;

    no_hosts) echo "❌ Nem találok host mentéseket itt: $1";;
    found_hosts) echo "Elérhető host mentések:";;
    choose_host) echo -n "Melyik host mentését állítsam vissza? (1-$1): ";;
    selected_host) echo "✅ Kiválasztott host: $1";;

    no_backups) echo "❌ Nem találok mentéseket itt: $1";;
    found_backups) echo "Elérhető mentések:";;
    choose_backup) echo -n "Melyik mentést állítsam vissza? (1-$1): ";;
    selected_backup) echo "✅ Kiválasztva: $1";;

    validating_backup) echo "🔍 Backup validálása...";;
    backup_not_readable) echo "❌ Backup file nem olvasható: $1";;
    backup_invalid_gzip) echo "❌ Backup file nem érvényes gzip archívum";;
    backup_invalid_tar) echo "❌ Backup file nem érvényes tar archívum";;
    backup_no_etcpve) echo "❌ Backup nem tartalmazza az etc/pve könyvtárat";;
    backup_corrupted) echo "❌ A backup file sérült vagy érvénytelen.";;
    backup_valid) echo "✅ Backup file érvényes";;

    warn_overwrite) echo "⚠️ FIGYELEM: Ez felülírhat cluster-wide fájlokat (/etc/pve) és VM/LXC configokat.";;

    confirm) echo -n "Biztosan folytassam? Írd be: YES : ";;
    abort) echo "❌ Megszakítva.";;

    extracting) echo "📦 Kicsomagolás: $1";;
    oldnode) echo "ℹ️ Régi node a mentésben: $1";;
    newnode) echo "ℹ️ Jelenlegi node: $1";;

    vm_conflicts_warning) echo "⚠️ FIGYELEM: A következő VM/LXC ID-k már léteznek és felül lesznek írva:";;
    vm_conflicts_confirm) echo -n "Biztosan folytatod? (yes/NO): ";;

    restore_global) echo "🔧 Cluster-wide configok visszaállítása (datacenter/users/firewall/domains + storage okosan)";;
    restore_vms) echo "🧠 VM/LXC configok visszaállítása a jelenlegi node alá";;

    zfs_detected) echo "🧷 storage.cfg-ben talált zfspool(ok): $1";;
    zfs_no_cmd) echo "⚠️ Nincs zpool parancs, zfspool blokkok tiltva lesznek a storage.cfg-ben.";;
    zfs_try_import) echo "🔎 ZFS pool import próbálkozás: $1";;
    zfs_already) echo "✅ ZFS pool már importálva: $1";;
    zfs_import_ok) echo "✅ ZFS pool import sikerült: $1";;
    zfs_import_skip) echo "⏭️ ZFS pool nem látszik importálhatónak, kihagyom: $1";;
    zfs_import_fail) echo "⚠️ ZFS pool import nem sikerült, storage tiltva: $1";;
    storage_applied) echo "✅ storage.cfg visszaállítva (szükség esetén zfspool blokkok tiltva).";;

    restore_net_prompt) echo -n "Visszaállítsam a network/interfaces fájlt is? (y/N): ";;
    restore_fstab_prompt) echo -n "Visszaállítsam az fstab fájlt is? (y/N): ";;
    net_applied) echo "✅ Network config visszaállítva. (Lehet, hogy újraindítás kell!)";;
    fstab_applied) echo "✅ fstab visszaállítva. (mount -a ajánlott)";;

    restart_prompt) echo -n "Újraindítsam a Proxmox service-eket (pvedaemon, pveproxy, pve-cluster)? (y/N): ";;
    restart_skipped) echo "⏭️ Service restart kihagyva.";;
    restart_services) echo "🔄 Proxmox service restart (pvedaemon, pveproxy, pve-cluster)";;

    done) echo "✅ Restore kész.";;
    safe_remove) echo "✅ USB leválasztva, kihúzhatod.";;

    help) cat <<'EOF'
Használat:
  ./pve-usb-restore.sh [hu|en]
  ./pve-usb-restore.sh --lang hu|en
  LANGUAGE=en ./pve-usb-restore.sh

Példa:
  ./pve-usb-restore.sh en
EOF
    ;;
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
    choose_disk) echo -n "Which USB disk should I use? (1-$1): ";;
    invalid_choice) echo "❌ Invalid selection.";;
    selected_disk) echo "✅ Selected: /dev/$1";;

    no_part) echo "❌ No mountable partition found on /dev/$1 (no FSTYPE / all mounted).";;
    tip_fs) echo "   Tip: create a filesystem partition (ext4/exfat/ntfs) on the USB drive (and ensure it's not mounted).";;
    using_part) echo "➡️ Using partition: $1";;

    temp_mount) echo "➡️ Temporary mount: $1";;
    already_mounted) echo "❌ $1 is already a mountpoint. Please umount it first.";;
    part_mounted_elsewhere) echo "❌ Partition is already mounted elsewhere: $1 -> $2";;
    mount_fail) echo "❌ Failed to mount: $1 → $2";;

    no_hosts) echo "❌ No host backups found under: $1";;
    found_hosts) echo "Available host backups:";;
    choose_host) echo -n "Which host backup should I restore? (1-$1): ";;
    selected_host) echo "✅ Selected host: $1";;

    no_backups) echo "❌ No backups found under: $1";;
    found_backups) echo "Available backups:";;
    choose_backup) echo -n "Which backup should I restore? (1-$1): ";;
    selected_backup) echo "✅ Selected: $1";;

    validating_backup) echo "🔍 Validating backup...";;
    backup_not_readable) echo "❌ Backup file not readable: $1";;
    backup_invalid_gzip) echo "❌ Backup file is not a valid gzip archive";;
    backup_invalid_tar) echo "❌ Backup file is not a valid tar archive";;
    backup_no_etcpve) echo "❌ Backup does not contain etc/pve directory";;
    backup_corrupted) echo "❌ Backup file is corrupted or invalid.";;
    backup_valid) echo "✅ Backup file is valid";;

    warn_overwrite) echo "⚠️ WARNING: This may overwrite cluster-wide files under /etc/pve and VM/LXC configs.";;

    confirm) echo -n "Are you sure? Type: YES : ";;
    abort) echo "❌ Aborted.";;

    extracting) echo "📦 Extracting: $1";;
    oldnode) echo "ℹ️ Old node in backup: $1";;
    newnode) echo "ℹ️ Current node: $1";;

    vm_conflicts_warning) echo "⚠️ WARNING: The following VM/LXC IDs already exist and will be overwritten:";;
    vm_conflicts_confirm) echo -n "Are you sure to continue? (yes/NO): ";;

    restore_global) echo "🔧 Restoring cluster-wide configs (datacenter/users/firewall/domains + smart storage)";;
    restore_vms) echo "🧠 Restoring VM/LXC configs into current node";;

    zfs_detected) echo "🧷 zfspool(s) found in storage.cfg: $1";;
    zfs_no_cmd) echo "⚠️ zpool command missing; zfspool stanzas will be disabled in storage.cfg.";;
    zfs_try_import) echo "🔎 Trying to import ZFS pool: $1";;
    zfs_already) echo "✅ ZFS pool already imported: $1";;
    zfs_import_ok) echo "✅ ZFS pool import OK: $1";;
    zfs_import_skip) echo "⏭️ ZFS pool not listed as importable, skipping: $1";;
    zfs_import_fail) echo "⚠️ ZFS pool import failed, disabling storage: $1";;
    storage_applied) echo "✅ storage.cfg restored (zfspool blocks disabled if needed).";;

    restore_net_prompt) echo -n "Restore network/interfaces too? (y/N): ";;
    restore_fstab_prompt) echo -n "Restore fstab too? (y/N): ";;
    net_applied) echo "✅ Network config restored. (May require restart!)";;
    fstab_applied) echo "✅ fstab restored. (Consider running mount -a)";;

    restart_prompt) echo -n "Restart Proxmox services (pvedaemon, pveproxy, pve-cluster)? (y/N): ";;
    restart_skipped) echo "⏭️ Skipped service restart.";;
    restart_services) echo "🔄 Restarting Proxmox services (pvedaemon, pveproxy, pve-cluster)";;

    done) echo "✅ Restore completed.";;
    safe_remove) echo "✅ USB unmounted, safe to unplug.";;

    help) cat <<'EOF'
Usage:
  ./pve-usb-restore.sh [hu|en]
  ./pve-usb-restore.sh --lang hu|en
  LANGUAGE=en ./pve-usb-restore.sh

Example:
  ./pve-usb-restore.sh en
EOF
    ;;
    *) echo "[$k] $*";;
  esac
}

usage() { msg help; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || { msg need_root; exit 1; }
}

require_cmds() {
  local c
  for c in lsblk udevadm mount umount mountpoint tar awk sed grep cp sync hostname mktemp gzip; do
    command -v "$c" >/dev/null 2>&1 || { msg need_cmd "$c"; exit 1; }
  done
  # opcionális, de ha van, tudunk restartolni
  command -v systemctl >/dev/null 2>&1 || true
  # zpool opcionális (storage okosításnál)
  command -v zpool >/dev/null 2>&1 || true
}

parse_args() {
  # elfogadjuk: "en" / "hu" első paramként, illetve --lang hu|en
  while (($#)); do
    case "$1" in
      hu|en) LANGUAGE="$1"; shift || true;;
      --lang|-l) shift; LANGUAGE="${1:-hu}"; shift || true;;
      --help|-h) usage; exit 0;;
      *) echo "Unknown option: $1"; usage; exit 1;;
    esac
  done
  case "${LANGUAGE}" in hu|en) ;; *) echo "Invalid language (hu|en)"; exit 1;; esac
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

  # NAME FSTYPE SIZE MOUNTPOINT
  local best_part="" best_size=0
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

  [[ -n "$best_part" ]] && echo "/dev/$best_part" || echo ""
}

safe_mount() {
  local part="$1"

  TMP_MNT="$(mktemp -d /mnt/.pve-usb-restore.XXXXXX)"

  if mountpoint -q "$TMP_MNT"; then
    msg already_mounted "$TMP_MNT"
    exit 1
  fi

  local existing_mnt=""
  existing_mnt="$(lsblk -no MOUNTPOINT "$part" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${existing_mnt:-}" ]]; then
    msg part_mounted_elsewhere "$part" "$existing_mnt"
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
  if [[ -n "${TMP_MNT:-}" ]] && mountpoint -q "$TMP_MNT"; then
    umount "$TMP_MNT" 2>/dev/null || true
  fi
  [[ -n "${RESTORE_TMP:-}" ]] && rm -rf "$RESTORE_TMP" 2>/dev/null || true
  [[ -n "${TMP_MNT:-}" ]] && rmdir "$TMP_MNT" 2>/dev/null || true
}

find_hosts() {
  local root="$1" # $TMP_MNT/$BACKUP_ROOT_NAME/hosts
  ls -1 "$root" 2>/dev/null || true
}

find_backups_for_host() {
  local host_base="$1" # $TMP_MNT/.../hosts/<host>
  ls -1 "$host_base/etc-pve"/pve-etc-*.tar.gz 2>/dev/null || true
}

validate_backup() {
  local tarfile="$1"

  [[ -r "$tarfile" ]] || { msg backup_not_readable "$tarfile"; return 1; }

  if ! gzip -t "$tarfile" 2>/dev/null; then
    msg backup_invalid_gzip
    return 1
  fi

  if ! tar tzf "$tarfile" >/dev/null 2>&1; then
    msg backup_invalid_tar
    return 1
  fi

  if ! tar tzf "$tarfile" 2>/dev/null | grep -q '^etc/pve/'; then
    msg backup_no_etcpve
    return 1
  fi

  return 0
}

check_vm_conflicts() {
  local src_pve_dir="$1" # extracted .../etc/pve
  local oldnode="$2"
  local newnode="$3"

  local conflicts=()

  if [[ -d "$src_pve_dir/nodes/$oldnode/qemu-server" ]]; then
    local conf
    for conf in "$src_pve_dir/nodes/$oldnode/qemu-server/"*.conf; do
      [[ -f "$conf" ]] || continue
      local vmid
      vmid="$(basename "$conf" .conf)"
      [[ -f "/etc/pve/nodes/$newnode/qemu-server/$vmid.conf" ]] && conflicts+=("VM $vmid")
    done
  fi

  if [[ -d "$src_pve_dir/nodes/$oldnode/lxc" ]]; then
    local conf
    for conf in "$src_pve_dir/nodes/$oldnode/lxc/"*.conf; do
      [[ -f "$conf" ]] || continue
      local ctid
      ctid="$(basename "$conf" .conf)"
      [[ -f "/etc/pve/nodes/$newnode/lxc/$ctid.conf" ]] && conflicts+=("LXC $ctid")
    done
  fi

  if (( ${#conflicts[@]} > 0 )); then
    msg vm_conflicts_warning
    printf '  - %s\n' "${conflicts[@]}"
    echo ""
    msg vm_conflicts_confirm
    local answer
    read -r answer < /dev/tty
    [[ "$answer" == "yes" ]] || return 1
  fi

  return 0
}

extract_zfspool_pools() {
  local cfg="$1"
  awk '
    /^[[:space:]]*zfspool:[[:space:]]+/ {in_zfs=1; pool=""; next}
    in_zfs==1 && /^[[:space:]]*pool[[:space:]]+/ {pool=$2}
    in_zfs==1 && /^[^[:space:]]/ { if (pool!="") print pool; in_zfs=0; pool="" }
    END{ if (in_zfs==1 && pool!="") print pool }
  ' "$cfg" | awk 'NF' | sort -u
}

map_zfspool_ids() {
  local cfg="$1"
  awk '
    /^[[:space:]]*zfspool:[[:space:]]+/ {in_zfs=1; id=$2; pool=""; next}
    in_zfs==1 && /^[[:space:]]*pool[[:space:]]+/ {pool=$2}
    in_zfs==1 && /^[^[:space:]]/ { if (pool!="" && id!="") print pool, id; in_zfs=0; id=""; pool="" }
    END{ if (in_zfs==1 && pool!="" && id!="") print pool, id }
  ' "$cfg"
}

disable_zfspool_stanza_by_id() {
  local cfg_in="$1" zfs_id="$2" cfg_out="$3"
  awk -v id="$zfs_id" '
    BEGIN{in=0}
    {
      if ($0 ~ "^[[:space:]]*zfspool:[[:space:]]+"id"([[:space:]]|$)") {in=1; print "# DISABLED_BY_RESTORE " $0; next}
      if (in==1 && $0 ~ "^[^[:space:]]") {in=0}
      if (in==1) {print "# DISABLED_BY_RESTORE " $0; next}
      print $0
    }
  ' "$cfg_in" > "$cfg_out"
}

pool_is_imported() {
  local pool="$1"
  zpool list -H "$pool" >/dev/null 2>&1
}

pool_is_importable() {
  local pool="$1"
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
  if zpool import -f -N "$pool" >/dev/null 2>&1; then
    msg zfs_import_ok "$pool"
    return 0
  fi

  return 1
}

restore_cluster_wide_files_smart() {
  local src_pve_dir="$1" # extracted: .../etc/pve
  msg restore_global

  local f
  for f in datacenter.cfg user.cfg domains.cfg firewall.cfg; do
    [[ -f "$src_pve_dir/$f" ]] && cp -a "$src_pve_dir/$f" "/etc/pve/$f"
  done

  if [[ -f "$src_pve_dir/storage.cfg" ]]; then
    local tmp_cfg="$RESTORE_TMP/storage.cfg.to_apply"
    cp -a "$src_pve_dir/storage.cfg" "$tmp_cfg"

    local pools=""
    pools="$(extract_zfspool_pools "$tmp_cfg" || true)"

    if [[ -n "${pools:-}" ]]; then
      msg zfs_detected "$(tr '\n' ' ' <<<"$pools" | sed 's/[[:space:]]\+$//')"

      if ! command -v zpool >/dev/null 2>&1; then
        msg zfs_no_cmd
        # nincs zpool: tiltsunk minden zfspool stanzát
        local mapfile_path="$RESTORE_TMP/zfspool.map"
        map_zfspool_ids "$tmp_cfg" > "$mapfile_path" || true
        while read -r mp mid; do
          [[ -n "${mid:-}" ]] || continue
          local tmp2="$RESTORE_TMP/storage.cfg.tmp2"
          disable_zfspool_stanza_by_id "$tmp_cfg" "$mid" "$tmp2"
          mv -f "$tmp2" "$tmp_cfg"
        done < "$mapfile_path"
      else
        local mapfile_path="$RESTORE_TMP/zfspool.map"
        map_zfspool_ids "$tmp_cfg" > "$mapfile_path" || true

        while IFS= read -r pool; do
          [[ -n "${pool:-}" ]] || continue
          if try_import_pool "$pool"; then
            :
          else
            # disable all IDs referencing this pool
            while read -r mp mid; do
              [[ "$mp" == "$pool" ]] || continue
              [[ -n "${mid:-}" ]] || continue
              local tmp2="$RESTORE_TMP/storage.cfg.tmp2"
              disable_zfspool_stanza_by_id "$tmp_cfg" "$mid" "$tmp2"
              mv -f "$tmp2" "$tmp_cfg"
            done < "$mapfile_path"
            msg zfs_import_fail "$pool"
          fi
        done <<< "$pools"
      fi
    fi

    cp -a "$tmp_cfg" "/etc/pve/storage.cfg"
    msg storage_applied
  fi
}

restore_vm_lxc_confs() {
  local src_pve_dir="$1"
  local oldnode="$2"
  local newnode="$3"

  msg restore_vms

  mkdir -p "/etc/pve/nodes/$newnode/qemu-server" "/etc/pve/nodes/$newnode/lxc"

  if [[ -d "$src_pve_dir/nodes/$oldnode/qemu-server" ]]; then
    cp -a "$src_pve_dir/nodes/$oldnode/qemu-server/"*.conf "/etc/pve/nodes/$newnode/qemu-server/" 2>/dev/null || true
  fi

  if [[ -d "$src_pve_dir/nodes/$oldnode/lxc" ]]; then
    cp -a "$src_pve_dir/nodes/$oldnode/lxc/"*.conf "/etc/pve/nodes/$newnode/lxc/" 2>/dev/null || true
  fi
}

restore_optional_file_for_date() {
  local kind="$1"          # network|fstab
  local date="$2"          # YYYY-MM-DD
  local host_base="$3"     # $TMP_MNT/.../hosts/<host>

  case "$kind" in
    network)
      local f="$host_base/network/interfaces-$date"
      if [[ -f "$f" ]]; then
        cp -a "$f" /etc/network/interfaces
        msg net_applied
      fi
      ;;
    fstab)
      local f="$host_base/fstab/fstab-$date"
      if [[ -f "$f" ]]; then
        cp -a "$f" /etc/fstab
        msg fstab_applied
      fi
      ;;
  esac
}

restart_services_prompt() {
  msg restart_prompt
  local yn
  read -r yn < /dev/tty
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      msg restart_services
      systemctl restart pve-cluster pvedaemon pveproxy >/dev/null 2>&1 || true
      sleep 2
    fi
  else
    msg restart_skipped
  fi
}

main() {
  parse_args "$@"
  require_root
  require_cmds

  # safe_remove csak umount után
  trap 'cleanup; msg safe_remove' EXIT

  mapfile -t disks < <(list_usb_disks)
  if (( ${#disks[@]} == 0 )); then
    msg no_usb
    exit 1
  fi

  msg found_usb
  local i
  for i in "${!disks[@]}"; do
    IFS='|' read -r name model size <<<"${disks[$i]}"
    echo "  [$((i+1))] /dev/$name  (${model})  ${size}"
  done

  msg choose_disk "${#disks[@]}"
  local choice
  read -r choice < /dev/tty

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#disks[@]} )); then
    msg invalid_choice
    exit 1
  fi

  local disk
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
  safe_mount "$part"
  msg temp_mount "$TMP_MNT"

  local hosts_root="$TMP_MNT/$BACKUP_ROOT_NAME/hosts"
  mapfile -t hosts < <(find_hosts "$hosts_root")
  if (( ${#hosts[@]} == 0 )); then
    msg no_hosts "$hosts_root"
    exit 1
  fi

  msg found_hosts
  for i in "${!hosts[@]}"; do
    echo "  [$((i+1))] ${hosts[$i]}"
  done

  msg choose_host "${#hosts[@]}"
  local hchoice
  read -r hchoice < /dev/tty
  if ! [[ "$hchoice" =~ ^[0-9]+$ ]] || (( hchoice < 1 || hchoice > ${#hosts[@]} )); then
    msg invalid_choice
    exit 1
  fi

  local host="${hosts[$((hchoice-1))]}"
  msg selected_host "$host"

  local host_base="$hosts_root/$host"

  mapfile -t backups < <(find_backups_for_host "$host_base")
  if (( ${#backups[@]} == 0 )); then
    msg no_backups "$host_base/etc-pve"
    exit 1
  fi

  msg found_backups
  for i in "${!backups[@]}"; do
    echo "  [$((i+1))] $(basename "${backups[$i]}")"
  done

  msg choose_backup "${#backups[@]}"
  local bchoice
  read -r bchoice < /dev/tty
  if ! [[ "$bchoice" =~ ^[0-9]+$ ]] || (( bchoice < 1 || bchoice > ${#backups[@]} )); then
    msg invalid_choice
    exit 1
  fi

  local backup_file="${backups[$((bchoice-1))]}"
  local backup_name
  backup_name="$(basename "$backup_file")"
  msg selected_backup "$backup_name"

  msg validating_backup
  if ! validate_backup "$backup_file"; then
    msg backup_corrupted
    exit 1
  fi
  msg backup_valid
  echo ""

  msg warn_overwrite
  msg confirm
  local confirm
  read -r confirm < /dev/tty
  [[ "$confirm" == "YES" ]] || { msg abort; exit 1; }

  RESTORE_TMP="$(mktemp -d /root/.pve-restore-tmp.XXXXXX)"

  msg extracting "$backup_name"
  tar xzf "$backup_file" -C "$RESTORE_TMP"

  local newnode oldnode
  newnode="$(hostname -s 2>/dev/null || hostname)"
  oldnode="$(ls -1 "$RESTORE_TMP/etc/pve/nodes" 2>/dev/null | head -n 1 || true)"

  msg oldnode "${oldnode:-unknown}"
  msg newnode "$newnode"

  if [[ -z "${oldnode:-}" ]]; then
    echo "❌ Nem tudom meghatározni a régi node nevét (hiányzik: etc/pve/nodes)."
    exit 1
  fi

  echo ""
  if ! check_vm_conflicts "$RESTORE_TMP/etc/pve" "$oldnode" "$newnode"; then
    msg abort
    exit 1
  fi
  echo ""

  restore_cluster_wide_files_smart "$RESTORE_TMP/etc/pve"
  restore_vm_lxc_confs "$RESTORE_TMP/etc/pve" "$oldnode" "$newnode"

  # opcionális: network + fstab a mentés dátuma alapján
  local date="${backup_name#pve-etc-}"
  date="${date%.tar.gz}"

  msg restore_net_prompt
  local yn
  read -r yn < /dev/tty
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    restore_optional_file_for_date "network" "$date" "$host_base"
  fi

  msg restore_fstab_prompt
  local yn2
  read -r yn2 < /dev/tty
  if [[ "$yn2" =~ ^[Yy]$ ]]; then
    restore_optional_file_for_date "fstab" "$date" "$host_base"
  fi

  restart_services_prompt

  msg done
}

main "$@"
