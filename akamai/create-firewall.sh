#!/bin/bash
# Implements the firewall decision from devstats-linodes-migration.md section 16.
# Two supported modes (set FW_MODE in linode-env.sh):
#
#   FW_MODE=open       Option A - NO Cloud Firewall at all (OCI-equivalent allow-all).
#                      This script then only verifies nothing is attached.
#
#   FW_MODE=allowlist  Option B - ONE shared Cloud Firewall on all nodes:
#                        inbound default DROP, outbound default ACCEPT
#                        ACCEPT TCP+UDP 1-65535 + ICMP from the VPC subnet (10.60.0.0/24)
#                        ACCEPT TCP 22 (SSH) and TCP 6443 (kube-apiserver) from ADMIN_CIDRS
#                      Public 80/443 stay CLOSED on nodes - internet traffic enters via the
#                      NodeBalancers, whose backend traffic arrives from inside the VPC subnet
#                      (VPC-integrated NBs get a /30 in it). Requires VPC-attached NBs!
#                      Node-to-node k8s traffic (vxlan UDP 8472, kubelet, etcd) = VPC rules.
#
# Verified CLI syntax (techdocs post-firewalls / post-firewall-device, 2026-06):
#   linode-cli firewalls create --label X --rules.inbound_policy DROP --rules.outbound_policy ACCEPT --rules.inbound '[...]'
#   linode-cli firewalls device-create <fw-id> --id <linode-id> --type linode
# With legacy config-profile interfaces (what create-infra.sh makes), the firewall attaches
# to the LINODE and filters both its public and VPC interfaces.
#
# Usage: source akamai/linode-env.sh && ./akamai/create-firewall.sh
# Switching later: FW_MODE=allowlist ./akamai/create-firewall.sh   (attach)
#                  ./akamai/create-firewall.sh detach              (back to open)
set -euo pipefail

ACTION="${1:-apply}"
# Arrays (NODES) cannot cross process boundaries - always self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AKAMAI_DIR}/linode-env.sh"
command -v linode-cli >/dev/null || { echo "linode-cli not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

fw_id () {
  linode-cli firewalls list --json | jq -r --arg l "${FW_LABEL}" '.[] | select(.label==$l) | .id' | head -1
}

node_ids () {
  local entry name
  for entry in "${NODES[@]}"; do
    read -r name _ _ _ <<<"${entry}"
    linode-cli linodes list --json | jq -r --arg l "${name}" '.[] | select(.label==$l) | .id'
  done
}

if [ "${ACTION}" = "detach" ]; then
  FW="$(fw_id)"
  [ -n "${FW}" ] || { echo "no firewall ${FW_LABEL} found - already open"; exit 0; }
  for dev in $(linode-cli firewalls devices-list "${FW}" --json | jq -r '.[].id'); do
    linode-cli firewalls device-delete "${FW}" "${dev}"
  done
  echo "All devices detached from ${FW_LABEL} (${FW}). Nodes are now open (Option A)."
  echo "Optionally: linode-cli firewalls delete ${FW}"
  exit 0
fi

if [ "${FW_MODE:-open}" = "open" ]; then
  echo "FW_MODE=open (Option A): no Cloud Firewall - nothing to do."
  FW="$(fw_id)"
  if [ -n "${FW}" ]; then
    echo "WARNING: firewall ${FW_LABEL} (${FW}) exists; run '$0 detach' if any node is attached."
  fi
  exit 0
fi

# --- FW_MODE=allowlist (Option B) ---------------------------------------------------------
# ADMIN_CIDRS is comma-separated; build the JSON address list.
ADMIN_JSON="$(echo "${ADMIN_CIDRS}" | tr ',' '\n' | jq -R . | jq -sc '{ipv4: .}')"
VPC_JSON='{"ipv4": ["'"${SUBNET_CIDR}"'"]}'

INBOUND='[
  {"label":"vpc-tcp","action":"ACCEPT","protocol":"TCP","ports":"1-65535","addresses":'"${VPC_JSON}"'},
  {"label":"vpc-udp","action":"ACCEPT","protocol":"UDP","ports":"1-65535","addresses":'"${VPC_JSON}"'},
  {"label":"icmp","action":"ACCEPT","protocol":"ICMP","addresses":{"ipv4":["0.0.0.0/0"]}},
  {"label":"ssh","action":"ACCEPT","protocol":"TCP","ports":"22","addresses":'"${ADMIN_JSON}"'},
  {"label":"kube-apiserver","action":"ACCEPT","protocol":"TCP","ports":"6443","addresses":'"${ADMIN_JSON}"'}
]'
echo "${INBOUND}" | jq -e . >/dev/null || { echo "internal error: bad inbound rules JSON"; exit 1; }

FW="$(fw_id)"
if [ -z "${FW}" ]; then
  echo "Creating Cloud Firewall ${FW_LABEL} (inbound DROP + allowlist)..."
  FW="$(linode-cli firewalls create --label "${FW_LABEL}" \
        --rules.inbound_policy DROP --rules.outbound_policy ACCEPT \
        --rules.inbound "$(echo "${INBOUND}" | jq -c .)" --json | jq -r '.[0].id')"
else
  echo "Updating rules on existing ${FW_LABEL} (${FW})..."
  linode-cli firewalls rules-update "${FW}" \
    --inbound_policy DROP --outbound_policy ACCEPT \
    --inbound "$(echo "${INBOUND}" | jq -c .)" >/dev/null
fi

echo "Attaching to all nodes..."
for id in $(node_ids); do
  if linode-cli firewalls devices-list "${FW}" --json | jq -e --argjson i "${id}" '.[] | select(.entity.id==$i)' >/dev/null 2>&1; then
    echo "  linode ${id}: already attached"
  else
    linode-cli firewalls device-create "${FW}" --id "${id}" --type linode >/dev/null
    echo "  linode ${id}: attached"
  fi
done

echo
echo "Option B active. Verify from OUTSIDE an admin CIDR that only expected ports answer, and:"
echo "  ssh root@<node-public-ip> 'echo ssh ok'                    # from admin CIDR"
echo "  kubectl get nodes                                          # apiserver 6443 from admin CIDR"
echo "  curl -I http://<PROD_NB_IP>/                               # NB path unaffected"
echo "Rollback to Option A anytime: $0 detach"
