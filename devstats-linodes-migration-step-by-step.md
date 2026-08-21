# DevStats OCI → Akamai Linode migration - step-by-step ACTION list

Companion to `devstats-linodes-migration.md` (all rationale/decisions live there).
This file is **actions only**: work top to bottom, run every command inline as written.
Assumptions (already decided): **TOPOLOGY = 8×256** (8 × `g7-dedicated-256-56`), **no firewall**
(FW open), Kubernetes **1.36.3 or the newest 1.36.x available on install day**, ingress-nginx
**final release** (chart 4.15.1 / controller v1.15.1 - project retired upstream), all other
version pins = the FROZEN baseline from `devstats-linodes-migration.md` §15.

Conventions used below:

- **[workstation]** - your current admin workstation: has this repo checked out (with all
  gitignored `*.secret` files), `ssh`, and the EXISTING kubectl contexts `prod`/`test` that
  point at the **old OCI cluster**. All `linode-cli` work happens here.
- **[master]** - `devstats-compute-01` on Linode (`ssh root@$MASTER_IP`), the new cluster's
  admin box: repo cloned at `/root/devstats-helm`, kubectl contexts `prod`/`test`/`shared`
  point at the **new Linode cluster**. All Linode `kubectl`/`helm` work happens here.
- **[OCI]** - the workstation again, but explicitly using the OLD OCI contexts.
- **State/resume**: every value is exported AND persisted into `./linodes.env.secret`
  (`*.secret` is gitignored). If you stop at any point, resume with:
  `cd <this repo> && source linodes.env.secret` (on master: `cd /root/devstats-helm && source linodes.env.secret`).
  The helper `sv NAME VALUE` = "export now + append `export NAME='VALUE'` to the file".
  After adding values on the workstation, re-sync the file to the master:
  `scp linodes.env.secret root@$MASTER_IP:/root/devstats-helm/`.
- Mon/Fri operating calendar (main plan §13.2): Part 1 on a Friday (platform, no state),
  Parts 2-3 on the following Monday (backups + restores; Jobs run unattended Tue-Thu),
  Part 4 (cutover) the next Friday - go/no-go 13:00, DNS flipped by 15:00 Europe/Warsaw.
  Part 5 (OCI teardown) only the Monday after a clean 72 h soak. Never cut DNS on a Monday.

---

## Part 0 - workstation prep (do this any day before; DNS TTL needs ~1 day)

### 0.1 How to "reserve" the 8×256 Linodes - the direct answer

There is **no reservation mechanism** on Linode - **creating the instances IS the
reservation** (billing starts immediately, which is fine: CNCF credits). You do **not** need
the Cloud Manager UI for any instance work and you do **not** need an Akamai
ticket: `g7-dedicated-256-56` (256 GB / 56 vCPU / 5,000 GB disk) is publicly orderable via
API/CLI today, unlike the 512 GB G7 plans (limited availability). The **only** thing done in
the UI is creating the API token (step 0.3). Everything else below is `linode-cli`.
So: the moment Part 1.3 finishes, your 8 machines are reserved and running. To hold the
capacity as early as possible, you may run Parts 0.2-0.5 + 1.1-1.4 days before the install
Friday and let the nodes idle - creation is the only step that competes for region capacity.

### 0.2 Install linode-cli + jq [workstation]

```bash
pip3 install --user --upgrade linode-cli
# make sure ~/.local/bin is on PATH:
export PATH="$HOME/.local/bin:$PATH"
linode-cli --version
sudo apt-get install -y jq curl   # (or the FreeBSD/pkg equivalents on this box)
```

### 0.3 API token + configure [workstation + one-time UI]

1. Log in at `https://cloud.linode.com` (the DevStats/CNCF Linode account).
2. Profile (top right) → **API Tokens** → **Create A Personal Access Token**:
   label `devstats-migration`, expiry per taste, scopes **Read/Write** for at least:
   Linodes, VPCs, NodeBalancers, Placement Groups, IPs, Firewalls, Images, Events.
3. Copy the token (shown once) and configure the CLI:

```bash
linode-cli configure
# paste the token when asked; set default region: us-ord; defaults for type/image: skip (Enter)
linode-cli regions list | grep us-ord          # sanity: region exists + capabilities
linode-cli linodes types --json | jq -r '.[] | select(.id=="g7-dedicated-256-56") | "\(.id) mem=\(.memory) disk=\(.disk) vcpus=\(.vcpus) $\(.price.monthly)/mo"'
```

Expected: `g7-dedicated-256-56 mem=262144 disk=5120000 vcpus=56 $2765/mo`.

### 0.4 Create `linodes.env.secret` [workstation, repo root]

This single file holds ALL migration state + helper functions. Create it once:

```bash
cd <this repo root>
cat > linodes.env.secret <<'ENVEOF'
# DevStats OCI -> Linode migration state. `source linodes.env.secret` to resume ANY time.
# Values appended later override earlier ones (last export wins). chmod 600. NEVER commit.
export LINODES_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/linodes.env.secret"
# sv NAME VALUE: export now AND persist here for future sessions (no single quotes in VALUE)
sv () { export "$1"="$2"; echo "export $1='$2'" >> "${LINODES_ENV_FILE}"; }

# --- static config: region/image/plan (TOPOLOGY=8x256, FW open) ---
export REGION='us-ord'
export IMAGE='linode/ubuntu26.04'
export TYPE_256='g7-dedicated-256-56'
export VPC_LABEL='devstats-vpc'
export SUBNET_LABEL='devstats-nodes'
export SUBNET_CIDR='10.60.0.0/24'
export PG_PROD_LABEL='devstats-prod-pg'
export PG_TC_LABEL='devstats-test-compute-pg'
export SSH_PUB_KEY_FILE="$HOME/.ssh/id_ed25519.pub"
export ROOT_DISK_MB=122880          # root 120 GB (ext4); rest -> raw disk, btrfs+zstd at /data

# --- node inventory: name:vpc-ip:placement-group (prod group=3, test/compute group=5, max 5/group) ---
NODE_INVENTORY='devstats-prod-db-01:10.60.0.11:prod devstats-prod-db-02:10.60.0.12:prod'
NODE_INVENTORY+=' devstats-prod-db-03:10.60.0.13:prod devstats-test-db-01:10.60.0.21:tc'
NODE_INVENTORY+=' devstats-test-db-02:10.60.0.22:tc devstats-compute-01:10.60.0.31:tc'
NODE_INVENTORY+=' devstats-compute-02:10.60.0.32:tc devstats-compute-03:10.60.0.33:tc'
export NODE_INVENTORY
export MASTER_VPC_IP='10.60.0.31'

# --- FROZEN version baseline (main plan section 15 - do NOT bump on install day) ---
export K8S_STREAM='v1.36'           # pkgs.k8s.io apt stream; K8S_PATCH pinned in step 1.6
export POD_CIDR='10.244.0.0/16'
export FLANNEL_VERSION='v0.28.9'
export CONTAINERD_VERSION='2.3.4'
export CRICTL_VERSION='v1.36.0'
export HELM_VERSION='v4.2.4'
export OPENEBS_VERSION='4.5.1'
export CERT_MANAGER_VERSION='v1.21.1'
export INGRESS_NGINX_CHART_VERSION='4.15.1'
export INGRESS_NGINX_CONTROLLER_VERSION='v1.15.1'
export INGRESS_NGINX_CONTROLLER_DIGEST='sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1'
export INGRESS_NGINX_WEBHOOK_VERSION='v1.6.9'
export INGRESS_NGINX_WEBHOOK_DIGEST='sha256:01038e7de14b78d702d2849c3aad72fd25903c4765af63cf16aa3398f5d5f2dd'
export PROD_INGRESS_CONTROLLER_VALUE='devstats.cncf.io/ingress-nginx-prod'
export TEST_INGRESS_CONTROLLER_VALUE='devstats.cncf.io/ingress-nginx-test'

# --- ingress NodePorts (identical to OCI) + NB backends (VPC IPs of the labeled nodes) ---
export PROD_HTTP_NODEPORT=30080
export PROD_HTTPS_NODEPORT=30443
export TEST_HTTP_NODEPORT=31080
export TEST_HTTPS_NODEPORT=31443
export PROD_INGRESS_BACKEND_VPC_IPS='10.60.0.31 10.60.0.12 10.60.0.13'
export TEST_INGRESS_BACKEND_VPC_IPS='10.60.0.32 10.60.0.21 10.60.0.22'

# --- Patroni sizing for 8x256 (main plan section 14, PROD_DB_NODE_GB=256) ---
export PROD_POSTGRES_NODES=3
export PROD_POSTGRES_STORAGE='4500Gi'
export PROD_PG_REQ_CPU='16000m';  export PROD_PG_LIM_CPU='48000m'
export PROD_PG_REQ_MEM='64Gi';    export PROD_PG_LIM_MEM='180Gi'
export TEST_POSTGRES_NODES=2
export TEST_POSTGRES_STORAGE='3600Gi'
export TEST_PG_REQ_CPU='8000m';   export TEST_PG_LIM_CPU='40000m'
export TEST_PG_REQ_MEM='48Gi';    export TEST_PG_LIM_MEM='160Gi'

# --- old OCI public endpoints (rollback + restore sources) ---
export OCI_PROD_NLB_IP='132.226.49.222'
export OCI_TEST_NLB_IP='152.70.192.23'

# --- the 12 test-env projects (helm --set escaped-comma form) ---
export TEST_PROJECTS='+azf\,+cii\,+cncf\,+fn\,+godotengine\,+linux\,+opencontainers\,+openfaas\,+openwhisk\,+riff\,+sam\,+zephyr'

# skips_except <ComponentsToKeep...>: emits skipX=1 for every chart component NOT listed
skips_except () {
  local all="Secrets PVs BackupsPV Vacuum Backups Bootstrap Provisions Crons Affiliations Grafanas Services Postgres Ingress Static API Namespaces"
  local out="" s k keep
  for s in ${all}; do
    keep=0
    for k in "$@"; do [ "${s}" = "${k}" ] && keep=1; done
    [ "${keep}" = "0" ] && out="${out},skip${s}=1"
  done
  echo "${out#,}"
}

# restore_prod <proj> <indexFrom> <indexTo>: restores one PROD project from the OCI backups
# page (kubectl context MUST be `prod` on the master). Installs release devstats-prod-<proj>
# (provision pod running devstats-helm/restore.sh + the project crons/grafanas/services).
restore_prod () {
  local s='namespace=devstats-prod,skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1'
  s+=',skipBootstrap=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1'
  s+=",indexPVsFrom=$2,indexPVsTo=$3,indexProvisionsFrom=$2,indexProvisionsTo=$3"
  s+=",indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3"
  s+=",indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=$2,indexAffiliationsTo=$3"
  s+=',provisionImage=lukaszgryglicki/devstats-prod,provisionCommand=devstats-helm/restore.sh'
  s+=',restoreFrom=https://devstats.cncf.io/backups/,testServer=,prodServer=1'
  helm install "devstats-prod-${1}" ./devstats-helm --set "${s}" \
    && echo "watch: kubectl -n devstats-prod logs -f devstats-provision-${1}"
}

# restore_test <proj> <indexFrom> <indexTo>: same for TEST (context `test`; teststats source)
restore_test () {
  local s='skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1'
  s+=',skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skikAddAll=1'
  s+=",indexPVsFrom=$2,indexPVsTo=$3,indexProvisionsFrom=$2,indexProvisionsTo=$3"
  s+=",indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3"
  s+=",indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=$2,indexAffiliationsTo=$3"
  s+=',provisionCommand=devstats-helm/restore.sh,restoreFrom=https://teststats.cncf.io/backups/'
  s+=",projectsOverride=+${1}"
  helm install "devstats-test-${1}" ./devstats-helm --set "${s}" \
    && echo "watch: kubectl -n devstats-test logs -f devstats-provision-${1}"
}

# wait_provisions [N]: block while N or more provision pods are still running (default 6)
wait_provisions () {
  local cap="${1:-6}"
  while [ "$(kubectl get po --no-headers 2>/dev/null | grep -c 'devstats-provision')" -ge "${cap}" ]; do
    echo "$(date '+%H:%M') - >=${cap} provision pods running, waiting..."; sleep 60
  done
}
ENVEOF
chmod 600 linodes.env.secret
source linodes.env.secret
```

### 0.5 Root password + SSH key [workstation]

```bash
source linodes.env.secret
sv ROOT_PASS "$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"   # or set your own
ls -l "$SSH_PUB_KEY_FILE"    # must exist - this key gets injected into every Linode
```

### 0.6 Lower DNS TTLs to 300 s NOW [DNS provider]

At the DNS provider(s) currently serving them (see `DNS-switchover.secret` in this repo for
how the previous switchover was executed), set TTL=300 for:
`devstats.cncf.io`, `teststats.cncf.io`, `devstats.cd.foundation`, `devstats.graphql.org`
and every per-project host/wildcard under those zones. Needs ~1 day to propagate - first task.

### 0.7 Secrets sanity [workstation]

```bash
# 12 single-line files, no trailing newline (prints one long line):
cat devstats-helm/secrets/*.secret; echo
ls devstats-helm/secrets/GF_SECURITY_ADMIN_PASSWORD.secret devstats-helm/secrets/GF_SECURITY_ADMIN_USER.secret \
   devstats-helm/secrets/GHA2DB_GITHUB_OAUTH.secret devstats-helm/secrets/PG_ADMIN_USER.secret \
   devstats-helm/secrets/PG_HOST.secret devstats-helm/secrets/PG_HOST_RO.secret devstats-helm/secrets/PG_PASS.secret \
   devstats-helm/secrets/PG_PASS_REP.secret devstats-helm/secrets/PG_PASS_RO.secret devstats-helm/secrets/PG_PASS_TEAM.secret \
   devstats-helm/secrets/PG_PORT.secret devstats-helm/secrets/PG_USER_RO.secret cert/cert-issuer.yaml.secret
```

### 0.8 OCI pre-flight audit [OCI]

```bash
kubectl config use-context prod
# every live Ingress must use class nginx-prod/nginx-test; snippet count must be 0
kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.ingressClassName}{"\n"}{end}'
kubectl get ingress -A -o yaml | grep -c snippet    # must print 0
# DB size go/no-go (prod <= 5.5 TiB, test <= 3.2 TiB; last measured: 1769 GB / 170 GB - PASS)
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- psql -U devstats_team -d postgres -c \
  "select sum(pg_database_size(datname))/1024^4 as tib from pg_database where not datistemplate;"
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- psql -U devstats_team -d postgres -c \
  "select sum(pg_database_size(datname))/1024^4 as tib from pg_database where not datistemplate;"
```

---

## Part 1 - FULL Linode platform, no DevStats yet (Friday; ~6-8 h)

Goal: 8 running nodes, k8s 1.36.x, storage, both ingress controllers + NodeBalancers,
cert-manager, and BOTH empty Patroni clusters tuned + failover-tested. No project data.

### 1.1 VPC + subnet [workstation]

```bash
source linodes.env.secret
sv VPC_ID "$(linode-cli vpcs create --label "$VPC_LABEL" --region "$REGION" \
  --subnets.label "$SUBNET_LABEL" --subnets.ipv4 "$SUBNET_CIDR" --json | jq -r '.[0].id')"
sv SUBNET_ID "$(linode-cli vpcs subnets-list "$VPC_ID" --json | jq -r --arg l "$SUBNET_LABEL" '.[] | select(.label==$l) | .id')"
echo "VPC=$VPC_ID SUBNET=$SUBNET_ID"
```

### 1.2 Placement groups (strict anti-affinity; max 5 members each) [workstation]

```bash
sv PG_PROD_ID "$(linode-cli placement group-create --label "$PG_PROD_LABEL" --region "$REGION" \
  --placement_group_type anti_affinity:local --placement_group_policy strict --json | jq -r '.[0].id')"
sv PG_TC_ID "$(linode-cli placement group-create --label "$PG_TC_LABEL" --region "$REGION" \
  --placement_group_type anti_affinity:local --placement_group_policy strict --json | jq -r '.[0].id')"
echo "PG prod=$PG_PROD_ID test/compute=$PG_TC_ID"
```

(If `placement group-create` errors on your CLI version, try `linode-cli placement --help`
for the exact action names - older CLIs used `groups-create`/`groups-list`.)

### 1.3 CREATE ALL 8 LINODES - this is the reservation [workstation]

```bash
for e in $NODE_INVENTORY; do
  name="${e%%:*}"; rest="${e#*:}"; vpc_ip="${rest%%:*}"; pg="${rest##*:}"
  [ "$pg" = "prod" ] && pgid="$PG_PROD_ID" || pgid="$PG_TC_ID"
  echo "creating $name ($vpc_ip, pg $pgid)..."
  linode-cli linodes create \
    --label "$name" --region "$REGION" --type "$TYPE_256" --image "$IMAGE" \
    --root_pass "$ROOT_PASS" --authorized_keys "$(cat "$SSH_PUB_KEY_FILE")" \
    --private_ip false --backups_enabled false \
    --placement_group.id "$pgid" \
    --interfaces '[{"purpose":"vpc","subnet_id":'"$SUBNET_ID"',"primary":true,"ipv4":{"vpc":"'"$vpc_ip"'","nat_1_1":"any"}}]' \
    --tags devstats --json | jq -r '.[0] | "  id=\(.id) status=\(.status)"'
done
watch -n 10 'linode-cli linodes list'    # Ctrl-C when all 8 show "running"
```

### 1.4 Record IDs + public IPs [workstation]

```bash
while read -r label id pub; do
  v="$(echo "$label" | tr '[:lower:]-' '[:upper:]_')"
  sv "ID_${v}" "$id"
  sv "PUB_${v}" "$pub"
  echo "$label id=$id public=$pub"
done < <(linode-cli linodes list --json | jq -r '.[] | select(.tags | index("devstats")) | "\(.label) \(.id) \(.ipv4[0])"')
sv MASTER_IP "$PUB_DEVSTATS_COMPUTE_01"
sv NODE_PUB_IPS "$PUB_DEVSTATS_PROD_DB_01 $PUB_DEVSTATS_PROD_DB_02 $PUB_DEVSTATS_PROD_DB_03 $PUB_DEVSTATS_TEST_DB_01 $PUB_DEVSTATS_TEST_DB_02 $PUB_DEVSTATS_COMPUTE_01 $PUB_DEVSTATS_COMPUTE_02 $PUB_DEVSTATS_COMPUTE_03"
```

### 1.5 Disk re-layout on every node (BEFORE installing anything) [workstation]

Each node: shut down → delete swap disk → shrink root to 120 GB → create one big RAW
`data` disk from the rest (~5,000 GB) → attach as `/dev/sdc` → boot. Step 1.7 then
formats `/dev/sdc` as **btrfs with transparent zstd compression** and mounts it at `/data`.

WHY split + btrfs (vs one big root):
- ext4 (the root fs, and the only thing Linode's image/resize tooling supports for boot)
  has NO transparent compression - so "one big root" also means "no compression, ever".
- btrfs `compress-force=zstd:3` typically shrinks DevStats Postgres data (text/JSON-heavy)
  ~2x on disk for a few % CPU on these 56-core nodes - effectively doubling DB headroom.
- btrfs is also SPECIFICALLY good for this k8s+DB purpose beyond compression:
  data checksums verified on every read + a monthly scrub (bit-rot detection ext4 never
  had), DUP metadata (fs survives single-sector metadata corruption), and SUBVOLUMES -
  instant crash-consistent snapshots of the Postgres hostpath taken before risky steps
  (delta re-restore, DNS cutover) = free local rollback points (§4.3, cleaned up in §5.1).
- isolation: a runaway DB/backup can only fill `/data` (pods degrade); it can never fill
  `/` and take down SSH/apt/kubelet on the node.
- the data disk is created `raw` because Linode can't create btrfs; we mkfs it ourselves.

120 GB root is comfortably enough: it holds ONLY the OS + apt packages (~10-15 GB).
Everything space-hungry is symlinked onto `/data` in step 1.7 - container images
(`/var/lib/containerd`), kubelet volumes (`/var/lib/kubelet`), etcd (`/var/lib/etcd`),
pod/container logs, and OpenEBS hostpath data (`/var/openebs`) - so kubernetes/containerd
image pulls never fill the root filesystem.

```bash
wait_status () { while [ "$(linode-cli linodes view "$1" --json | jq -r '.[0].status')" != "$2" ]; do sleep 10; done; }
wait_disks  () { while linode-cli linodes disks-list "$1" --json | jq -e '.[] | select(.status!="ready")' >/dev/null 2>&1; do sleep 10; done; }

for e in $NODE_INVENTORY; do
  name="${e%%:*}"
  id="$(linode-cli linodes list --json | jq -r --arg l "$name" '.[] | select(.label==$l) | .id')"
  total="$(linode-cli linodes view "$id" --json | jq -r '.[0].specs.disk')"
  echo "== $name (id $id, plan disk ${total} MB) =="
  if linode-cli linodes disks-list "$id" --json | jq -e '.[] | select(.label=="data")' >/dev/null; then
    echo "  data disk already exists - skipping (re-run safe)"; continue
  fi
  linode-cli linodes shutdown "$id" >/dev/null || true; wait_status "$id" offline
  root_id="$(linode-cli linodes disks-list "$id" --json | jq -r '[.[] | select(.filesystem=="ext4")][0].id')"
  swap_id="$(linode-cli linodes disks-list "$id" --json | jq -r '.[] | select(.filesystem=="swap") | .id' | head -1)"
  [ -n "$swap_id" ] && [ "$swap_id" != "null" ] && { linode-cli linodes disk-delete "$id" "$swap_id" >/dev/null; wait_disks "$id"; }
  root_size="$(linode-cli linodes disks-list "$id" --json | jq -r --arg i "$root_id" '.[] | select((.id|tostring)==$i) | .size')"
  if [ "$root_size" -gt "$ROOT_DISK_MB" ]; then
    linode-cli linodes disk-resize "$id" "$root_id" --size "$ROOT_DISK_MB" >/dev/null; wait_disks "$id"
  fi
  data_id="$(linode-cli linodes disk-create "$id" --label data --filesystem raw --size "$(( total - ROOT_DISK_MB ))" --json | jq -r '.[0].id')"
  wait_disks "$id"
  cfg_id="$(linode-cli linodes configs-list "$id" --json | jq -r '.[0].id')"
  linode-cli linodes config-update "$id" "$cfg_id" --devices.sdc.disk_id "$data_id" >/dev/null
  linode-cli linodes boot "$id" >/dev/null; wait_status "$id" running
  echo "  done: root ${ROOT_DISK_MB} MB + raw data $(( total - ROOT_DISK_MB )) MB as /dev/sdc"
done
```

### 1.6 Pin the NEWEST 1.36.x patch + helm checksum [workstation]

```bash
sv K8S_PATCH "$(curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/Packages" \
  | awk '/^Package: kubeadm$/{p=1} p&&/^Version:/{print $2; p=0}' | sort -V | tail -1 | cut -d- -f1)"
echo "K8S_PATCH=$K8S_PATCH"      # expect 1.36.3 or a newer 1.36.x - FROZEN from now on
sv HELM_SHA256 "$(curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" | awk '{print $1}')"
echo "HELM_SHA256=$HELM_SHA256"  # expected (v4.2.4): c306b46f719b0a4da32d0f78ee21bf90ce8d602f15b22ab753f0674d1670a7f3
```

### 1.7 OS + k8s prerequisites on ALL 8 nodes [workstation → each node]

One big remote block per node (idempotent; ~5 min/node; run sequentially so failures are obvious):

```bash
for h in $NODE_PUB_IPS; do
  echo "===== preparing $h ====="
  ssh -o StrictHostKeyChecking=accept-new root@$h \
    "K8S_STREAM='$K8S_STREAM' K8S_PATCH='$K8S_PATCH' HELM_VERSION='$HELM_VERSION' HELM_SHA256='$HELM_SHA256' CONTAINERD_VERSION='$CONTAINERD_VERSION' CRICTL_VERSION='$CRICTL_VERSION' bash -s" <<'NODESETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# [1] /etc/hosts - whole VPC inventory + master alias
if ! grep -q devstats-prod-db-01 /etc/hosts; then
cat >> /etc/hosts <<'HOSTS'

# DevStats Akamai VPC inventory
10.60.0.11 devstats-prod-db-01
10.60.0.12 devstats-prod-db-02
10.60.0.13 devstats-prod-db-03
10.60.0.21 devstats-test-db-01
10.60.0.22 devstats-test-db-02
10.60.0.31 devstats-compute-01
10.60.0.32 devstats-compute-02
10.60.0.33 devstats-compute-03
10.60.0.31 devstats-master
HOSTS
fi

# [1b] hostname from VPC IP (Linode images boot as "localhost"; kubelet uses the
# hostname as the k8s node NAME - joins would collide without unique hostnames)
VPC_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep '^10\.60\.0\.' | head -1)"
NODE_NAME="$(awk -v ip="$VPC_IP" '$1==ip && $2 ~ /^devstats-(prod|test|compute)/ {print $2; exit}' /etc/hosts)"
[ -n "$NODE_NAME" ] || { echo "cannot map VPC IP '$VPC_IP' to a node name"; exit 1; }
hostnamectl set-hostname "$NODE_NAME"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $NODE_NAME/" /etc/hosts
else
  echo "127.0.1.1 $NODE_NAME" >> /etc/hosts
fi
echo "hostname -> $NODE_NAME"

# [2] base packages
chmod -x /etc/update-motd.d/* 2>/dev/null || true
apt-get update -y && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg gpg nfs-common net-tools \
  iptables-persistent jq mc btop iperf3 fio btrfs-progs btrfs-compsize

# [3] /data = btrfs + transparent zstd on the raw data disk (/dev/sdc from step 1.5)
if ! mountpoint -q /data; then
  [ -b /dev/sdc ] || { echo '/dev/sdc missing - re-run step 1.5 for this node'; exit 1; }
  mkdir -p /data
  # DUP metadata: two copies of fs metadata - survives single-sector corruption
  [ "$(blkid -s TYPE -o value /dev/sdc)" = "btrfs" ] || mkfs.btrfs -f -L data -m dup -d single /dev/sdc
  UUID="$(blkid -s UUID -o value /dev/sdc)"
  OPTS="compress-force=zstd:3,noatime,discard=async"
  OPTS+=",x-systemd.before=local-fs.target,x-systemd.requires=local-fs-pre.target"
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data btrfs $OPTS 0 0" >> /etc/fstab
  systemctl daemon-reload && mount -a
fi
findmnt -no FSTYPE,OPTIONS /data | grep -q 'btrfs.*zstd' || { echo '/data is not btrfs+zstd'; exit 1; }
# monthly scrub re-verifies every checksum on cold data too (idle io class; 1st, 04:30)
echo '30 4 1 * * root /usr/bin/btrfs scrub start -c 3 /data >/dev/null 2>&1' > /etc/cron.d/btrfs-scrub-data

# [4] SUBVOLUMES (independent snapshot/rollback units) + fat-disk symlinks
for sv in openebs containerd kubelet etcd logs; do
  [ -d "/data/$sv" ] || btrfs subvolume create "/data/$sv"
done
mkdir -p /data/logs/containers /data/logs/pods
chattr +C /data/etcd 2>/dev/null || true   # etcd: fsync-heavy+tiny -> no CoW (skips compression there only)
chown -R root:root /data && chmod 755 /data
[ -e /var/openebs ]        || ln -s /data/openebs /var/openebs
[ -e /var/lib/containerd ] || ln -s /data/containerd /var/lib/containerd
[ -e /var/lib/kubelet ]    || ln -s /data/kubelet /var/lib/kubelet
[ -e /var/lib/etcd ]       || ln -s /data/etcd /var/lib/etcd
[ -e /var/log/pods ]       || ln -s /data/logs/pods /var/log/pods
[ -e /var/log/containers ] || ln -s /data/logs/containers /var/log/containers

# [5] swap off, kernel modules, sysctls, forwarding
swapoff -a; sed -i '/\sswap\s/d' /etc/fstab
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/containerd.conf
modprobe overlay; modprobe br_netfilter
cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'SYS'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.ip_forward = 1
SYS
cat > /etc/sysctl.d/99-k8s-scale.conf <<'SYS'
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384
fs.inotify.max_user_instances=4096
fs.inotify.max_user_watches=1048576
net.netfilter.nf_conntrack_max=2621440
net.core.somaxconn=4096
SYS
sysctl --system >/dev/null
iptables -P FORWARD ACCEPT
iptables-save > /etc/iptables/rules.v4

# [6] containerd (pinned) + runc + crictl (pinned), systemd cgroups
if ! command -v containerd >/dev/null; then
  curl -fsSL -o /tmp/containerd.tgz "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
  tar -C /usr/local -xzf /tmp/containerd.tgz && rm /tmp/containerd.tgz
  curl -fsSL -o /etc/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
  systemctl daemon-reload
fi
apt-get install -y runc
mkdir -p /etc/containerd
if [ ! -f /etc/containerd/config.toml ]; then
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
fi
systemctl enable --now containerd
if ! command -v crictl >/dev/null; then
  curl -fsSL -o /tmp/crictl.tgz "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  tar -C /usr/local/bin -xzf /tmp/crictl.tgz crictl && rm /tmp/crictl.tgz
fi
printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\ntimeout: 10\ndebug: false\n' > /etc/crictl.yaml
crictl info >/dev/null

# [7] kubelet/kubeadm/kubectl pinned to EXACTLY ${K8S_PATCH}, held
mkdir -p -m 755 /etc/apt/keyrings
if [ ! -f "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg" ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/Release.key" | gpg --dearmor -o "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/ /" > "/etc/apt/sources.list.d/kubernetes-${K8S_STREAM/v/}.list"
fi
apt-get update
PKG="$(apt-cache madison kubeadm | awk -v p="${K8S_PATCH}-" 'index($3,p)==1{print $3; exit}')"
[ -n "$PKG" ] || { echo "kubernetes ${K8S_PATCH} not in the ${K8S_STREAM} apt stream:"; apt-cache madison kubeadm; exit 1; }
apt-get install -y --allow-change-held-packages kubelet="$PKG" kubeadm="$PKG" kubectl="$PKG"
apt-mark hold kubelet kubeadm kubectl
kubeadm version -o short | grep -qx "v${K8S_PATCH}" || { echo "kubeadm version mismatch"; exit 1; }

# [8] helm pinned + sha256-verified
if [ "$(helm version --template '{{.Version}}' 2>/dev/null || true)" != "${HELM_VERSION}" ]; then
  curl -fsSL -o /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  echo "${HELM_SHA256}  /tmp/helm.tgz" | sha256sum -c -
  tar -C /tmp -xzf /tmp/helm.tgz linux-amd64/helm
  install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
  rm -rf /tmp/helm.tgz /tmp/linux-amd64
fi
echo "NODE READY: $(hostname) $(kubeadm version -o short) containerd $(containerd --version | awk '{print $3}') helm $(helm version --template '{{.Version}}')"
NODESETUP
done
```

Gate: every node printed `NODE READY: devstats-... v${K8S_PATCH} ...` - the first field
MUST be that node's own `devstats-*` name, NOT `localhost` (kubelet registers under it).

### 1.8 kubeadm init + flannel + /22 pod CIDRs + 1024 pods (master FIRST, before joins) [master]

```bash
# [workstation] first, push the env file to the master:
scp linodes.env.secret root@$MASTER_IP:/root/
ssh root@$MASTER_IP
# --- on devstats-compute-01, as root ---
source /root/linodes.env.secret
kubeadm config images pull --kubernetes-version "v${K8S_PATCH}"
kubeadm init --kubernetes-version "v${K8S_PATCH}" \
  --apiserver-advertise-address=10.60.0.31 --pod-network-cidr=10.244.0.0/16
mkdir -p ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config
# pinned flannel:
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.9/kube-flannel.yml
kubectl taint nodes devstats-compute-01 node-role.kubernetes.io/control-plane:NoSchedule-
```

Now switch the cluster to /22 per-node pod CIDRs + 1024 pods/node BEFORE joining workers
(joining after this means every worker gets a /22 automatically - no reset dance):

```bash
# (a) controller-manager: add the /22 mask (static pod restarts itself)
sed -i '/- kube-controller-manager/a\    - --node-cidr-mask-size-ipv4=22' /etc/kubernetes/manifests/kube-controller-manager.yaml
sleep 30; kubectl -n kube-system get po | grep controller-manager    # wait Running

# (b) flannel: SubnetLen 22
kubectl -n kube-flannel get cm kube-flannel-cfg -o json \
  | jq '.data["net-conf.json"] |= sub("\"Network\": \"10.244.0.0/16\","; "\"Network\": \"10.244.0.0/16\",\n      \"SubnetLen\": 22,")' \
  | kubectl apply -f -
kubectl -n kube-flannel get cm kube-flannel-cfg -o jsonpath='{.data.net-conf\.json}'   # verify SubnetLen: 22

# (c) master kubelet: 1024 pods
grep -q '^maxPods:' /var/lib/kubelet/config.yaml || echo 'maxPods: 1024' >> /var/lib/kubelet/config.yaml
sed -i 's/^maxPods:.*/maxPods: 1024/' /var/lib/kubelet/config.yaml

# (d) re-register the master so it re-allocates a /22 podCIDR (cluster is empty - safe):
kubectl delete node devstats-compute-01
systemctl stop kubelet
ip link del cni0 2>/dev/null; ip link del flannel.1 2>/dev/null
systemctl restart containerd && systemctl start kubelet
sleep 20
kubectl -n kube-flannel rollout restart ds kube-flannel-ds
kubectl get node devstats-compute-01 -o custom-columns=NAME:.metadata.name,CAP:.status.capacity.pods,PODCIDR:.spec.podCIDR
# MUST show 1024 and 10.244.x.y/22 - do NOT continue until it does
kubectl taint nodes devstats-compute-01 node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
```

### 1.9 Join the other 7 nodes [workstation]

```bash
source linodes.env.secret
JOIN_CMD="$(ssh root@$MASTER_IP 'kubeadm token create --print-join-command')"
echo "$JOIN_CMD"     # must join via 10.60.0.31 (VPC IP)
for h in $NODE_PUB_IPS; do
  [ "$h" = "$MASTER_IP" ] && continue
  echo "===== joining $h ====="
  ssh root@$h "$JOIN_CMD"
  ssh root@$h "grep -q '^maxPods:' /var/lib/kubelet/config.yaml || echo 'maxPods: 1024' >> /var/lib/kubelet/config.yaml; sed -i 's/^maxPods:.*/maxPods: 1024/' /var/lib/kubelet/config.yaml; systemctl restart kubelet"
done
```

### 1.10 Cluster gate [master]

```bash
kubectl get nodes -o wide          # 8 Ready, INTERNAL-IP = 10.60.0.x on ALL nodes
kubectl get nodes -o custom-columns=NAME:.metadata.name,CAP:.status.capacity.pods,PODCIDR:.spec.podCIDR
# EVERY node: CAP=1024 and a /22 podCIDR. If any node shows a /24: kubectl delete node <n>;
# then on that node: systemctl stop kubelet; ip link del cni0; ip link del flannel.1;
# systemctl restart containerd; systemctl start kubelet  - it re-registers with a /22.
# cross-node networking smoke: two pods on two nodes must ping each other
kubectl run net-a --image=busybox --restart=Never --overrides='{"spec":{"nodeName":"devstats-compute-02"}}' -- sleep 300
kubectl run net-b --image=busybox --restart=Never --overrides='{"spec":{"nodeName":"devstats-prod-db-01"}}' -- sleep 300
sleep 20; kubectl exec net-a -- ping -c 3 "$(kubectl get po net-b -o jsonpath='{.status.podIP}')"
kubectl delete po net-a net-b
```

### 1.11 Make the master the admin box: repo + secrets + contexts [workstation → master]

```bash
# [workstation]
ssh root@$MASTER_IP 'git clone https://github.com/cncf/devstats-helm /root/devstats-helm'
scp devstats-helm/secrets/*.secret root@$MASTER_IP:/root/devstats-helm/devstats-helm/secrets/
scp cert/cert-issuer.yaml.secret   root@$MASTER_IP:/root/devstats-helm/cert/
scp linodes.env.secret             root@$MASTER_IP:/root/devstats-helm/
# [master]
ssh root@$MASTER_IP
cd /root/devstats-helm && source linodes.env.secret
kubectl config set-context prod   --cluster=kubernetes --user=kubernetes-admin --namespace=devstats-prod
kubectl config set-context test   --cluster=kubernetes --user=kubernetes-admin --namespace=devstats-test
kubectl config set-context shared --cluster=kubernetes --user=kubernetes-admin --namespace=default
kubectl config use-context shared
```

### 1.12 Node labels + namespaces [master]

Storage-placement policy (we are tight on disk): the 5 Patroni nodes store ONLY their
databases; ALL other data - git clones, backups PV, grafana/provision workdirs - goes to
the 3 compute nodes. The chart enforces this via `appNodeSelector`/`backupsNodeSelector`
(= `node: devstats-app`) on every pod that writes to `openebs-hostpath` (provisions,
hourly syncs, grafanas, bootstrap, affs-sync, backups), and hostpath PVCs bind to the
node of their first consumer - so `node=devstats-app` goes on the COMPUTE nodes ONLY:

```bash
# app/backup/git-clone label - the 3 compute nodes ONLY (NEVER the prod-db nodes;
# test-db nodes may be added later as overflow if compute disks get tight - test DBs are small):
for n in devstats-compute-01 devstats-compute-02 devstats-compute-03; do
  kubectl label node "$n" node=devstats-app --overwrite
done
for n in devstats-prod-db-01 devstats-prod-db-02 devstats-prod-db-03; do kubectl label node "$n" node2=devstats-db-prod --overwrite; done
for n in devstats-test-db-01 devstats-test-db-02; do kubectl label node "$n" node2=devstats-db-test --overwrite; done
# ingress nodes MUST match the NodeBalancer backends (externalTrafficPolicy=Local):
kubectl label node devstats-compute-01 ingress=prod --overwrite
kubectl label node devstats-prod-db-02 ingress=prod --overwrite
kubectl label node devstats-prod-db-03 ingress=prod --overwrite
kubectl label node devstats-compute-02 ingress=test --overwrite
kubectl label node devstats-test-db-01 ingress=test --overwrite
kubectl label node devstats-test-db-02 ingress=test --overwrite
kubectl create ns devstats-test; kubectl create ns devstats-prod
kubectl get nodes --show-labels
```

### 1.13 Storage: OpenEBS (hostpath) + dynamic-NFS + gate [master]

```bash
helm repo add openebs https://openebs.github.io/openebs && helm repo update
helm install openebs openebs/openebs -n openebs --create-namespace --version "$OPENEBS_VERSION" \
  --set engines.replicated.mayastor.enabled=false \
  --set engines.local.lvm.enabled=false \
  --set engines.local.zfs.enabled=false \
  --set loki.enabled=false \
  --set alloy.enabled=false \
  --set localpv-provisioner.hostpathClass.isDefaultClass=true
kubectl -n openebs get pods -w        # Ctrl-C when all Ready
kubectl get sc                        # openebs-hostpath must exist and be (default)
helm repo add openebs-dynamic-nfs https://openebs-archive.github.io/dynamic-nfs-provisioner/ && helm repo update
# nfsServerNodeAffinity pins the NFS server pods (which PHYSICALLY hold the backups-PV
# data on their hostpath) to the compute nodes - never on Patroni nodes:
helm install openebs-nfs openebs-dynamic-nfs/nfs-provisioner --namespace openebs-nfs --create-namespace \
  --set nfsStorageClass.name=nfs-openebs-localstorage --set-string nfsStorageClass.backendStorageClass=openebs-hostpath \
  --set-string 'nfsProvisioner.nfsServerNodeAffinity=node:[devstats-app]'
# gate: 1Gi PVC + pod in BOTH classes
for sc in openebs-hostpath nfs-openebs-localstorage; do
  kubectl apply -f - <<GATE
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: gate-$sc}
spec:
  storageClassName: $sc
  accessModes: [$( [ "$sc" = "openebs-hostpath" ] && echo ReadWriteOnce || echo ReadWriteMany )]
  resources: {requests: {storage: 1Gi}}
GATE
  ov='{"spec":{"containers":[{"name":"g","image":"busybox",'
  ov+='"command":["sh","-c","echo ok > /mnt/ok && cat /mnt/ok"],'
  ov+='"volumeMounts":[{"name":"v","mountPath":"/mnt"}]}],'
  ov+='"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"gate-'$sc'"}}]}}'
  kubectl run "gate-$sc" --image=busybox --restart=Never --overrides="$ov"
  sleep 25; kubectl logs "gate-$sc"   # must print: ok
  kubectl delete po "gate-$sc"; kubectl delete pvc "gate-$sc"
done
# fallback if OpenEBS 4.5.1 misbehaves: OCI-proven 3.10.0 from https://openebs.github.io/charts
```

Verify NFS server placement - the backups-PV data lives on the NFS server pod's node, so
it MUST be a compute node (NFS servers are created per-PVC, so check again after 1.19):
`kubectl -n openebs-nfs get po -o wide` → only `devstats-compute-*` in the NODE column.

### 1.14 ingress-nginx × 2 - pinned FINAL release [master]

ingress-nginx is retired upstream (2026-03-24); chart 4.15.1 / controller v1.15.1 is the last
release and was certified only up to k8s 1.35. Running it on 1.36.x is a locally-validated
exception - the gate in 1.17 MUST pass before anything stateful is installed.

```bash
cd /root/devstats-helm && source linodes.env.secret
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
# pre-install gate: resolved chart/app version must equal the pins
helm show chart ingress-nginx/ingress-nginx --version "$INGRESS_NGINX_CHART_VERSION" | grep -E '^(version|appVersion):'
# must print: version: 4.15.1 / appVersion: 1.15.1 - STOP otherwise

COMMON_SETS=(
  --version "$INGRESS_NGINX_CHART_VERSION"
  --atomic
  --set controller.image.tag="$INGRESS_NGINX_CONTROLLER_VERSION"
  --set controller.image.digest="$INGRESS_NGINX_CONTROLLER_DIGEST"
  --set controller.admissionWebhooks.patch.image.tag="$INGRESS_NGINX_WEBHOOK_VERSION"
  --set controller.admissionWebhooks.patch.image.digest="$INGRESS_NGINX_WEBHOOK_DIGEST"
  --set defaultBackend.enabled=false
  --set controller.ingressClassByName=true
  --set controller.watchIngressWithoutClass=false
  --set controller.allowSnippetAnnotations=false
  --set controller.enableAnnotationValidations=true
  --set controller.config.disable-ipv6="true"
  --set controller.config.worker-rlimit-nofile="65535"
  --set controller.startupProbe.httpGet.path=/healthz
  --set controller.startupProbe.httpGet.port=10254
  --set controller.startupProbe.failureThreshold=18
  --set controller.startupProbe.periodSeconds=5
  --set controller.livenessProbe.initialDelaySeconds=30
  --set controller.livenessProbe.periodSeconds=20
  --set controller.livenessProbe.timeoutSeconds=5
  --set controller.livenessProbe.successThreshold=1
  --set controller.livenessProbe.failureThreshold=5
  --set controller.readinessProbe.initialDelaySeconds=15
  --set controller.readinessProbe.periodSeconds=20
  --set controller.readinessProbe.timeoutSeconds=5
  --set controller.readinessProbe.successThreshold=1
  --set controller.readinessProbe.failureThreshold=5
  --set controller.service.type=NodePort
  --set controller.kind=DaemonSet
  --set controller.service.externalTrafficPolicy=Local
)

kubectl config use-context test
helm upgrade --install nginx-ingress-test ingress-nginx/ingress-nginx \
  --namespace devstats-test --create-namespace \
  --set controller.ingressClassResource.name=nginx-test \
  --set controller.ingressClassResource.controllerValue="$TEST_INGRESS_CONTROLLER_VALUE" \
  --set controller.ingressClassResource.default=false \
  --set controller.ingressClass=nginx-test \
  --set controller.electionID=nginx-test-leader \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-test \
  --set 'controller.admissionWebhooks.namespaceSelector.matchLabels.kubernetes\.io/metadata\.name=devstats-test' \
  --set controller.nodeSelector.ingress=test \
  --set controller.service.nodePorts.http=31080 \
  --set controller.service.nodePorts.https=31443 \
  "${COMMON_SETS[@]}"

kubectl config use-context prod
helm upgrade --install nginx-ingress-prod ingress-nginx/ingress-nginx \
  --namespace devstats-prod --create-namespace \
  --set controller.ingressClassResource.name=nginx-prod \
  --set controller.ingressClassResource.controllerValue="$PROD_INGRESS_CONTROLLER_VALUE" \
  --set controller.ingressClassResource.default=false \
  --set controller.ingressClass=nginx-prod \
  --set controller.electionID=nginx-prod-leader \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-prod \
  --set 'controller.admissionWebhooks.namespaceSelector.matchLabels.kubernetes\.io/metadata\.name=devstats-prod' \
  --set controller.nodeSelector.ingress=prod \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  "${COMMON_SETS[@]}"

# verify classes + images
kubectl get ingressclass nginx-test -o jsonpath='{.spec.controller}{"\n"}'   # devstats.cncf.io/ingress-nginx-test
kubectl get ingressclass nginx-prod -o jsonpath='{.spec.controller}{"\n"}'   # devstats.cncf.io/ingress-nginx-prod
kubectl -n devstats-test get po -o wide -l app.kubernetes.io/name=ingress-nginx   # 3 pods on the ingress=test nodes
kubectl -n devstats-prod get po -o wide -l app.kubernetes.io/name=ingress-nginx   # 3 pods on the ingress=prod nodes
```

### 1.15 Raise controller open-files limit (ulimit 65535 wrapper) [master]

```bash
for ns in devstats-test devstats-prod; do
  ds="$(kubectl -n "$ns" get ds -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}')"
  if kubectl -n "$ns" get ds "$ds" -o jsonpath='{.spec.template.spec.containers[0].command}' | grep -q '/bin/sh'; then
    echo "$ns/$ds already wrapped"; continue
  fi
  wrap="$(kubectl -n "$ns" get ds "$ds" -o json | jq -r '.spec.template.spec.containers[0] | "ulimit -n 65535 && exec " + (.args | join(" "))')"
  kubectl -n "$ns" patch ds "$ds" --type=json -p "$(jq -cn --arg w "$wrap" \
    '[{op:"add",path:"/spec/template/spec/containers/0/command",value:["/bin/sh","-c"]},
      {op:"replace",path:"/spec/template/spec/containers/0/args",value:[$w]}]')"
  kubectl -n "$ns" rollout status ds "$ds"
done
```

### 1.16 NodeBalancers (VPC-attached; TCP pass-through) [workstation]

```bash
source linodes.env.secret
sv PROD_NB_ID "$(linode-cli nodebalancers create --label devstats-prod-nb --region "$REGION" \
  --vpcs '[{"vpc_id":'"$VPC_ID"',"subnet_id":'"$SUBNET_ID"'}]' --json | jq -r '.[0].id')"
sv TEST_NB_ID "$(linode-cli nodebalancers create --label devstats-test-nb --region "$REGION" \
  --vpcs '[{"vpc_id":'"$VPC_ID"',"subnet_id":'"$SUBNET_ID"'}]' --json | jq -r '.[0].id')"
# NOTE: the NB's VPC binding CANNOT be changed later (delete+recreate if wrong).

mk_cfg () { linode-cli nodebalancers config-create "$1" --port "$2" --protocol tcp --algorithm roundrobin \
  --check connection --check_interval 10 --check_timeout 5 --check_attempts 3 --json | jq -r '.[0].id'; }
add_be () { local nb="$1" cfg="$2" port="$3"; shift 3
  for ip in "$@"; do linode-cli nodebalancers node-create "$nb" "$cfg" \
    --address "${ip}:${port}" --label "n-${ip//./-}" --mode accept >/dev/null && echo "  backend ${ip}:${port}"; done; }

CFG="$(mk_cfg "$PROD_NB_ID" 80)";  add_be "$PROD_NB_ID" "$CFG" "$PROD_HTTP_NODEPORT"  $PROD_INGRESS_BACKEND_VPC_IPS
CFG="$(mk_cfg "$PROD_NB_ID" 443)"; add_be "$PROD_NB_ID" "$CFG" "$PROD_HTTPS_NODEPORT" $PROD_INGRESS_BACKEND_VPC_IPS
CFG="$(mk_cfg "$TEST_NB_ID" 80)";  add_be "$TEST_NB_ID" "$CFG" "$TEST_HTTP_NODEPORT"  $TEST_INGRESS_BACKEND_VPC_IPS
CFG="$(mk_cfg "$TEST_NB_ID" 443)"; add_be "$TEST_NB_ID" "$CFG" "$TEST_HTTPS_NODEPORT" $TEST_INGRESS_BACKEND_VPC_IPS

sv PROD_NB_IP "$(linode-cli nodebalancers view "$PROD_NB_ID" --json | jq -r '.[0].ipv4')"
sv TEST_NB_IP "$(linode-cli nodebalancers view "$TEST_NB_ID" --json | jq -r '.[0].ipv4')"
echo "PROD_NB_IP=$PROD_NB_IP  TEST_NB_IP=$TEST_NB_IP"
scp linodes.env.secret root@$MASTER_IP:/root/devstats-helm/    # keep the master copy fresh
```

(If VPC-attached creation fails in your CLI version, create the two NBs in Cloud Manager -
same region, attach to `devstats-vpc`/`devstats-nodes` at creation - then only run the
`mk_cfg`/`add_be` parts against their IDs.)

### 1.17 MANDATORY qualification gate: k8s 1.36.x ↔ ingress-nginx v1.15.1 [master]

Nothing stateful may be installed until this passes. If it fails: the cluster holds no data -
investigate, or rebuild the control plane with k8s 1.35.7 (in-place downgrade is unsupported).

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl version | grep Server        # must report exactly v${K8S_PATCH}

# per env: temp Service -> the controller's own /healthz (10254), temp Ingress, curl through
# EVERY NodePort backend over HTTP and HTTPS, then prove class isolation, then clean up.
gate_env () { # ctx ns class host httpport httpsport backends...
  local ctx="$1" ns="$2" class="$3" host="$4" hp="$5" sp="$6"; shift 6
  kubectl config use-context "$ctx"
  kubectl -n "$ns" apply -f - <<SVC
apiVersion: v1
kind: Service
metadata: {name: ingress-smoke, namespace: $ns}
spec:
  selector: {app.kubernetes.io/name: ingress-nginx, app.kubernetes.io/component: controller}
  ports: [{port: 80, targetPort: 10254}]
SVC
  kubectl -n "$ns" create ingress ingress-smoke --class="$class" --rule="${host}/*=ingress-smoke:80" \
    || { echo "ADMISSION WEBHOOK FAILED in $ns - GATE FAILED"; return 1; }
  sleep 15
  local ip rc
  for ip in "$@"; do
    rc="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://${ip}:${hp}/healthz")"
    echo "HTTP  ${ip}:${hp} -> ${rc}";  [ "$rc" = "200" ] || { echo GATE FAILED; return 1; }
    rc="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${host}" "https://${ip}:${sp}/healthz")"
    echo "HTTPS ${ip}:${sp} -> ${rc}"; [ "$rc" = "200" ] || { echo GATE FAILED; return 1; }
  done
}
gate_env test devstats-test nginx-test smoke.test.local 31080 31443 $TEST_INGRESS_BACKEND_VPC_IPS
gate_env prod devstats-prod nginx-prod smoke.prod.local 30080 30443 $PROD_INGRESS_BACKEND_VPC_IPS

# class isolation: the OTHER env's host must NOT be served (expect 404, never 200)
curl -s -o /dev/null -w 'isolation prod-host-via-test: %{http_code}\n' -H 'Host: smoke.prod.local' http://10.60.0.32:31080/healthz
curl -s -o /dev/null -w 'isolation test-host-via-prod: %{http_code}\n' -H 'Host: smoke.test.local' http://10.60.0.31:30080/healthz

# NodeBalancer path (from the workstation OR master - NBs are public):
curl -sI "http://$PROD_NB_IP/" | head -1   # any nginx answer (404) = NB->NodePort->controller OK
curl -sI "http://$TEST_NB_IP/" | head -1

# controller stability + log scan
kubectl -n devstats-test get po -l app.kubernetes.io/name=ingress-nginx   # 0 restarts
kubectl -n devstats-prod get po -l app.kubernetes.io/name=ingress-nginx
kubectl -n devstats-test logs -l app.kubernetes.io/name=ingress-nginx --tail=-1 | grep -Ei 'panic|fatal' || echo "test logs clean"
kubectl -n devstats-prod logs -l app.kubernetes.io/name=ingress-nginx --tail=-1 | grep -Ei 'panic|fatal' || echo "prod logs clean"

# cleanup
kubectl config use-context test; kubectl -n devstats-test delete ingress ingress-smoke; kubectl -n devstats-test delete svc ingress-smoke
kubectl config use-context prod; kubectl -n devstats-prod delete ingress ingress-smoke; kubectl -n devstats-prod delete svc ingress-smoke
```

### 1.18 cert-manager + issuers [master]

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" --set crds.enabled=true
kubectl -n cert-manager get po -w    # Ctrl-C when Ready
cp cert/cert-issuer.yaml.secret cert/cert-issuer.yaml
kubectl apply -f cert/cert-issuer.yaml
# certificates only get ISSUED after DNS points here (HTTP-01 on port 80) - that is expected
```

### 1.19 DevStats secrets + backups PV + project PVCs (both envs) [master]

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl config use-context test
helm install devstats-test-secrets    ./devstats-helm --set "$(skips_except Secrets)"
helm install devstats-test-backups-pv ./devstats-helm --set "$(skips_except BackupsPV)"
helm install devstats-test-pvcs       ./devstats-helm --set "$(skips_except PVs),projectsOverride=${TEST_PROJECTS}"
kubectl -n devstats-test get pvc | grep Pending   # delete any NON-test-project PVCs that appear:
# kubectl -n devstats-test delete pvc <name>

kubectl config use-context prod
helm install devstats-prod-secrets    ./devstats-helm --set "namespace=devstats-prod,$(skips_except Secrets)"
helm install devstats-prod-backups-pv ./devstats-helm --set "namespace=devstats-prod,$(skips_except BackupsPV)"
helm install devstats-prod-pvcs       ./devstats-helm --set "namespace=devstats-prod,$(skips_except PVs)"
```

Storage-placement gate - backups-PV NFS servers (one per env appeared just now) and their
backing hostpath data MUST sit on compute nodes, never on Patroni nodes:

```bash
kubectl -n openebs-nfs get po -o wide                  # NODE column: devstats-compute-* only
# hostpath PVs record their node in nodeAffinity - none may say prod-db/test-db:
kubectl get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,NODE:'.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
```

### 1.20 Patroni TEST (2 nodes, empty) + tune + restart + failover check [master]

```bash
kubectl config use-context test
S="$(skips_except Postgres),postgresNodes=${TEST_POSTGRES_NODES}"
S+=",postgresStorageSize=${TEST_POSTGRES_STORAGE},dbNodeSelector.node2=devstats-db-test"
S+=",requestsPostgresCPU=${TEST_PG_REQ_CPU},requestsPostgresMemory=${TEST_PG_REQ_MEM}"
S+=",limitsPostgresCPU=${TEST_PG_LIM_CPU},limitsPostgresMemory=${TEST_PG_LIM_MEM}"
helm install devstats-test-patroni ./devstats-helm --set "$S"
kubectl -n devstats-test get po -o wide -w | grep postgres   # Ctrl-C when 2/2 Running
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list   # 1 leader + 1 replica

# tune (PATCH persists to the k8s DCS - any member works):
PARAMS='{"loop_wait":15,"ttl":60,"retry_timeout":60,"primary_start_timeout":600,'
PARAMS+='"maximum_lag_on_failover":53687091200,'
PARAMS+='"postgresql":{"use_pg_rewind":true,"use_slots":true,"parameters":{'
PARAMS+='"shared_buffers":"48GB","max_connections":1024,"max_worker_processes":16,'
PARAMS+='"max_parallel_workers":16,"max_parallel_workers_per_gather":8,"work_mem":"1GB",'
PARAMS+='"wal_buffers":"1GB","temp_file_limit":"200GB","wal_keep_size":"100GB",'
PARAMS+='"max_wal_senders":10,"max_replication_slots":10,"maintenance_work_mem":"2GB",'
PARAMS+='"idle_in_transaction_session_timeout":"30min","wal_level":"replica",'
PARAMS+='"wal_log_hints":"on","hot_standby":"on","hot_standby_feedback":"on",'
PARAMS+='"max_wal_size":"128GB","min_wal_size":"4GB","checkpoint_completion_target":0.9,'
PARAMS+='"default_statistics_target":1000,"effective_cache_size":"128GB",'
PARAMS+='"effective_io_concurrency":8,"random_page_cost":1.1,"autovacuum_max_workers":1,'
PARAMS+='"autovacuum_naptime":"120s","autovacuum_vacuum_cost_limit":100,'
PARAMS+='"autovacuum_vacuum_threshold":150,"autovacuum_vacuum_scale_factor":0.25,'
PARAMS+='"autovacuum_analyze_threshold":100,"autovacuum_analyze_scale_factor":0.2,'
PARAMS+='"password_encryption":"scram-sha-256"}}}'
echo "$PARAMS" | jq . >/dev/null && echo "PARAMS JSON OK"
kubectl exec -n devstats-test devstats-postgres-0 -c devstats-postgres -- \
  curl -s -X PATCH -H 'Content-Type: application/json' -d "$PARAMS" http://localhost:8008/config
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl show-config
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list

# failover sanity (empty cluster - free to test):
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl switchover devstats-postgres --force
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list    # new leader, old rejoined
```

### 1.21 Patroni PROD (3 nodes, empty) + tune + restart + failover check [master]

```bash
kubectl config use-context prod
S="namespace=devstats-prod,$(skips_except Postgres),postgresNodes=${PROD_POSTGRES_NODES}"
S+=",postgresStorageSize=${PROD_POSTGRES_STORAGE},dbNodeSelector.node2=devstats-db-prod"
S+=",requestsPostgresCPU=${PROD_PG_REQ_CPU},requestsPostgresMemory=${PROD_PG_REQ_MEM}"
S+=",limitsPostgresCPU=${PROD_PG_LIM_CPU},limitsPostgresMemory=${PROD_PG_LIM_MEM}"
helm install devstats-prod-patroni ./devstats-helm --set "$S"
kubectl -n devstats-prod get po -o wide -w | grep postgres   # Ctrl-C when 3/3 Running
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list   # 1 leader + 2 replicas

# tune for 256 GB nodes (sb 64GB / ecs 128GB / wm 1GB / temp 100GB):
PARAMS='{"loop_wait":15,"ttl":60,"retry_timeout":60,"primary_start_timeout":600,'
PARAMS+='"maximum_lag_on_failover":53687091200,'
PARAMS+='"postgresql":{"use_pg_rewind":true,"use_slots":true,"parameters":{'
PARAMS+='"shared_buffers":"64GB","max_connections":1024,"max_worker_processes":32,'
PARAMS+='"max_parallel_workers":32,"max_parallel_workers_per_gather":16,"work_mem":"1GB",'
PARAMS+='"wal_buffers":"1GB","temp_file_limit":"100GB","wal_keep_size":"100GB",'
PARAMS+='"max_wal_senders":10,"max_replication_slots":10,"maintenance_work_mem":"2GB",'
PARAMS+='"idle_in_transaction_session_timeout":"30min","wal_level":"replica",'
PARAMS+='"wal_log_hints":"on","hot_standby":"on","hot_standby_feedback":"on",'
PARAMS+='"max_wal_size":"128GB","min_wal_size":"4GB","checkpoint_completion_target":0.9,'
PARAMS+='"default_statistics_target":1000,"effective_cache_size":"128GB",'
PARAMS+='"effective_io_concurrency":8,"random_page_cost":1.1,"autovacuum_max_workers":1,'
PARAMS+='"autovacuum_naptime":"120s","autovacuum_vacuum_cost_limit":100,'
PARAMS+='"autovacuum_vacuum_threshold":150,"autovacuum_vacuum_scale_factor":0.25,'
PARAMS+='"autovacuum_analyze_threshold":100,"autovacuum_analyze_scale_factor":0.2,'
PARAMS+='"password_encryption":"scram-sha-256"}}}'
echo "$PARAMS" | jq . >/dev/null && echo "PARAMS JSON OK"
kubectl exec -n devstats-prod devstats-postgres-0 -c devstats-postgres -- \
  curl -s -X PATCH -H 'Content-Type: application/json' -d "$PARAMS" http://localhost:8008/config
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl show-config
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list

# failover sanity:
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl switchover devstats-postgres --force
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list
```

**Part 1 done** - full platform is up (nodes, k8s, storage, ingress+NB, certs pending DNS,
both Patroni clusters tuned and failover-tested). No DevStats data anywhere yet.

---

## Part 2 - fresh backups on the CURRENT OCI infra (Monday morning)

### 2.1 Trigger the regular backups now [OCI]

```bash
kubectl config use-context prod
kubectl -n devstats-prod create job --from=cronjob/devstats-backups devstats-backups-manual
kubectl -n devstats-prod logs -f job/devstats-backups-manual     # hours - leave running
kubectl config use-context test
kubectl -n devstats-test create job --from=cronjob/devstats-backups devstats-backups-manual
```

### 2.2 Refresh artificial-events backups (debug pod on OCI prod) [OCI]

```bash
kubectl config use-context prod
S='namespace=devstats-prod,skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1'
S+=',skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1'
S+=',skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1'
S+=',bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s}'
S+=',bootstrapMountBackups=1,limitsBackupsCPU=4000m,limitsBackupsMemory=64Gi'
helm install devstats-prod-debug ./devstats-helm --set "$S"
kubectl -n devstats-prod exec -it debug -- bash
# inside the pod (ONLY must be EXPLICIT - the pod defaults to the TEST db list):
ONLY="$(cat ./devel/all_prod_dbs.txt)" FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh
exit
helm delete devstats-prod-debug
```

### 2.3 Verify dumps are fresh [workstation]

```bash
curl -s https://devstats.cncf.io/backups/  | grep -o 'gha.dump[^<]*'      # today's date
curl -s https://devstats.cncf.io/backups/  | grep -o 'allprj.dump[^<]*'
curl -s https://teststats.cncf.io/backups/ | grep -o 'cncf.dump[^<]*'
```

### 2.4 Snapshot OCI cronjob suspend-state (needed at cutover) [OCI]

```bash
kubectl config use-context prod
kubectl get cj -A -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) suspend=\(.spec.suspend)"' > oci-cron-suspends.secret
wc -l oci-cron-suspends.secret    # keep this file - re-apply intentional suspends after cutover
```

Do NOT suspend anything on OCI yet - it keeps syncing until Part 4.

---

## Part 3 - DevStats on Linode + restore everything (Mon → Fri; restores run unattended)

All of Part 3 runs **[master]** in `/root/devstats-helm` with `source linodes.env.secret`,
except the Grafana tar (3.3, workstation). Restores download dumps from
`https://devstats.cncf.io/backups/` / `https://teststats.cncf.io/backups/` - these still
resolve to OCI until Part 4, which is exactly what we want. ALL restores must be finished
BEFORE the DNS switch.

### 3.1 TEST env: statics, ingress, bootstrap, debug pod

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl config use-context test
helm install devstats-test-statics   ./devstats-helm --set "$(skips_except Static),projectsOverride=${TEST_PROJECTS},indexStaticsFrom=0,indexStaticsTo=1"
helm install devstats-test-ingress   ./devstats-helm --set "$(skips_except Ingress),indexDomainsFrom=0,indexDomainsTo=1,projectsOverride=${TEST_PROJECTS},ingressClass=nginx-test,sslEnv=test"
helm install devstats-test-bootstrap ./devstats-helm --set "$(skips_except Bootstrap),projectsOverride=${TEST_PROJECTS}"
kubectl get po -w    # Ctrl-C when bootstrap Completed and statics Running
helm install devstats-test-debug     ./devstats-helm --set "$(skips_except Bootstrap),bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1"
kubectl get ingress    # hosts present, class nginx-test (certs stay Pending until DNS - OK)
```

### 3.2 PROD env: statics, ingress, bootstrap, debug pod

```bash
kubectl config use-context prod
helm install devstats-prod-statics   ./devstats-helm --set "namespace=devstats-prod,$(skips_except Static),indexStaticsFrom=1"
helm install devstats-prod-ingress   ./devstats-helm --set "namespace=devstats-prod,$(skips_except Ingress),skipAliases=1,indexDomainsFrom=1,ingressClass=nginx-prod,sslEnv=prod"
helm install devstats-prod-bootstrap ./devstats-helm --set "namespace=devstats-prod,$(skips_except Bootstrap)"
kubectl get po -w    # Ctrl-C when bootstrap Completed
helm install devstats-prod-debug     ./devstats-helm --set "namespace=devstats-prod,$(skips_except Bootstrap),bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1"
```

### 3.3 Grafana artifacts tar [workstation - needs cncf/devstats + cncf/devstatscode checkouts]

```bash
cd ~/dev/go/src/github.com/cncf/devstats        # adjust to your checkout
cp ../devstatscode/sqlitedb ../devstatscode/runq ../devstatscode/replacer grafana/
tar cf /tmp/devstats-grafana.tar \
  grafana/runq grafana/sqlitedb grafana/replacer grafana/shared \
  grafana/img/*.svg grafana/img/*.png \
  grafana/*/change_title_and_icons.sh grafana/*/custom_sqlite.sql \
  grafana/dashboards/*/*.json
scp /tmp/devstats-grafana.tar root@$MASTER_IP:/root/
```

Unpack into BOTH static pods **[master]** (grafana provisioning fetches from there):

```bash
for ctx in test prod; do
  kubectl config use-context "$ctx"
  SPOD="$(kubectl get po -o name | grep devstats-static | head -1 | cut -d/ -f2)"
  kubectl cp /root/devstats-grafana.tar "$SPOD":/usr/share/nginx/html/backups/devstats-grafana.tar
  kubectl exec "$SPOD" -- sh -c 'cd /usr/share/nginx/html/backups && rm -rf grafana && tar xf devstats-grafana.tar && rm devstats-grafana.tar && chmod -R ugo+rwx grafana'
  kubectl exec "$SPOD" -- ls /usr/share/nginx/html/backups/grafana
done
```

### 3.4 Restore `affiliations` DB manually (BOTH envs; it is NOT a chart project)

```bash
# check the exact dump name first: curl -s https://devstats.cncf.io/backups/ | grep -o 'affiliations[^<]*dump'
kubectl config use-context prod
kubectl exec -it devstats-postgres-0 -c devstats-postgres -- bash -c \
  'cd /tmp && curl -fsSL -o aff.dump https://devstats.cncf.io/backups/affiliations.dump && \
   dropdb -U postgres --if-exists affiliations && createdb -U postgres affiliations && \
   pg_restore -U postgres -j 4 -d affiliations aff.dump && rm aff.dump && \
   psql -U postgres affiliations -c "\dt+" | head'
kubectl config use-context test
kubectl exec -it devstats-postgres-0 -c devstats-postgres -- bash -c \
  'cd /tmp && curl -fsSL -o aff.dump https://teststats.cncf.io/backups/affiliations.dump && \
   dropdb -U postgres --if-exists affiliations && createdb -U postgres affiliations && \
   pg_restore -U postgres -j 4 -d affiliations aff.dump && rm aff.dump'
```

### 3.5 TEST restores - the 12 live test projects (`restore_test` from linodes.env.secret)

Each call helm-installs a provision release that drops/recreates the DB, downloads the dump
from teststats.cncf.io and pg_restores it, then keeps hourly syncs running via crons.

```bash
kubectl config use-context test
restore_test cncf 49 50
restore_test opencontainers 50 51
restore_test zephyr 53 54
restore_test linux 54 55
restore_test sam 59 60
restore_test azf 60 61
restore_test riff 61 62
restore_test fn 62 63
restore_test openwhisk 63 64
restore_test openfaas 64 65
restore_test cii 67 68
restore_test godotengine 97 98
watch 'kubectl get po | grep provision'   # Ctrl-C when all Completed
kubectl delete po --field-selector=status.phase=Succeeded
```

### 3.6 TEST artificial rows + affiliations import + API + backups(suspended)

```bash
# artificial rows via the debug pod - ONLY/RESTORE_FROM MUST be explicit:
kubectl exec -it debug -- bash -c "ONLY='azf cii cncf fn godotengine linux opencontainers openfaas openwhisk riff sam zephyr' RESTORE_FROM='https://teststats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"

helm install devstats-test-affs-import ./devstats-helm --set "$(skips_except),skipAffiliationsImport=,affiliationsDB=affiliations,prodServer=,testServer=1,backupsCronProd=45 2 16\,28 * *"
helm install devstats-test-api         ./devstats-helm --set "$(skips_except API),projectsOverride=${TEST_PROJECTS}"
helm install devstats-test-backups     ./devstats-helm --set "$(skips_except Backups)"
# test backups are PERMANENTLY disabled (same as OCI today):
kubectl patch cronjob devstats-backups -p '{"spec":{"suspend":true}}'
```

### 3.7 TEST smoke (via NodeBalancer, fake Host - DNS still points to OCI)

```bash
curl -sk -H 'Host: k8s.teststats.cncf.io' "https://$TEST_NB_IP/" | grep -i grafana && echo TEST-OK
curl -s  -H 'Host: teststats.cncf.io'     "http://$TEST_NB_IP/"  | head -5
```

### 3.8 PROD restores - kick off the two LONG poles first (many hours each)

```bash
kubectl config use-context prod
restore_prod kubernetes 0 1     # biggest DB (~120 GB dump)
restore_prod all 38 39          # allprj - second biggest
```

Leave them running and start the rest immediately - `wait_provisions 8` caps parallelism
at 8 concurrent provisions (the two above included) so Patroni is never overwhelmed.

### 3.9 PROD restores - the remaining 86 projects (runs for 1-3 days unattended)

Paste as ONE block (e.g. inside `tmux` on the master so it survives disconnects):

```bash
kubectl config use-context prod
while read -r p f t; do
  wait_provisions 8
  restore_prod "$p" "$f" "$t"
  kubectl delete po --field-selector=status.phase=Succeeded 2>/dev/null
done <<'RESTORELIST'
prometheus 1 2
fluentd 3 4
linkerd 4 5
grpc 5 6
coredns 6 7
containerd 7 8
cni 9 10
envoy 10 11
jaeger 11 12
notary 12 13
tuf 13 14
rook 14 15
vitess 15 16
nats 16 17
opa 17 18
spiffe 18 19
spire 19 20
cloudevents 20 21
telepresence 21 22
helm 22 23
openmetrics 23 24
harbor 24 25
etcd 25 26
tikv 26 27
cortex 27 28
buildpacks 28 29
falco 29 30
dragonfly 30 31
virtualkubelet 31 32
kubeedge 32 33
brigade 33 34
crio 34 35
networkservicemesh 35 36
openebs 36 37
opentelemetry 37 38
tekton 39 40
spinnaker 40 41
jenkinsx 41 42
jenkins 42 43
allcdf 43 44
graphqljs 44 45
graphiql 45 46
graphqlspec 46 47
expressgraphql 47 48
graphql 48 49
thanos 55 56
flux 56 57
intoto 57 58
strimzi 58 59
kubevirt 65 66
longhorn 66 67
chubaofs 69 70
keda 70 71
smi 71 72
argo 72 73
volcano 73 74
cnigenie 74 75
keptn 75 76
kudo 76 77
cloudcustodian 77 78
dex 78 79
litmuschaos 79 80
artifacthub 80 81
kuma 81 82
parsec 82 83
bfe 83 84
crossplane 84 85
contour 85 86
operatorframework 86 87
chaosmesh 87 88
serverlessworkflow 88 89
k3s 89 90
backstage 90 91
tremor 91 92
metal3 92 93
porter 93 94
openyurt 94 95
openservicemesh 95 96
keylime 96 97
schemahero 98 99
cdk8s 99 100
certmanager 100 101
openkruise 101 102
tinkerbell 102 103
pravega 103 104
kyverno 104 105
RESTORELIST
echo 'ALL PROD RESTORES SUBMITTED'
```

Monitor (any time, e.g. next Mon/Fri):

```bash
kubectl get po | grep provision | grep -cv Completed          # still-running count
kubectl get po -o wide | grep provision | awk '{print $8}' | sort | uniq -c   # ALL on devstats-compute-* (git clones/hostpath!)
kubectl get po | grep provision | grep -Ev 'Completed|Running' # failures - MUST be empty
# retry a failed one: helm delete devstats-prod-<proj> ; restore_prod <proj> <from> <to>
# DB-level completeness vs the list above:
kubectl exec devstats-postgres-0 -c devstats-postgres -- psql -U postgres -Atc "select datname from pg_database where datname not in ('postgres','template0','template1') order by 1" | wc -l
# expect ~90: 88 project DBs (kubernetes=gha, all=allprj, ...) + affiliations + devstats;
# compare the name list against the RESTORELIST above if the count is off 
```

### 3.10 PROD artificial rows + affiliations import + API + backups(hold)

Only after ALL provisions in 3.8/3.9 are Completed:

```bash
kubectl config use-context prod
kubectl exec -it debug -- bash -c "ONLY=\"\$(cat ./devstats-helm/all_prod_dbs.txt)\" RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"

helm install devstats-prod-affs-import ./devstats-helm --set "namespace=devstats-prod,$(skips_except),skipAffiliationsImport=,affiliationsDB=affiliations,prodServer=1,testServer="
helm install devstats-prod-api         ./devstats-helm --set "namespace=devstats-prod,$(skips_except API),apiImage=lukaszgryglicki/devstats-api-prod"
helm install devstats-prod-backups     ./devstats-helm --set "namespace=devstats-prod,$(skips_except Backups),backupsTestServer=,backupsProdServer=1"
kubectl edit cronjob devstats-backups   # set schedule: '45 2 10,20 * *'
# keep it SUSPENDED until after cutover (two backup sources must never run at once):
kubectl patch cronjob devstats-backups -p '{"spec":{"suspend":true}}'
```

### 3.11 PROD smoke + full validation gate

```bash
curl -sk -H 'Host: k8s.devstats.cncf.io' "https://$PROD_NB_IP/" | grep -i grafana && echo PROD-OK
curl -sk -H 'Host: devstats.cncf.io'     "https://$PROD_NB_IP/" | head -5
curl -sk -H 'Host: all.devstats.cncf.io' "https://$PROD_NB_IP/" | grep -i grafana && echo ALL-OK

# checklist before you may proceed to Part 4 - ALL must hold:
kubectl get po -A | grep -Ev 'Running|Completed'                  # empty
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list  # leader + 2 streaming replicas
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list  # leader + 1 replica
kubectl -n devstats-prod get cj | head                            # sync crons exist; spot-check recent sync jobs succeed:
kubectl -n devstats-prod get jobs --sort-by=.metadata.creationTimestamp | tail -20
# spot-check data freshness on a few dashboards through the NB with fake Host headers
```

Linode is now a fully working, self-syncing replica of production. OCI is still live and
serving. Wait until the next Friday for the cutover.

---

## Part 4 - delta restore + DNS cutover (a FRIDAY; go/no-go 13:00, DNS flipped by ~15:00 Warsaw)

Never cut over on a Monday (no working day follows). Rollback at ANY point = flip DNS back
to OCI (prod `132.226.49.222`, test `152.70.192.23`) - OCI stays untouched until Part 5.

### 4.1 Freeze OCI: suspend ALL sync/affiliation crons [OCI]

```bash
kubectl config use-context prod    # OCI kubeconfig!
for ns in devstats-prod devstats-test; do
  kubectl -n "$ns" get cj -o name | xargs -I{} kubectl -n "$ns" patch {} -p '{"spec":{"suspend":true}}'
done
kubectl -n devstats-prod get jobs | grep -v Complete   # wait for in-flight syncs to finish
```

### 4.2 FINAL OCI backups of the delta-restore set [OCI]

Only the big consolidated DBs need a byte-fresh final dump (everything else self-syncs on
Linode from GH Archive within the hour):

```bash
kubectl -n devstats-prod create job --from=cronjob/devstats-backups devstats-backups-final
kubectl -n devstats-prod logs -f job/devstats-backups-final    # wait - this gates everything
# refresh artificial + affiliations dumps too (debug pod, as in 2.2):
S='namespace=devstats-prod,skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1'
S+=',skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1'
S+=',skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1'
S+=',bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s}'
S+=',bootstrapMountBackups=1,limitsBackupsCPU=4000m,limitsBackupsMemory=64Gi'
helm install devstats-prod-debug ./devstats-helm --set "$S"
kubectl -n devstats-prod exec -it debug -- bash -c "ONLY=\"\$(cat ./devel/all_prod_dbs.txt)\" FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh"
helm delete devstats-prod-debug
curl -s https://devstats.cncf.io/backups/ | grep -o 'gha.dump[^<]*'   # timestamp = today
```

### 4.3 Delta re-restore of the big DBs on Linode [master]

FIRST: instant crash-consistent btrfs snapshots of the prod Postgres hostpaths = free
rollback point (Postgres recovers from a snapshot exactly like from a power loss):

```bash
# [workstation]
source linodes.env.secret
for h in $PUB_DEVSTATS_PROD_DB_01 $PUB_DEVSTATS_PROD_DB_02 $PUB_DEVSTATS_PROD_DB_03; do
  ssh root@$h 'btrfs subvolume snapshot -r /data/openebs /data/.snap-openebs-pre-delta; btrfs subvolume list /data'
  ssh root@$h 'compsize /data/openebs | tail -3'    # bonus: see the real zstd ratio
done
# rollback (only if delta-restore goes wrong): on the affected node:
#   systemctl stop kubelet; btrfs subvolume delete /data/openebs
#   btrfs subvolume snapshot /data/.snap-openebs-pre-delta /data/openebs; systemctl start kubelet
```

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl config use-context prod    # LINODE kubeconfig (on the master)
helm delete devstats-prod-kubernetes; sleep 10; restore_prod kubernetes 0 1
helm delete devstats-prod-all;        sleep 10; restore_prod all 38 39
# fresh affiliations too (same one-liner as 3.4, prod + test)
# fresh artificial rows AFTER the two provisions complete (same as 3.10):
watch 'kubectl get po | grep provision'   # Ctrl-C when Completed
kubectl exec -it debug -- bash -c "ONLY=\"\$(cat ./devstats-helm/all_prod_dbs.txt)\" RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"
```

Go/no-go now (13:00): 3.11 checklist still green + the two deltas restored → GO.

### 4.4 Flip DNS [wherever cncf.io DNS is managed]

Record every change in `DNS-switchover.secret` (old value → new value, timestamp):

```text
devstats.cncf.io.     A  -> $PROD_NB_IP     (was 132.226.49.222)
*.devstats.cncf.io.   A  -> $PROD_NB_IP     (was 132.226.49.222)
teststats.cncf.io.    A  -> $TEST_NB_IP     (was 152.70.192.23)
*.teststats.cncf.io.  A  -> $TEST_NB_IP     (was 152.70.192.23)
```

TTL is already 300 (step 0.6) → propagation ≤ 5 min:

```bash
watch -n 20 "dig +short devstats.cncf.io k8s.devstats.cncf.io teststats.cncf.io @8.8.8.8"
```

### 4.5 Watch Let's Encrypt issuance [master]

HTTP-01 works as soon as DNS resolves to the NodeBalancers. Limits: 50 certs/week per
domain, chart packs ≤35 hosts per cert.

```bash
kubectl config use-context prod
kubectl get certificate,order,challenge    # certificates: READY=True (minutes, not hours)
kubectl config use-context test
kubectl get certificate,order,challenge
curl -sI https://devstats.cncf.io/  | head -3    # real cert now, no -k needed
curl -sI https://k8s.devstats.cncf.io/ | head -3
curl -sI https://teststats.cncf.io/ | head -3
```

### 4.6 Populate the Linode backups PV NOW + enable prod backups cron [master]

The moment DNS flips, `https://devstats.cncf.io/backups/` serves the LINODE backups PV -
which is empty. gitdm/cncf tooling and future restores need it populated:

```bash
kubectl config use-context prod
kubectl patch cronjob devstats-backups -p '{"spec":{"suspend":false}}'
kubectl create job --from=cronjob/devstats-backups devstats-backups-initial
kubectl logs -f job/devstats-backups-initial    # hours; runs unattended
# ALSO refresh artificial dumps INTO the Linode PV (debug pod, backup direction):
kubectl exec -it debug -- bash -c "ONLY=\"\$(cat ./devstats-helm/all_prod_dbs.txt)\" FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh"
```

### 4.7 Re-apply intentional cron suspends from the OCI snapshot [master]

```bash
grep 'suspend=true' oci-cron-suspends.secret   # (scp it to the master if needed)
# for each intentionally-suspended cron that exists on Linode, mirror it:
# kubectl -n <ns> patch cronjob <name> -p '{"spec":{"suspend":true}}'
# verify test backups stayed suspended:
kubectl -n devstats-test get cj devstats-backups -o jsonpath='{.spec.suspend}{"\n"}'   # true
```

### 4.8 Host-level extras that lived outside k8s on OCI

```bash
# landscape sync cron - moves to devstats-compute-02 (check OCI bastion crontab first):
ssh root@$PUB_DEVSTATS_COMPUTE_02 'crontab -l'
# add (adjust to whatever the OCI bastion had):  0 3 * * * /root/check_sync.sh
# gitdm / cncf/velocity jobs that pull https://devstats.cncf.io/backups/ - no change needed,
# they follow DNS; just confirm the first post-cutover run succeeds.
```

### 4.9 First-24h monitoring [master]

```bash
kubectl get po -A | grep -Ev 'Running|Completed'      # repeatedly; empty
kubectl -n devstats-prod get jobs --sort-by=.metadata.creationTimestamp | tail   # hourly syncs green
kubectl -n devstats-prod logs -l app.kubernetes.io/name=ingress-nginx --tail=200 | grep -c ' 200 '   # traffic arriving
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list
# spot-check https://devstats.cncf.io, https://k8s.devstats.cncf.io, https://all.devstats.cncf.io,
# https://teststats.cncf.io in a browser - dashboards fresh (Last sync < 2h on home pages)
```

ROLLBACK (any failure you cannot fix quickly): flip the four DNS records back to
`132.226.49.222`/`152.70.192.23`, unsuspend the OCI crons (`suspend:false` on everything that
was running per `oci-cron-suspends.secret`), suspend Linode's `devstats-backups` again. OCI
is 100% intact until Part 5.

---

## Part 5 - soak + OCI decommission (the NEXT Mon + Fri; nothing before 72 h)

### 5.1 Soak checklist (Monday after cutover) [master]

```bash
# 2+ days of green syncs everywhere:
for ctx in prod test; do kubectl config use-context $ctx; kubectl get jobs --sort-by=.metadata.creationTimestamp | tail -30; done
# affiliations import cron ran (or run it once manually) and dashboards show updated affs
# scheduled prod backup (10th/20th 02:45) or the manual one is green AND restorable:
kubectl config use-context prod
kubectl exec -it debug -- bash -c 'cd /tmp && curl -fsSL -o t.dump https://devstats.cncf.io/backups/homebrew.dump && pg_restore --list t.dump | head && rm t.dump'
# certificates all READY, no pending challenges:
kubectl get certificate -A | grep -v True    # empty
```

Soak green → drop the pre-cutover btrfs snapshots (they pin deleted data = grow over time):

```bash
# [workstation]
source linodes.env.secret
for h in $PUB_DEVSTATS_PROD_DB_01 $PUB_DEVSTATS_PROD_DB_02 $PUB_DEVSTATS_PROD_DB_03; do
  ssh root@$h 'btrfs subvolume delete /data/.snap-openebs-pre-delta; btrfs filesystem usage -T /data | head -12'
done
```

### 5.2 Final state snapshot (goes into the repo/docs) [master]

```bash
helm list -A -o yaml          > linode-helm-releases.snapshot.yaml
kubectl get cj -A -o yaml     > linode-cronjobs.snapshot.yaml
kubectl get nodes -o wide     > linode-nodes.snapshot.txt
kubectl get pv,pvc -A         > linode-storage.snapshot.txt
```

### 5.3 Decommission OCI (Friday; ONLY after explicit sign-off) 

Confirm with the team (Shah/Ihor) that nothing else lives on those OCI resources. Then, in
the OCI console/CLI, in this order:

1. Delete the two Network Load Balancers (prod `132.226.49.222`, test `152.70.192.23`).
2. Terminate all compute instances of the old cluster (keep boot-volume backups for 30 days
   if policy allows - free rollback insurance).
3. Delete block volumes / boot volumes after instance termination.
4. Delete the VCN, subnets, security lists, gateways.
5. Remove any OCI DNS entries / reserved public IPs that are now unused.
6. Delete old kubeconfig contexts pointing at OCI from your workstation.

### 5.4 Repo/docs cleanup [workstation]

```bash
# update devstats-helm docs: new NB IPs, node inventory, k8s/ingress versions, this runbook's
# "was" values; commit the snapshots from 5.2; remove/archive OCI-specific docs and scripts.
git -C ~/dev/go/src/github.com/cncf/devstats-helm status
```

**DONE.** DevStats runs on 8 × Linode G7 Dedicated 256 GB in us-ord, k8s ${K8S_PATCH},
final-release ingress-nginx, Patroni HA on OpenEBS - and `linodes.env.secret` +
`DNS-switchover.secret` + the snapshots document exactly how it was built.
