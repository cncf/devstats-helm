#!/bin/bash
# Single source of truth for the DevStats OCI -> Akamai Linode migration.
# Usage: source akamai/linode-env.sh
# See: devstats-linodes-migration.md
# Requires: linode-cli (pip install linode-cli), jq. Run `linode-cli configure` first.

# --- Region (MUST be confirmed by Akamai for G7 availability before creating anything) ---
export REGION="${REGION:-us-ord}"

# --- Image: Ubuntu 26.04 LTS is mandatory (custom image upload if absent in catalog) ---
# Discover with: linode-cli images list --json | jq -r '.[].id' | grep -i ubuntu
export IMAGE="${IMAGE:-linode/ubuntu26.04}"

# --- Root password/SSH for new Linodes (password only used at creation; SSH keys preferred) ---
export ROOT_PASS="${ROOT_PASS:-}"                       # set before running create-infra.sh
export SSH_PUB_KEY_FILE="${SSH_PUB_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"

# --- VPC ---
export VPC_LABEL="devstats-vpc"
export SUBNET_LABEL="devstats-nodes"
export SUBNET_CIDR="10.60.0.0/24"

# --- Placement groups (strict anti-affinity, max 5 Linodes per group) ---
export PG_PROD_LABEL="devstats-prod-pg"
export PG_TEST_COMPUTE_LABEL="devstats-test-compute-pg"

# --- Plans (live API verified 2026-08-18, us-ord: Premium Plans + Placement Group + VPCs OK):
#   g7-dedicated-256-56  class "dedicated" 256 GB, 56 vCPU, 5,120,000 MB disk, 11 TB pooled transfer, $2,765/mo
#   g7-premium-56        class "premium"   256 GB, identical specs/price (premium tier of the same size)
#   The G7 dedicated ladder ENDS at 256 GB - there is NO public 512 GB G7 plan ("limited
#   deployment availability" per docs). Get the 512 type ID from Akamai (credits thread) and
#   pin TYPE_512, or use TOPOLOGY=8x256/7x256 below (fully orderable today), or fallback
#   g8-dedicated-512-256 (512 GB, 256 vCPU, 5,368,832 MB disk, usage-based egress $0.005/GB).
export TYPE_512="${TYPE_512:-}"                         # pin after Akamai confirms (limited availability)
export TYPE_256="${TYPE_256:-g7-dedicated-256-56}"      # confirmed in live API

# --- Topology: mixed (3x512+4x256, needs Akamai for the 512s) | 8x256 | 7x256 ------------
# 8x256 and 7x256 use ONLY g7-dedicated-256-56 (orderable today, no Akamai dependency).
# See plan section 1.4 for the full comparison.
export TOPOLOGY="${TOPOLOGY:-mixed}"

# --- Node inventory: name / VPC IP / plan-size / placement group ---
# Keep in sync with devstats-linodes-migration.md sections 1.1/1.4.
case "${TOPOLOGY}" in
  mixed)   # 3 x 512 GB (prod db) + 4 x 256 GB - the originally approved config
    export NODES=(
      "devstats-prod-db-01 10.60.0.11 512 prod"
      "devstats-prod-db-02 10.60.0.12 512 prod"
      "devstats-prod-db-03 10.60.0.13 512 prod"
      "devstats-test-db-01 10.60.0.21 256 testcompute"
      "devstats-test-db-02 10.60.0.22 256 testcompute"
      "devstats-compute-01 10.60.0.31 256 testcompute"
      "devstats-compute-02 10.60.0.32 256 testcompute"
    )
    export PROD_DB_NODE_GB=512
    ;;
  8x256)   # 8 x 256 GB: 3 prod-db + 2 test-db + 3 compute ($22,120/mo - cheaper than mixed)
    export NODES=(
      "devstats-prod-db-01 10.60.0.11 256 prod"
      "devstats-prod-db-02 10.60.0.12 256 prod"
      "devstats-prod-db-03 10.60.0.13 256 prod"
      "devstats-test-db-01 10.60.0.21 256 testcompute"
      "devstats-test-db-02 10.60.0.22 256 testcompute"
      "devstats-compute-01 10.60.0.31 256 testcompute"
      "devstats-compute-02 10.60.0.32 256 testcompute"
      "devstats-compute-03 10.60.0.33 256 testcompute"
    )
    export PROD_DB_NODE_GB=256
    ;;
  7x256)   # 7 x 256 GB: 3 prod-db + 2 test-db + 2 compute ($19,355/mo - last resort)
    export NODES=(
      "devstats-prod-db-01 10.60.0.11 256 prod"
      "devstats-prod-db-02 10.60.0.12 256 prod"
      "devstats-prod-db-03 10.60.0.13 256 prod"
      "devstats-test-db-01 10.60.0.21 256 testcompute"
      "devstats-test-db-02 10.60.0.22 256 testcompute"
      "devstats-compute-01 10.60.0.31 256 testcompute"
      "devstats-compute-02 10.60.0.32 256 testcompute"
    )
    export PROD_DB_NODE_GB=256
    ;;
  *) echo "linode-env.sh: unknown TOPOLOGY=${TOPOLOGY} (use mixed|8x256|7x256)"; return 1 2>/dev/null || exit 1 ;;
esac
export MASTER_NODE="devstats-compute-01"
export MASTER_VPC_IP="10.60.0.31"

# --- Firewall mode: open (Option A - no firewall at all) | allowlist (Option B) -----------
# See plan section 16 for the full comparison. create-firewall.sh consumes these.
export FW_MODE="${FW_MODE:-open}"
export FW_LABEL="devstats-nodes-fw"
export ADMIN_CIDRS="${ADMIN_CIDRS:-0.0.0.0/0}"   # comma-separated CIDRs allowed to SSH/kubectl in allowlist mode

# --- Disk layout (MiB): root shrunk to 150 GB, remainder -> ext4 "data" disk at /data ---
export ROOT_DISK_MB=153600

# --- Kubernetes ---
export K8S_STREAM="${K8S_STREAM:-v1.36}"   # newest stable pkgs.k8s.io stream (v1.36.3 as of 2026-08); OCI ran v1.35.0
export POD_CIDR="10.244.0.0/16"
export SVC_CIDR="10.96.0.0/12"

# --- containerd/crictl versions (bump to newest at install time) ---
export CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.3.4}"
export CRICTL_VERSION="${CRICTL_VERSION:-v1.36.0}"

# --- Ingress NodePorts (identical to OCI) ---
export PROD_HTTP_NODEPORT=30080
export PROD_HTTPS_NODEPORT=30443
export TEST_HTTP_NODEPORT=31080
export TEST_HTTPS_NODEPORT=31443

# --- NodeBalancers ---
export PROD_NB_LABEL="devstats-prod-nb"
export TEST_NB_LABEL="devstats-test-nb"
# Backends = nodes labeled ingress=prod / ingress=test (externalTrafficPolicy=Local!)
export PROD_INGRESS_BACKENDS=("10.60.0.31" "10.60.0.12" "10.60.0.13")
export TEST_INGRESS_BACKENDS=("10.60.0.32" "10.60.0.21" "10.60.0.22")
# Fill after create-nodebalancers.sh prints them:
export PROD_NB_IP="${PROD_NB_IP:-}"
export TEST_NB_IP="${TEST_NB_IP:-}"

# --- Patroni sizing (see devstats-linodes-migration.md section 14; topology-aware) ---
export PROD_POSTGRES_NODES=3
if [ "${PROD_DB_NODE_GB}" = "512" ]; then
  export PROD_POSTGRES_STORAGE="6000Gi"
  export PROD_PG_REQ_CPU="24000m";  export PROD_PG_LIM_CPU="56000m"
  export PROD_PG_REQ_MEM="96Gi";    export PROD_PG_LIM_MEM="400Gi"
else  # prod Patroni on 256 GB nodes (TOPOLOGY=8x256|7x256): 5,000 GiB disk, /data ~4,850 GiB -> PVC 4500Gi
  export PROD_POSTGRES_STORAGE="4500Gi"
  export PROD_PG_REQ_CPU="16000m";  export PROD_PG_LIM_CPU="48000m"
  export PROD_PG_REQ_MEM="64Gi";    export PROD_PG_LIM_MEM="180Gi"
fi

export TEST_POSTGRES_NODES=2
export TEST_POSTGRES_STORAGE="3600Gi"
export TEST_PG_REQ_CPU="8000m";   export TEST_PG_LIM_CPU="40000m"
export TEST_PG_REQ_MEM="48Gi";    export TEST_PG_LIM_MEM="160Gi"

# --- Old OCI public endpoints (for restores and rollback) ---
export OCI_PROD_NLB_IP="132.226.49.222"
export OCI_TEST_NLB_IP="152.70.192.23"
export RESTORE_FROM_PROD="https://devstats.cncf.io/backups/"
export RESTORE_FROM_TEST="https://teststats.cncf.io/backups/"
