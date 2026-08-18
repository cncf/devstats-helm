#!/bin/bash
# Creates the Akamai/Linode infrastructure for DevStats:
#   VPC + subnet, 2 strict anti-affinity placement groups, 7-8 G7 Linodes (per TOPOLOGY)
#   with manual VPC IPv4 addresses and public IPv4 via 1:1 NAT.
# Replaces the OCI instance/VCN/NSG setup. Idempotent-ish: skips existing objects by label.
#
# Usage:
#   source akamai/linode-env.sh
#   ./akamai/create-infra.sh pilot    # only devstats-prod-db-01 + devstats-compute-01 (benchmark first!)
#   ./akamai/create-infra.sh rest     # the remaining nodes (5 or 6, per TOPOLOGY)
#   ./akamai/create-infra.sh all      # everything at once
set -euo pipefail

MODE="${1:-pilot}"
# Arrays (NODES) cannot cross process boundaries - always self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AKAMAI_DIR}/linode-env.sh"
command -v linode-cli >/dev/null || { echo "linode-cli not found (pip install linode-cli)"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }
[ -n "${ROOT_PASS:-}" ] || { echo "ROOT_PASS not set (export ROOT_PASS=... before running)"; exit 1; }
[ -f "${SSH_PUB_KEY_FILE}" ] || { echo "SSH public key ${SSH_PUB_KEY_FILE} not found"; exit 1; }
SSH_KEY="$(cat "${SSH_PUB_KEY_FILE}")"

# --- 0) Discover G7 plan type IDs unless pinned in linode-env.sh -------------------------
# Live API 2026-08-18: 256GB G7 = "g7-dedicated-256-56" (class "dedicated", 56 vCPU, 5000GB
# disk; "g7-premium-56" is the identically-specced premium twin - either works).
# 512GB G7 is LIMITED AVAILABILITY and absent from the public type list - pin TYPE_512 after
# Akamai confirms the ID (fallback: g8-dedicated-512-256, class "dedicated", 256 vCPU).
# Prefer g7-* ids: g8 types have price.monthly=null which jq sorts FIRST - do not sort by price.
discover_type () {
  local ram_mb="$1"
  linode-cli linodes types --json 2>/dev/null \
    | jq -r --argjson ram "${ram_mb}" \
      '[.[] | select(.class=="dedicated" or .class=="premium") | select(.memory==$ram)]
       | (map(select(.id|startswith("g7-"))) + map(select(.id|startswith("g7-")|not)))
       | .[0].id // empty'
}
if [ -z "${TYPE_512}" ]; then
  # only needed when the topology actually contains 512 GB nodes (TOPOLOGY=mixed)
  if printf '%s\n' "${NODES[@]}" | grep -q ' 512 '; then
    TYPE_512="$(discover_type 524288)"
    [ -n "${TYPE_512}" ] || { echo "cannot discover 512GB type id (limited availability - ask Akamai) - pin TYPE_512 in linode-env.sh or use TOPOLOGY=8x256/7x256"; exit 1; }
  else
    TYPE_512="unused"
  fi
fi
if [ -z "${TYPE_256}" ]; then
  TYPE_256="$(discover_type 262144)"
  [ -n "${TYPE_256}" ] || { echo "cannot discover 256GB type id - pin TYPE_256=g7-premium-56 in linode-env.sh"; exit 1; }
fi
case "${TYPE_512}" in g8-*) echo "WARNING: TYPE_512=${TYPE_512} is a G8 plan: usage-based egress, 5243GB disk (not 7200GB) - see plan section 4.1";; esac
echo "Using topology=${TOPOLOGY:-mixed} types: 512GB=${TYPE_512}, 256GB=${TYPE_256}, region=${REGION}, image=${IMAGE}"

# --- 1) VPC + subnet ---------------------------------------------------------------------
VPC_ID="$(linode-cli vpcs list --json | jq -r --arg l "${VPC_LABEL}" '.[] | select(.label==$l) | .id' | head -1)"
if [ -z "${VPC_ID}" ]; then
  echo "Creating VPC ${VPC_LABEL} (${SUBNET_CIDR})..."
  VPC_ID="$(linode-cli vpcs create --label "${VPC_LABEL}" --region "${REGION}" \
    --subnets.label "${SUBNET_LABEL}" --subnets.ipv4 "${SUBNET_CIDR}" --json | jq -r '.[0].id')"
else
  echo "VPC ${VPC_LABEL} exists (id ${VPC_ID})"
fi
SUBNET_ID="$(linode-cli vpcs subnets-list "${VPC_ID}" --json | jq -r --arg l "${SUBNET_LABEL}" '.[] | select(.label==$l) | .id' | head -1)"
[ -n "${SUBNET_ID}" ] || { echo "subnet ${SUBNET_LABEL} not found in VPC ${VPC_ID}"; exit 1; }
echo "VPC=${VPC_ID} SUBNET=${SUBNET_ID}"

# --- 2) Placement groups (strict anti-affinity, max 5 members each) -----------------------
create_pg () {
  local label="$1"
  local id
  # linode-cli command group is "placement"; list action name differs across CLI versions.
  id="$( (linode-cli placement group-list --json 2>/dev/null || linode-cli placement groups-list --json 2>/dev/null) \
        | jq -r --arg l "${label}" '.[] | select(.label==$l) | .id' | head -1 || true)"
  if [ -z "${id}" ]; then
    echo "Creating placement group ${label}..." >&2
    id="$(linode-cli placement group-create --label "${label}" --region "${REGION}" \
      --placement_group_type anti_affinity:local --placement_group_policy strict --json | jq -r '.[0].id')"
  fi
  echo "${id}"
}
PG_PROD_ID="$(create_pg "${PG_PROD_LABEL}")"
PG_TC_ID="$(create_pg "${PG_TEST_COMPUTE_LABEL}")"
echo "Placement groups: prod=${PG_PROD_ID} test-compute=${PG_TC_ID}"

# --- 3) Linodes ---------------------------------------------------------------------------
create_node () {
  local name="$1" vpc_ip="$2" size="$3" pg="$4"
  local type pg_id existing
  existing="$(linode-cli linodes list --json | jq -r --arg l "${name}" '.[] | select(.label==$l) | .id' | head -1)"
  if [ -n "${existing}" ]; then echo "  ${name} exists (id ${existing}) - skipping"; return 0; fi
  if [ "${size}" = "512" ]; then type="${TYPE_512}"; else type="${TYPE_256}"; fi
  if [ "${pg}" = "prod" ]; then pg_id="${PG_PROD_ID}"; else pg_id="${PG_TC_ID}"; fi
  echo "  Creating ${name} (${type}, VPC ip ${vpc_ip}, pg ${pg_id})..."
  # VPC interface with manual address + 1:1 NAT public IPv4 ("nat_1_1: any").
  # No Cloud Firewall at creation - Option A/B applied later via create-firewall.sh (plan section 16).
  linode-cli linodes create \
    --label "${name}" \
    --region "${REGION}" \
    --type "${type}" \
    --image "${IMAGE}" \
    --root_pass "${ROOT_PASS}" \
    --authorized_keys "${SSH_KEY}" \
    --private_ip false \
    --backups_enabled false \
    --placement_group.id "${pg_id}" \
    --interfaces '[{"purpose":"vpc","subnet_id":'"${SUBNET_ID}"',"primary":true,"ipv4":{"vpc":"'"${vpc_ip}"'","nat_1_1":"any"}}]' \
    --tags devstats --json | jq -r '.[0] | "  created id=\(.id) status=\(.status)"'
}

for entry in "${NODES[@]}"; do
  read -r name vpc_ip size pg <<<"${entry}"
  case "${MODE}" in
    pilot) [[ "${name}" == "devstats-prod-db-01" || "${name}" == "devstats-compute-01" ]] || continue ;;
    rest)  [[ "${name}" == "devstats-prod-db-01" || "${name}" == "devstats-compute-01" ]] && continue ;;
    all)   : ;;
    *) echo "usage: $0 pilot|rest|all"; exit 1 ;;
  esac
  create_node "${name}" "${vpc_ip}" "${size}" "${pg}"
done

echo
echo "Done. Next steps:"
echo "  linode-cli linodes list  # wait until running, note public IPs"
echo "  ./akamai/resize-node-disks.sh all   # BEFORE installing anything on the nodes"
if [ "${MODE}" = "pilot" ]; then
  echo "  Benchmark pilots (ping/iperf3/fio - see plan section 4), then: $0 rest"
fi
