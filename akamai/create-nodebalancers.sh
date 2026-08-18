#!/bin/bash
# Creates the two Akamai NodeBalancers replacing OCI NLBs (oci/nlb-setup.sh, oci/oci-create-nlbs.sh):
#   devstats-prod-nb: TCP 80 -> 30080, TCP 443 -> 30443, backends = ingress=prod nodes
#   devstats-test-nb: TCP 80 -> 31080, TCP 443 -> 31443, backends = ingress=test nodes
# TCP pass-through only - TLS terminates in ingress-nginx/cert-manager, exactly as on OCI.
#
# NOTE on backends: this script attaches backends over the VPC (subnet selected at NB creation).
# If your linode-cli/region does not support VPC-attached NodeBalancers yet, create the two NBs in
# Cloud Manager (Region -> same VPC/subnet -> TCP configs as below) and re-run this script only for
# backend attachment, or add backends in the UI. Health check: TCP connect on the backend port.
# CLASSIC (non-VPC) NB fallback caveat: classic backends need Linode PRIVATE IPv4s - nodes are
# created with --private_ip false, so first `linode-cli linodes ip-add <id> --type ipv4
# --public false` + reboot each backend node, then use 192.168.x.y:<NodePort> backends (plan 7.2).
#
# Usage: source akamai/linode-env.sh && ./akamai/create-nodebalancers.sh
set -euo pipefail

# Arrays (backend lists) cannot cross process boundaries - always self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AKAMAI_DIR}/linode-env.sh"
command -v linode-cli >/dev/null || { echo "linode-cli not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

VPC_ID="$(linode-cli vpcs list --json | jq -r --arg l "${VPC_LABEL}" '.[] | select(.label==$l) | .id' | head -1)"
SUBNET_ID="$(linode-cli vpcs subnets-list "${VPC_ID}" --json | jq -r --arg l "${SUBNET_LABEL}" '.[] | select(.label==$l) | .id' | head -1)"
[ -n "${SUBNET_ID}" ] || { echo "VPC/subnet not found - run create-infra.sh first"; exit 1; }

create_nb () { # label
  local label="$1" id
  id="$(linode-cli nodebalancers list --json | jq -r --arg l "${label}" '.[] | select(.label==$l) | .id' | head -1)"
  if [ -z "${id}" ]; then
    echo "Creating NodeBalancer ${label}..." >&2
    # --vpcs: attach to our VPC at creation (GA 2026; vpc_id AND subnet_id required, a /30
    # ipv4_range is auto-assigned; the NB's VPC CANNOT be changed after creation).
    id="$(linode-cli nodebalancers create --label "${label}" --region "${REGION}" \
            --vpcs '[{"vpc_id":'"${VPC_ID}"',"subnet_id":'"${SUBNET_ID}"'}]' --json 2>/dev/null | jq -r '.[0].id')" || true
    if [ -z "${id}" ] || [ "${id}" = "null" ]; then
      echo "  VPC-attached creation failed; creating classic NB (use private IPs or UI for backends)..." >&2
      id="$(linode-cli nodebalancers create --label "${label}" --region "${REGION}" --json | jq -r '.[0].id')"
    fi
  fi
  echo "${id}"
}

create_cfg () { # nb_id, port
  local nb_id="$1" port="$2" cfg_id
  cfg_id="$(linode-cli nodebalancers configs-list "${nb_id}" --json | jq -r --argjson p "${port}" '.[] | select(.port==$p) | .id' | head -1)"
  if [ -z "${cfg_id}" ]; then
    cfg_id="$(linode-cli nodebalancers config-create "${nb_id}" \
      --port "${port}" --protocol tcp --algorithm roundrobin \
      --check connection --check_interval 10 --check_timeout 5 --check_attempts 3 \
      --json | jq -r '.[0].id')"
  fi
  echo "${cfg_id}"
}

add_backends () { # nb_id, cfg_id, node_port, backends...
  local nb_id="$1" cfg_id="$2" node_port="$3"; shift 3
  local ip
  for ip in "$@"; do
    if ! linode-cli nodebalancers nodes-list "${nb_id}" "${cfg_id}" --json | jq -e --arg a "${ip}:${node_port}" '.[] | select(.address==$a)' >/dev/null 2>&1; then
      echo "  backend ${ip}:${node_port}"
      linode-cli nodebalancers node-create "${nb_id}" "${cfg_id}" \
        --address "${ip}:${node_port}" --label "n-${ip//./-}" --mode accept >/dev/null
    fi
  done
}

echo "=== PROD NodeBalancer ==="
PROD_NB_ID="$(create_nb "${PROD_NB_LABEL}")"
CFG80="$(create_cfg "${PROD_NB_ID}" 80)";  add_backends "${PROD_NB_ID}" "${CFG80}"  "${PROD_HTTP_NODEPORT}"  "${PROD_INGRESS_BACKENDS[@]}"
CFG443="$(create_cfg "${PROD_NB_ID}" 443)"; add_backends "${PROD_NB_ID}" "${CFG443}" "${PROD_HTTPS_NODEPORT}" "${PROD_INGRESS_BACKENDS[@]}"

echo "=== TEST NodeBalancer ==="
TEST_NB_ID="$(create_nb "${TEST_NB_LABEL}")"
CFG80T="$(create_cfg "${TEST_NB_ID}" 80)";  add_backends "${TEST_NB_ID}" "${CFG80T}"  "${TEST_HTTP_NODEPORT}"  "${TEST_INGRESS_BACKENDS[@]}"
CFG443T="$(create_cfg "${TEST_NB_ID}" 443)"; add_backends "${TEST_NB_ID}" "${CFG443T}" "${TEST_HTTPS_NODEPORT}" "${TEST_INGRESS_BACKENDS[@]}"

PROD_NB_IP="$(linode-cli nodebalancers view "${PROD_NB_ID}" --json | jq -r '.[0].ipv4')"
TEST_NB_IP="$(linode-cli nodebalancers view "${TEST_NB_ID}" --json | jq -r '.[0].ipv4')"
echo
echo "PROD_NB_IP=${PROD_NB_IP}   (point devstats.cncf.io / devstats.cd.foundation / devstats.graphql.org here at cutover)"
echo "TEST_NB_IP=${TEST_NB_IP}   (point teststats.cncf.io here at cutover)"
echo "Record both in akamai/linode-env.sh."
echo
echo "Validate now (before DNS):"
echo "  curl -I --resolve devstats.cncf.io:80:${PROD_NB_IP} http://devstats.cncf.io/"
echo "  curl -I --resolve teststats.cncf.io:80:${TEST_NB_IP} http://teststats.cncf.io/"
