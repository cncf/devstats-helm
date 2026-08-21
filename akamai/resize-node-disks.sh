#!/bin/bash
# Re-allocates each Linode's plan-included local SSD (replaces the OCI 8xNVMe mdadm RAID-10):
#   - shut down
#   - resize root disk to ROOT_DISK_MB (120 GB)
#   - delete swap disk (swap must stay off for kubelet anyway)
#   - create one RAW disk "data" from the full remaining plan allocation
#     (RAW because Linode can't create btrfs; node-setup.sh formats it btrfs+zstd)
#   - attach it as sdc in the config profile
#   - boot
# The disk is then mounted at /data by node-setup.sh (fstab UUID entry).
#
# Usage:
#   source akamai/linode-env.sh
#   ./akamai/resize-node-disks.sh all              # every node from $NODES
#   ./akamai/resize-node-disks.sh devstats-test-db-01
set -euo pipefail

TARGET="${1:-all}"
# Arrays (NODES) cannot cross process boundaries - always self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AKAMAI_DIR}/linode-env.sh"
command -v linode-cli >/dev/null || { echo "linode-cli not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

wait_status () { # id, wanted
  local id="$1" wanted="$2" s
  while true; do
    s="$(linode-cli linodes view "${id}" --json | jq -r '.[0].status')"
    [ "${s}" = "${wanted}" ] && break
    echo "    ${id}: ${s} (waiting for ${wanted})"; sleep 10
  done
}

wait_disks_ready () { # id
  local id="$1"
  while linode-cli linodes disks-list "${id}" --json | jq -e '.[] | select(.status!="ready")' >/dev/null 2>&1; do
    echo "    disks busy..."; sleep 10
  done
}

wait_disk_ready () { # id disk_id - a freshly created disk is NOT instantly visible in
  # disks-list, so waiting for "all listed disks ready" races; wait for THIS disk instead
  local id="$1" disk_id="$2"
  while [ "$(linode-cli linodes disks-list "${id}" --json | jq -r --arg d "${disk_id}" '.[] | select((.id|tostring)==$d) | .status')" != "ready" ]; do
    echo "    disk ${disk_id} not ready yet..."; sleep 10
  done
}

fix_node () {
  local name="$1"
  local id total root_id root_size swap_id data_id cfg_id
  id="$(linode-cli linodes list --json | jq -r --arg l "${name}" '.[] | select(.label==$l) | .id' | head -1)"
  [ -n "${id}" ] || { echo "  ${name}: not found - skipping"; return 0; }
  total="$(linode-cli linodes view "${id}" --json | jq -r '.[0].specs.disk')"   # MiB-ish (MB) plan allocation
  echo "== ${name} (id ${id}, plan disk ${total} MB) =="

  if linode-cli linodes disks-list "${id}" --json | jq -e '.[] | select(.label=="data")' >/dev/null; then
    echo "  data disk already exists - skipping"; return 0
  fi

  echo "  shutting down..."
  linode-cli linodes shutdown "${id}" >/dev/null || true
  wait_status "${id}" offline

  root_id="$(linode-cli linodes disks-list "${id}" --json | jq -r '[.[] | select(.filesystem=="ext4" or .filesystem=="ext3")][0].id')"
  root_size="$(linode-cli linodes disks-list "${id}" --json | jq -r '[.[] | select(.filesystem=="ext4" or .filesystem=="ext3")][0].size')"
  swap_id="$(linode-cli linodes disks-list "${id}" --json | jq -r '.[] | select(.filesystem=="swap") | .id' | head -1)"

  if [ -n "${swap_id}" ] && [ "${swap_id}" != "null" ]; then
    echo "  deleting swap disk ${swap_id}..."
    linode-cli linodes disk-delete "${id}" "${swap_id}" >/dev/null
    wait_disks_ready "${id}"
  fi

  if [ "${root_size}" -gt "${ROOT_DISK_MB}" ]; then
    echo "  resizing root disk ${root_id}: ${root_size} -> ${ROOT_DISK_MB} MB..."
    linode-cli linodes disk-resize "${id}" "${root_id}" --size "${ROOT_DISK_MB}" >/dev/null
    wait_disks_ready "${id}"
  fi

  local data_size=$(( total - ROOT_DISK_MB ))
  echo "  creating raw data disk (${data_size} MB)..."
  data_id="$(linode-cli linodes disk-create "${id}" --label data --filesystem raw --size "${data_size}" --json | jq -r '.[0].id')"
  wait_disk_ready "${id}" "${data_id}"

  cfg_id="$(linode-cli linodes configs-list "${id}" --json | jq -r '.[0].id')"
  echo "  attaching data disk ${data_id} as sdc in config ${cfg_id} (sda passed too - config-update REPLACES the devices map)..."
  linode-cli linodes config-update "${id}" "${cfg_id}" \
    --devices.sda.disk_id "${root_id}" --devices.sdc.disk_id "${data_id}" >/dev/null

  echo "  booting..."
  linode-cli linodes boot "${id}" >/dev/null
  wait_status "${id}" running
  echo "  ${name} done (root ${ROOT_DISK_MB} MB + data ${data_size} MB as /dev/sdc)"
}

if [ "${TARGET}" = "all" ]; then
  for entry in "${NODES[@]}"; do
    read -r name _ _ _ <<<"${entry}"
    fix_node "${name}"
  done
else
  fix_node "${TARGET}"
fi

echo
echo "Next: run node-setup.sh on every node (mounts /dev/sdc at /data and installs k8s prereqs)."
