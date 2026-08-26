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
- **CWD/env assumption**: EVERY command block (any host tag) assumes the shell is at the repo
  root (workstation: this checkout; master: `/root/devstats-helm`) with
  `source linodes.env.secret` already run. Blocks only repeat the
  `cd ... && source linodes.env.secret` line as a reminder where a fresh shell/host switch is
  likely - if any `$VAR` comes up empty, re-run that resume line first.
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
- UPDATE 2026-08-25: calendar accelerated - cutover is NOT postponed to Friday. Plan:
  request DNS switchover from LF ASAP, test domain(s) first; once test DNS is confirmed
  working, request prod. All Linode CJs run original schedules, unsuspended, under
  observation. Part 4 steps below remain valid - just executed as soon as LF responds.

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
# DELIBERATE design change vs the earlier 3-node-minimum discussion: TEST Patroni runs
# with only 2 members on the 8x256 layout. Replication + automatic failover still work,
# but while one member is down TEST has NO remaining replica (no further failover) until
# it recovers. Acceptable for TEST; PROD keeps 3 members and full redundancy.
export TEST_POSTGRES_STORAGE='3600Gi'
# TEST sizing from MEASURED reality (2026-08-21 live OCI): only 16 DBs, 170 GB total,
# biggest = cii 85 GB, ~34 connections - test needs far less than prod (245 DBs, 1793 GB)
export TEST_PG_REQ_CPU='4000m';   export TEST_PG_LIM_CPU='32000m'
export TEST_PG_REQ_MEM='40Gi';    export TEST_PG_LIM_MEM='128Gi'

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

# API_CATCHUP_RANGE: FALLBACK ghapi2db lookback, used only when the dump's Last-Modified
# header cannot be read. Normally the window is COMPUTED per restore: dump age + 2 days
# margin (see catchup_range below) - so a fresh dump costs minutes of GitHub API work, not
# hours. Events themselves need no window - gha2db_sync replays GH Archive from the max
# event time in the restored DB. Only applies to the one-shot provision pod: hourly-sync
# crons do not template ghapi* values and keep the 8h default.
export API_CATCHUP_RANGE='12 days'

# proj_db <proj>: dump/DB name for a project (kubernetes->gha, all->allprj, else proj)
proj_db () {
  case "$1" in kubernetes) echo gha;; all) echo allprj;; *) echo "$1";; esac
}

# catchup_range <dump-url>: ghapi2db window = dump age (from Last-Modified) + 2 days margin
catchup_range () {
  local lm secs
  lm="$(curl -fsSI "$1" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{print $2}')"
  secs="$(date -d "${lm}" +%s 2>/dev/null)" || secs=''
  if [ -z "${lm}" ] || [ -z "${secs}" ]; then echo "${API_CATCHUP_RANGE}"; return; fi
  echo "$(( ( $(date +%s) - secs ) / 86400 + 2 )) days"
}

# restore_prod <proj> <indexFrom> <indexTo>: restores one PROD project from the OCI backups
# page (kubectl context MUST be `prod` on the master). Installs release devstats-prod-<proj>
# (provision pod running devstats-helm/restore.sh + the project crons/grafanas/services).
# skipPVs=1: project PVCs already exist (owned by the devstats-*-pvcs release from 1.19).
restore_prod () {
  local s='namespace=devstats-prod,skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1'
  s+=',skipBootstrap=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipPVs=1'
  s+=",indexProvisionsFrom=$2,indexProvisionsTo=$3"
  s+=",indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3"
  s+=",indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=$2,indexAffiliationsTo=$3"
  s+=',provisionImage=lukaszgryglicki/devstats-prod,provisionCommand=devstats-helm/restore.sh'
  s+=',restoreFrom=https://devstats.cncf.io/backups/,testServer=,prodServer=1'
  local cr; cr="$(catchup_range "https://devstats.cncf.io/backups/$(proj_db "$1").dump")"
  echo "ghapi2db catch-up window for ${1}: ${cr}"
  s+=",ghapiRecentRange=${cr},ghapiOrphanCommitsRange=${cr},ghapiRecentReposRange=${cr}"
  helm install "devstats-prod-${1}" ./devstats-helm -n devstats-prod --set "${s}" \
    && echo "watch: kubectl -n devstats-prod logs -f devstats-provision-${1}"
}

# restore_test <proj> <indexFrom> <indexTo>: same for TEST (context `test`; teststats source)
restore_test () {
  local s='skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1'
  s+=',skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipAddAll=1,skipPVs=1'
  s+=",indexProvisionsFrom=$2,indexProvisionsTo=$3"
  s+=",indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3"
  s+=",indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=$2,indexAffiliationsTo=$3"
  s+=',provisionCommand=devstats-helm/restore.sh,restoreFrom=https://teststats.cncf.io/backups/'
  s+=",projectsOverride=+${1}"
  local cr; cr="$(catchup_range "https://teststats.cncf.io/backups/$(proj_db "$1").dump")"
  echo "ghapi2db catch-up window for ${1}: ${cr}"
  s+=",ghapiRecentRange=${cr},ghapiOrphanCommitsRange=${cr},ghapiRecentReposRange=${cr}"
  helm install "devstats-test-${1}" ./devstats-helm -n devstats-test --set "${s}" \
    && echo "watch: kubectl -n devstats-test logs -f devstats-provision-${1}"
}

# wait_provisions [N] [ns]: block while N or more provision pods still run in ns
wait_provisions () {
  local cap="${1:-6}" ns="${2:-devstats-prod}"
  while [ "$(kubectl -n "${ns}" get po --no-headers 2>/dev/null | grep -c 'devstats-provision')" -ge "${cap}" ]; do
    echo "$(date '+%H:%M') - >=${cap} provision pods running in ${ns}, waiting..."; sleep 60
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
sv ALL_VPC_IPS "10.60.0.11 10.60.0.12 10.60.0.13 10.60.0.21 10.60.0.22 10.60.0.31 10.60.0.32 10.60.0.33"
```

### 1.5 Disk re-layout on every node (BEFORE installing anything) [workstation]

Each node: shut down → delete swap disk → shrink root to 120 GB → create one big RAW
`data` disk from the rest (~5,000 GB) → attach as `/dev/sdc` → boot. Step 1.7a then
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
Everything space-hungry is symlinked onto `/data` in step 1.7a - container images
(`/var/lib/containerd`), kubelet volumes (`/var/lib/kubelet`), etcd (`/var/lib/etcd`),
pod/container logs, and OpenEBS hostpath data (`/var/openebs`) - so kubernetes/containerd
image pulls never fill the root filesystem.

```bash
wait_status () { while [ "$(linode-cli linodes view "$1" --json | jq -r '.[0].status')" != "$2" ]; do sleep 10; done; }
wait_disks  () { while linode-cli linodes disks-list "$1" --json | jq -e '.[] | select(.status!="ready")' >/dev/null 2>&1; do sleep 10; done; }
# wait_disk ID DISK_ID: waits until that SPECIFIC disk exists AND is ready (a freshly
# created disk is NOT instantly visible in disks-list - waiting on "all ready" races)
wait_disk () {
  while [ "$(linode-cli linodes disks-list "$1" --json | jq -r --arg d "$2" '.[] | select((.id|tostring)==$d) | .status')" != "ready" ]; do sleep 10; done
}

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
  wait_disk "$id" "$data_id"
  cfg_id="$(linode-cli linodes configs-list "$id" --json | jq -r '.[0].id')"
  # config-update REPLACES the whole devices map - always pass sda (root) AND sdc (data)!
  linode-cli linodes config-update "$id" "$cfg_id" \
    --devices.sda.disk_id "$root_id" --devices.sdc.disk_id "$data_id" >/dev/null
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

### 1.7a Filesystem & identity on ALL 8 nodes - NO installs yet [workstation → each node]

Hostname + /etc/hosts + btrfs `/data` only (idempotent; ~1 min/node). Nothing is installed
here, so you can stop after this step and inspect `/data` before any software lands:

```bash
for h in $NODE_PUB_IPS; do
  echo "===== filesystem: $h ====="
  ssh -o StrictHostKeyChecking=accept-new root@$h bash -s <<'FSSETUP'
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

# [2] hostname from VPC IP (Linode images boot as "localhost"; kubelet uses the
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

# [3] /data = btrfs + transparent zstd on the raw data disk (/dev/sdc from step 1.5)
command -v mkfs.btrfs >/dev/null || apt-get install -y btrfs-progs  # preinstalled on 26.04
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
chown root:root /data && chmod 755 /data   # NEVER -R: re-runs must not chown Postgres PVC data
[ -e /var/openebs ]        || ln -s /data/openebs /var/openebs
[ -e /var/lib/containerd ] || ln -s /data/containerd /var/lib/containerd
[ -e /var/lib/kubelet ]    || ln -s /data/kubelet /var/lib/kubelet
[ -e /var/lib/etcd ]       || ln -s /data/etcd /var/lib/etcd
[ -e /var/log/pods ]       || ln -s /data/logs/pods /var/log/pods
[ -e /var/log/containers ] || ln -s /data/logs/containers /var/log/containers

# [5] swap off now and at every boot (the swap DISK itself was already deleted in step 1.5)
swapoff -a; sed -i '/\sswap\s/d' /etc/fstab
echo "FS READY: $(hostname) $(findmnt -no FSTYPE /data) $(findmnt -no OPTIONS /data)"
FSSETUP
done
```

Gate: every node printed `FS READY: devstats-... btrfs ...zstd:3...` - the first field MUST
be that node's own `devstats-*` name (NOT `localhost`), /data MUST be btrfs with zstd.

### 1.7b Reboot ALL 8 nodes + verify automount survives boot [workstation]

Prove the fs layout is boot-persistent BEFORE anything is installed on top of it.
Reboot via the Linode API, NOT in-guest `reboot` (a guest reboot can land the node in
`offline` and stay there until the watchdog kicks in minutes later - or not at all):

```bash
for v in ${!ID_DEVSTATS_*}; do echo "rebooting $v (${!v})"; linode-cli linodes reboot "${!v}" >/dev/null; done
sleep 90    # nodes take ~1-2 min to come back; re-run the loop below until all 8 answer
for h in $NODE_PUB_IPS; do
  echo "===== verifying: $h ====="
  ssh -o ConnectTimeout=10 root@$h 'echo "host: $(hostname)"; df -h / /data | tail -2; \
    findmnt -no FSTYPE,OPTIONS /data; swapon --show | grep -q . && echo SWAP-ON || echo no-swap; \
    echo "systemd: $(systemctl is-system-running)"'
done
```

Known reboot quirks (all hit during the live run - none is fatal):

- `ssh: connect to host ... port 22: Connection refused` right after the node shows
  `running`: Linode `running` means the VM booted, NOT that sshd is up yet - it can lag
  by ~1 min on first boot after a resize. Just re-run the verify loop; do NOT panic-boot.
- `systemd: degraded` with `grub2-common.service` failed (`grub-editenv: error: invalid
  environment block`): the offline root resize in 1.5 can corrupt `/boot/grub/grubenv`.
  Harmless (Linodes boot via host-side GRUB), but fix it so `degraded` never masks a REAL
  failure later: `ssh root@$h 'grub-editenv /boot/grub/grubenv create && systemctl restart
  grub2-common.service && systemctl is-system-running'` - must print `running`.

If a node stays unreachable: `linode-cli linodes view "$ID_..." --json | jq -r '.[0].status'`
- when it reports `offline`, start it with `linode-cli linodes boot "$ID_..."`.

Gate, on EVERY node: its own `devstats-*` hostname, `/` ~119G on /dev/sda, `/data` ~4.8T
btrfs with `compress-force=zstd:3`, `no-swap`, and `systemd: running`. Only then continue
to 1.7c.

### 1.7c OS packages + k8s prerequisites on ALL 8 nodes [workstation → each node]

Installs everything (idempotent; ~5 min/node; run sequentially so failures are obvious):

```bash
for h in $NODE_PUB_IPS; do
  echo "===== installing: $h ====="
  ssh root@$h \
    "K8S_STREAM='$K8S_STREAM' K8S_PATCH='$K8S_PATCH' HELM_VERSION='$HELM_VERSION' HELM_SHA256='$HELM_SHA256' CONTAINERD_VERSION='$CONTAINERD_VERSION' CRICTL_VERSION='$CRICTL_VERSION' bash -s" <<'NODESETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
findmnt -no FSTYPE /data | grep -qx btrfs || { echo 'run step 1.7a on this node first'; exit 1; }

# [6] base packages
chmod -x /etc/update-motd.d/* 2>/dev/null || true
# Linode's Ubuntu image ships a CORRUPTED debconf answer: grub-pc/install_devices is the
# literal string "multiselect", so any grub-pc upgrade runs `grub-install /multiselect`
# and dpkg dies mid-upgrade. Linodes boot via HOST-side GRUB and the root disk is
# partitionless (no MBR gap), so grub-install must be SKIPPED entirely - empty the list:
echo 'grub-pc grub-pc/install_devices multiselect ' | debconf-set-selections
echo 'grub-pc grub-pc/install_devices_disks_changed multiselect ' | debconf-set-selections
echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections
dpkg --configure -a    # heals a half-configured grub-pc left by an earlier failed run
apt-get update -y && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg gpg nfs-common net-tools \
  iptables-persistent jq mc btop iperf3 fio btrfs-progs btrfs-compsize

# [7] kernel modules, sysctls, forwarding
# nf_conntrack must be loaded NOW or the net.netfilter.nf_conntrack_max sysctl silently
# does not exist yet (the module would only autoload once kube-proxy adds NAT rules)
printf 'overlay\nbr_netfilter\nnf_conntrack\n' > /etc/modules-load.d/containerd.conf
modprobe overlay; modprobe br_netfilter; modprobe nf_conntrack
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

# [8] containerd (pinned) + runc + crictl (pinned), systemd cgroups
if ! command -v containerd >/dev/null; then
  curl -fsSL -o /tmp/containerd.tgz "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
  tar -C /usr/local -xzf /tmp/containerd.tgz && rm /tmp/containerd.tgz
  curl -fsSL -o /etc/systemd/system/containerd.service "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service"
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

# [9] kubelet/kubeadm/kubectl pinned to EXACTLY ${K8S_PATCH}, held
mkdir -p -m 755 /etc/apt/keyrings
if [ ! -f "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg" ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/Release.key" | gpg --dearmor -o "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/ /" > "/etc/apt/sources.list.d/kubernetes-${K8S_STREAM/v/}.list"
fi
apt-get update
# NO `exit` inside awk: an early exit SIGPIPEs apt-cache and set -o pipefail kills the
# whole script silently (bit us live on 2 nodes) - consume all input, print first match
PKG="$(apt-cache madison kubeadm | awk -v p="${K8S_PATCH}-" 'index($3,p)==1 && !f {print $3; f=1}')"
[ -n "$PKG" ] || { echo "kubernetes ${K8S_PATCH} not in the ${K8S_STREAM} apt stream:"; apt-cache madison kubeadm; exit 1; }
apt-get install -y --allow-change-held-packages kubelet="$PKG" kubeadm="$PKG" kubectl="$PKG"
apt-mark hold kubelet kubeadm kubectl
kubeadm version -o short | grep -qx "v${K8S_PATCH}" || { echo "kubeadm version mismatch"; exit 1; }

# [10] helm pinned + sha256-verified
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

Recovery if a run died in [6] with `grub-install /multiselect` / `dpkg: error processing
package grub-pc` (nodes set up before the debconf preseed above existed): just re-run the
whole NODESETUP on that node - the preseed + `dpkg --configure -a` heal the half-configured
grub-pc, and everything after it is idempotent. Verify with: `dpkg --audit` (must print
nothing) and `sysctl -n net.netfilter.nf_conntrack_max` (must print 2621440).

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
# the delete/re-register above LOSES the kubeadm control-plane labels (added only at
# init) - restore them; kubeadm upgrade tooling finds control-plane nodes by this label:
kubectl label node devstats-compute-01 node-role.kubernetes.io/control-plane= node.kubernetes.io/exclude-from-external-load-balancers=
# coredns pods still hold sandboxes wired to the PRE-dance cni0 - sooner or later they
# CrashLoop with "dial tcp 10.96.0.1:443: connect: no route to host". Recreate them now:
kubectl -n kube-system delete po -l k8s-app=kube-dns
sleep 30; kubectl -n kube-system get po -l k8s-app=kube-dns    # both 1/1 Running
```

### 1.8b OPTIONAL: env file on every node + full root SSH mesh [workstation]

Everything in this runbook runs from the workstation, so this step is optional - but handy:
every node gets `/root/linodes.env.secret` (so `source linodes.env.secret` works right after
ssh-ing anywhere) and every node can root-ssh to every other node without password prompts.
Nodes already resolve each other by hostname over the VPC (`/etc/hosts`, set up in 1.7a).

```bash
source linodes.env.secret
NODE_NAMES="devstats-prod-db-01 devstats-prod-db-02 devstats-prod-db-03 devstats-test-db-01 devstats-test-db-02 devstats-compute-01 devstats-compute-02 devstats-compute-03"

# (a) workstation first: learn all public-IP host keys once (kills yes/no prompts), then push env:
ssh-keyscan -T 5 $NODE_PUB_IPS 2>/dev/null >> ~/.ssh/known_hosts; sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts
for h in $NODE_PUB_IPS; do scp -q linodes.env.secret root@$h:/root/; done

# (b) each node: root ed25519 key (generate if missing), then collect all 8 pubkeys:
for h in $NODE_PUB_IPS; do
  ssh root@$h "[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519"
done
: > /tmp/mesh.pub
for h in $NODE_PUB_IPS; do ssh root@$h 'cat /root/.ssh/id_ed25519.pub' >> /tmp/mesh.pub; done

# (c) merge all 8 pubkeys into every node's authorized_keys (idempotent, keeps existing keys):
for h in $NODE_PUB_IPS; do
  scp -q /tmp/mesh.pub root@$h:/tmp/mesh.pub
  ssh root@$h 'touch /root/.ssh/authorized_keys; sort -u /root/.ssh/authorized_keys /tmp/mesh.pub > /tmp/ak; mv /tmp/ak /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; rm -f /tmp/mesh.pub'
done
rm -f /tmp/mesh.pub

# (d) known_hosts: every node pre-learns every peer under hostname, master alias AND public IP
#     (so no "authenticity of host" prompts ever; $NODE_NAMES/$NODE_PUB_IPS expand HERE):
for h in $NODE_PUB_IPS; do
  ssh root@$h "ssh-keyscan -T 5 $NODE_NAMES devstats-master $NODE_PUB_IPS 2>/dev/null >> /root/.ssh/known_hosts; sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts"
done

# (e) verify all 64 hops non-interactively - silence means every hop works:
for h in $NODE_PUB_IPS; do
  for n in $NODE_NAMES; do
    ssh root@$h "ssh -o BatchMode=yes -o ConnectTimeout=5 root@$n hostname" >/dev/null 2>&1 || echo "FAIL: $h -> $n"
  done
done; echo "mesh check done (no FAIL lines above = all 64 hops OK)"
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

### 1.9b kubectl from the workstation - "linode" context next to the OCI ones [workstation]

Your existing `prod`/`test`/`shared` contexts reach OCI through the FreeBSD `kube_tunnel`
rc.d service (lo0 alias 10.0.0.253 + `ssh -N -L 10.0.0.253:6443:10.0.0.253:6443 ubuntu@omaster`,
auto-respawned by daemon(8); `service kube_tunnel status|start|stop`). The Linode apiserver
needs NO tunnel - it is directly reachable on the master public IP. The apiserver cert has
SANs [devstats-compute-01, kubernetes*, 10.96.0.1, 10.60.0.31] - the public IP is NOT there,
so the cluster entry pins `tls-server-name: kubernetes` (alternative: add certSANs via the
kubeadm-config CM + regen the apiserver cert - not worth it). When the firewall arrives
(Part 6) remember to keep 6443/tcp open from your workstation IP.

```bash
source linodes.env.secret
scp root@$MASTER_IP:/etc/kubernetes/admin.conf /tmp/linode-admin.conf
cp -p ~/.kube/config ~/.kube/config.$(date +%Y-%m-%d)     # backup first
CA=$(awk '/certificate-authority-data/{print $2}' /tmp/linode-admin.conf)
CRT=$(awk '/client-certificate-data/{print $2}' /tmp/linode-admin.conf)
KEY=$(awk '/client-key-data/{print $2}' /tmp/linode-admin.conf)
kubectl config set-cluster linode --server="https://$MASTER_IP:6443"
kubectl config set clusters.linode.certificate-authority-data "$CA"
kubectl config set clusters.linode.tls-server-name kubernetes
kubectl config set users.linode-admin.client-certificate-data "$CRT"
kubectl config set users.linode-admin.client-key-data "$KEY"
kubectl config set-context linode --cluster=linode --user=linode-admin --namespace=default
# namespaced twins of the OCI prod/test contexts (namespaces themselves come in 1.12):
kubectl config set-context linode-prod --cluster=linode --user=linode-admin --namespace=devstats-prod
kubectl config set-context linode-test --cluster=linode --user=linode-admin --namespace=devstats-test
rm /tmp/linode-admin.conf
kubectl --context linode get nodes     # 8 Ready - without changing your current context
kubectl --context linode-prod get nodes && kubectl --context linode-test get nodes   # same
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
# every pod must be Running (catches the stale-sandbox coredns CrashLoop from 1.8):
kubectl get po -A --no-headers | grep -v ' Running ' || echo 'ALL PODS RUNNING'
# in-cluster DNS smoke - must print 10.96.0.1:
kubectl run dnstest --image=busybox:1.36 --restart=Never --rm -i -- nslookup kubernetes.default.svc.cluster.local
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

Storage-placement policy (only PROD-db disks are tight): the 3 PROD Patroni nodes hold
ONLY prod patroni DB data plus small-to-medium stuff (ingress controller pods, DaemonSets,
short-lived/temporary migration pods - deleted right after the migration). They are NEVER
allowed to hold backups, git clones, or anything that can grow to a comparable size.
ALL such data - git clones, backups PV, grafana/provision workdirs - goes to the
3 compute nodes + the 2 test-db nodes (test DBs are small, plenty of room).
The chart enforces this via `appNodeSelector`/`backupsNodeSelector`
(= `node: devstats-app`) on every pod that writes to `openebs-hostpath` (provisions,
hourly syncs, grafanas, bootstrap, affs-sync, backups), and hostpath PVCs bind to the
node of their first consumer - so `node=devstats-app` goes everywhere EXCEPT prod-db nodes:

```bash
# app/backup/git-clone label - computes + test-db nodes (NEVER the prod-db nodes):
for n in devstats-compute-01 devstats-compute-02 devstats-compute-03 devstats-test-db-01 devstats-test-db-02; do
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
  --set localpv-provisioner.hostpathClass.isDefaultClass=true \
  --set localpv-provisioner.localpv.nodeSelector.node=devstats-app
kubectl -n openebs get pods -w        # Ctrl-C when all Ready
kubectl get sc                        # openebs-hostpath must exist and be (default)
helm repo add openebs-dynamic-nfs https://openebs-archive.github.io/dynamic-nfs-provisioner/ && helm repo update
# nfsServerNodeAffinity pins the per-PVC NFS SERVER pods (which PHYSICALLY hold the
# backups-PV data on their hostpath) to devstats-app nodes - never on prod Patroni nodes.
# nfsProvisioner.nodeSelector pins the CONTROLLER deployment (stateless, but keep it off
# prod-db nodes too) - these are two different knobs for two different pods:
helm install openebs-nfs openebs-dynamic-nfs/nfs-provisioner --namespace openebs-nfs --create-namespace \
  --set nfsStorageClass.name=nfs-openebs-localstorage --set-string nfsStorageClass.backendStorageClass=openebs-hostpath \
  --set-string 'nfsProvisioner.nfsServerNodeAffinity=node:[devstats-app]' \
  --set nfsProvisioner.nodeSelector.node=devstats-app
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
  # NFS first-PVC spin-up (image pull + server pod) can take >1 min - wait properly:
  for i in $(seq 1 24); do
    [ "$(kubectl get po gate-$sc -o jsonpath='{.status.phase}' 2>/dev/null)" = "Succeeded" ] && break; sleep 5
  done
  kubectl logs "gate-$sc"   # must print: ok
  kubectl delete po "gate-$sc"; kubectl delete pvc "gate-$sc"
done
# fallback if OpenEBS 4.5.1 misbehaves: OCI-proven 3.10.0 from https://openebs.github.io/charts
```

Verify placement - the backups-PV data lives on the NFS server pod's node, so every pod in
`kubectl -n openebs-nfs get po -o wide` must sit on a devstats-app node (compute-* or
test-db-*; NFS server pods are created per-PVC, so check again after 1.19). The controller
pod (`openebs-nfs-nfs-provisioner-*`) is covered by the nodeSelector; the per-PVC
`nfs-pvc-*` pods by nfsServerNodeAffinity.

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
  --rollback-on-failure    # helm v4 name for the deprecated --atomic
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
  # VPC-attached NB backends REQUIRE --subnet_id (API 400 "node address of vpc type" without it):
  for ip in "$@"; do linode-cli nodebalancers node-create "$nb" "$cfg" --subnet_id "$SUBNET_ID" \
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

# per env: temp Service -> the controller's own /healthz (10254), temp Ingress on /gate with a
# rewrite to /healthz, curl through EVERY NodePort backend (HTTP+HTTPS), isolation, clean up.
# NEVER probe /healthz through the data plane: the controller's catch-all server special-cases
# 'location /healthz' and answers 200 for ANY Host even with ZERO Ingresses (LB health checks).
# Only /gate proves real Ingress routing: wrong host/class falls to the catch-all -> 404.
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
  kubectl -n "$ns" create ingress ingress-smoke --class="$class" \
    --annotation nginx.ingress.kubernetes.io/rewrite-target=/healthz \
    --rule="${host}/gate*=ingress-smoke:80" \
    || { echo "ADMISSION WEBHOOK FAILED in $ns - GATE FAILED"; return 1; }
  sleep 15
  local ip rc
  for ip in "$@"; do
    rc="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://${ip}:${hp}/gate")"
    echo "HTTP  ${ip}:${hp} -> ${rc}";  [ "$rc" = "200" ] || { echo GATE FAILED; return 1; }
    rc="$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: ${host}" "https://${ip}:${sp}/gate")"
    echo "HTTPS ${ip}:${sp} -> ${rc}"; [ "$rc" = "200" ] || { echo GATE FAILED; return 1; }
  done
}
gate_env test devstats-test nginx-test smoke.test.local 31080 31443 $TEST_INGRESS_BACKEND_VPC_IPS
gate_env prod devstats-prod nginx-prod smoke.prod.local 30080 30443 $PROD_INGRESS_BACKEND_VPC_IPS

# class isolation: the OTHER env's host must NOT be served (expect 404, never 200)
# probe /gate, NOT /healthz - /healthz is answered 200 by every controller for any Host
curl -s -o /dev/null -w 'isolation prod-host-via-test: %{http_code}\n' -H 'Host: smoke.prod.local' http://10.60.0.32:31080/gate
curl -s -o /dev/null -w 'isolation test-host-via-prod: %{http_code}\n' -H 'Host: smoke.test.local' http://10.60.0.31:30080/gate

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
cd /root/devstats-helm && source linodes.env.secret
helm repo add jetstack https://charts.jetstack.io && helm repo update
# pin every component to app nodes (node=devstats-app) - prod-db nodes stay DB-only:
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" --set crds.enabled=true \
  --set nodeSelector.node=devstats-app \
  --set webhook.nodeSelector.node=devstats-app \
  --set cainjector.nodeSelector.node=devstats-app \
  --set startupapicheck.nodeSelector.node=devstats-app
kubectl -n cert-manager get po -o wide -w   # Ctrl-C when Ready; NODE = computes/test-dbs only
# apply the issuers straight from the .secret file (NEVER copy secrets into non-.secret names):
kubectl apply -f cert/cert-issuer.yaml.secret
kubectl get issuer -A                       # both letsencrypt-{prod,test} must reach READY=True
# certificates only get ISSUED after DNS points here (HTTP-01 on port 80) - that is expected
```

### 1.18.1 metrics-server (kubectl top) [master]

Not required by DevStats, but makes `kubectl top nodes/pods` work - very handy for watching
restore/provision load. kubeadm kubelets use self-signed serving certs, so the
`--kubelet-insecure-tls` flag is REQUIRED (without it metrics-server logs x509 errors and
stays NotReady):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment metrics-server --timeout=120s
sleep 20 && kubectl top nodes   # all 8 nodes must show CPU/MEM percentages
```

### 1.19 DevStats secrets + backups PV + project PVCs (both envs) [master]

Always pass `-n devstats-{test,prod}` to helm: without it the RELEASE metadata lands in the
current context's namespace (the chart's objects go to `.Values.namespace` regardless - test
is the chart default, prod needs `namespace=devstats-prod`), and a stale context would split
them apart. `projectsOverride` only sets `GHA2DB_PROJECTS_OVERRIDE` inside future pods - it
does NOT filter PVC creation, so ALL project PVCs appear in test and the non-test ones are
pruned right after. `Pending` is EXPECTED for every project PVC (`WaitForFirstConsumer` -
they bind when the first pod uses them); only `devstats-backups` (NFS) binds immediately.

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl config use-context test
helm install devstats-test-secrets    ./devstats-helm -n devstats-test --set "$(skips_except Secrets)"
helm install devstats-test-backups-pv ./devstats-helm -n devstats-test --set "$(skips_except BackupsPV)"
helm install devstats-test-pvcs       ./devstats-helm -n devstats-test --set "$(skips_except PVs),projectsOverride=${TEST_PROJECTS}"
# prune the NON-test-project PVCs (chart creates all ~283; test keeps its 12 + backups):
keep_re="$(echo "$TEST_PROJECTS" | tr -d '+\\' | tr ',' '|')"
kubectl -n devstats-test get pvc --no-headers | awk '{print $1}' \
  | grep -Ev "^devstats-pvc-(${keep_re})$|^devstats-backups$" \
  | xargs -r kubectl -n devstats-test delete pvc
kubectl -n devstats-test get pvc --no-headers | wc -l   # exactly 13 (12 projects + backups)

kubectl config use-context prod
helm install devstats-prod-secrets    ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except Secrets)"
helm install devstats-prod-backups-pv ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except BackupsPV)"
helm install devstats-prod-pvcs       ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except PVs)"

# PROD prune: the chart is a superset of what OCI prod actually serves - drop PVCs for
# archived projects (rkt, opentracing, brigade, ...) + test-only godotengine. The list below
# was derived by diffing live PVC sets (workstation, where both OCI+Linode contexts exist):
#   comm -13 <(kubectl --context <oci-prod> get pvc ... | sort) <(linode prod pvc list | sort)
# NOTE: keptn/smi/sealer/teller/cnigenie are archived but STILL deployed on OCI - kept.
echo "$PROD_ARCHIVED_PVCS" | tr ' ' '\n' | xargs -r kubectl -n devstats-prod delete pvc
kubectl -n devstats-prod get pvc --no-headers | wc -l   # exactly 262 (261 projects + backups)

# gate: releases live in their own namespaces, backups PVCs Bound 2Ti RWX in both envs
helm ls -n devstats-test    # devstats-test-{secrets,backups-pv,pvcs} + nginx-ingress-test
helm ls -n devstats-prod    # devstats-prod-{secrets,backups-pv,pvcs} + nginx-ingress-prod
kubectl -n devstats-test get pvc devstats-backups; kubectl -n devstats-prod get pvc devstats-backups
kubectl -n devstats-test get secret | grep -E 'pg-db|github-oauth|grafana-secret'   # 3 secrets
kubectl -n devstats-prod get secret | grep -E 'pg-db|github-oauth|grafana-secret'   # 3 secrets
```

Storage-placement gate - the two backups-PV NFS server pods (one per env, appeared just now)
and their backing hostpath data MUST sit on `node=devstats-app` nodes (computes + test-dbs),
NEVER on the reserved PROD Patroni nodes:

```bash
kubectl -n openebs-nfs get po -o wide     # NODE column: never devstats-prod-db-*
# hostpath PVs record their node in nodeAffinity - none may say prod-db:
kubectl get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,NODE:'.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
```

### 1.20 Patroni TEST (2 nodes, empty) + tune + restart + failover check [master]

Sizing MUST be passed as helm values: the patroni image renders `PATRONI_POSTGRES_*` envs
into the LOCAL `/home/postgres/patroni.yml`, and local `postgresql.parameters` OVERRIDE the
DCS (`patronictl edit-config` / REST PATCH) for everything except the Patroni-controlled
params. The DCS PATCH below only carries what ONLY the DCS can set: the Patroni-controlled
params (`max_connections`, `max_worker_processes`, `max_locks_per_transaction`,
`max_wal_senders`, `max_replication_slots`, `wal_level`, `wal_log_hints`, `hot_standby`,
`wal_keep_size` - Patroni defaults it to 128MB and ignores the local file for it) + params
the local file does not define (`password_encryption`). `max_locks_per_transaction=1024`
(PG default 64 is NOT enough: TSDB reinit/provisioning drops+creates THOUSANDS of s*/t*
tables per DB; on 2026-08-26 prod hit `FATAL: out of shared memory / HINT: increase
max_locks_per_transaction` (SQLSTATE 53200) killing ALL concurrent queries when a reinit +
import_affs + hourly syncs overlapped; 1024*1024 slots costs only ~200MB shared memory). To START OVER from scratch: `helm delete -n devstats-test
devstats-test-patroni`, then delete the `pgdata-devstats-postgres-*` PVCs and the leftover
`devstats-postgres-config` endpoints+service in the namespace (they hold the Patroni DCS
state - a fresh cluster must not inherit it), wait until pods are gone.

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl config use-context test
# chart default is postgresNodes=6 - ALWAYS pass it explicitly (2 for test, 3 for prod)
S="$(skips_except Postgres),postgresNodes=${TEST_POSTGRES_NODES}"
S+=",postgresStorageSize=${TEST_POSTGRES_STORAGE},dbNodeSelector.node2=devstats-db-test"
S+=",requestsPostgresCPU=${TEST_PG_REQ_CPU},requestsPostgresMemory=${TEST_PG_REQ_MEM}"
S+=",limitsPostgresCPU=${TEST_PG_LIM_CPU},limitsPostgresMemory=${TEST_PG_LIM_MEM}"
# measured test reality (16 DBs / 170 GB, cii 85 GB, ~34 conns): sb 32GB, ecs 64GB, wm 512MB
S+=",${TEST_PG_TUNE}"
helm install devstats-test-patroni ./devstats-helm -n devstats-test --set "$S"
kubectl -n devstats-test get po -o wide -w | grep postgres   # Ctrl-C when 2/2 Running
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list   # 1 leader + 1 replica

# DCS-only params (see intro; all sizing already lives in the local patroni.yml via helm).
# retry_timeout=20 NOT 60: Patroni enforces loop_wait+2*retry_timeout<=ttl and otherwise
# SILENTLY degrades to loop_wait=1s (K8s-API hammering) - 15+2*20=55<=60 is valid:
PARAMS='{"loop_wait":15,"ttl":60,"retry_timeout":20,"primary_start_timeout":600,'
PARAMS+='"maximum_lag_on_failover":53687091200,'
PARAMS+='"postgresql":{"use_pg_rewind":true,"use_slots":true,"parameters":{'
PARAMS+='"max_connections":1024,"max_worker_processes":16,"max_wal_senders":10,'
PARAMS+='"max_locks_per_transaction":1024,'
PARAMS+='"max_replication_slots":10,"wal_level":"replica","wal_log_hints":"on",'
PARAMS+='"hot_standby":"on","wal_keep_size":"50GB","max_slot_wal_keep_size":"100GB",'
PARAMS+='"password_encryption":"scram-sha-256"}}}'
echo "$PARAMS" | jq . >/dev/null && echo "PARAMS JSON OK"
kubectl exec -n devstats-test devstats-postgres-0 -c devstats-postgres -- \
  curl -s -X PATCH -H 'Content-Type: application/json' -d "$PARAMS" http://localhost:8008/config
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl show-config
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list

# RUNTIME verification gate - SHOW on EVERY member must match the intended values below
# (show-config is NOT enough: it prints the DCS, which the local file can override):
for m in 0 1; do echo "== member $m =="; kubectl exec -n devstats-test devstats-postgres-$m -c devstats-postgres -- \
  psql -U postgres -tAc "show shared_buffers; show work_mem; show effective_cache_size; show temp_file_limit; show wal_keep_size; show maintenance_work_mem; show max_wal_size; show min_wal_size"; done
# expect per member: 32GB 512MB 64GB 50GB 50GB 1GB 32GB 2GB
for m in 0 1; do echo "== member $m =="; kubectl exec -n devstats-test devstats-postgres-$m -c devstats-postgres -- \
  psql -U postgres -tAc "show max_connections; show max_worker_processes; show max_parallel_workers; show max_parallel_workers_per_gather" \
  -c "show autovacuum_vacuum_cost_limit; show autovacuum_vacuum_scale_factor; show autovacuum_analyze_scale_factor; show password_encryption; show max_locks_per_transaction"; done
# expect per member: 1024 16 8 4 then 200 0.1 0.05 scram-sha-256 1024

# failover sanity (empty cluster - free to test), then put the leader back on postgres-0:
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl switchover devstats-postgres --force
# WAIT for postgres-0 to REJOIN as a streaming replica before switching back - right after
# the switchover it shows State=stopped and the switchback fails with "no good candidates":
until kubectl exec -n devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list 2>/dev/null | grep 'devstats-postgres-0' | grep -q streaming; do sleep 5; done
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list    # new leader, old rejoined+streaming
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl switchover devstats-postgres --candidate devstats-postgres-0 --force
kubectl exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl list    # leader = devstats-postgres-0
```

### 1.21 Patroni PROD (3 nodes, empty) + tune + restart + failover check [master]

Same local-file-beats-DCS rule as 1.20: sizing via `${PROD_PG_TUNE}` helm values, DCS PATCH
only for Patroni-controlled params + `password_encryption` + `checkpoint_timeout` (not in
the local file, so the DCS value is effective). Sized for 256 GB nodes + MEASURED prod
(245 DBs / 1793 GB, allprj 521 GB, gha 214 GB): sb 64GB / ecs 128GB / wm 1GB / temp 100GB,
autovacuum much more aggressive than live OCI (1 worker @ cost_limit 100 cannot keep up).

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl config use-context prod
# chart default is postgresNodes=6 - ALWAYS pass it explicitly (3 for prod, 2 for test)
S="namespace=devstats-prod,$(skips_except Postgres),postgresNodes=${PROD_POSTGRES_NODES}"
S+=",postgresStorageSize=${PROD_POSTGRES_STORAGE},dbNodeSelector.node2=devstats-db-prod"
S+=",requestsPostgresCPU=${PROD_PG_REQ_CPU},requestsPostgresMemory=${PROD_PG_REQ_MEM}"
S+=",limitsPostgresCPU=${PROD_PG_LIM_CPU},limitsPostgresMemory=${PROD_PG_LIM_MEM}"
S+=",${PROD_PG_TUNE}"
echo $S
helm install devstats-prod-patroni ./devstats-helm -n devstats-prod --set "$S"
kubectl -n devstats-prod get po -o wide -w | grep postgres   # Ctrl-C when 3/3 Running
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list   # 1 leader + 2 replicas

PARAMS='{"loop_wait":15,"ttl":60,"retry_timeout":20,"primary_start_timeout":600,'
PARAMS+='"maximum_lag_on_failover":53687091200,'
PARAMS+='"postgresql":{"use_pg_rewind":true,"use_slots":true,"parameters":{'
PARAMS+='"max_connections":1024,"max_worker_processes":32,"max_wal_senders":10,'
PARAMS+='"max_locks_per_transaction":1024,'
PARAMS+='"max_replication_slots":10,"wal_level":"replica","wal_log_hints":"on","hot_standby":"on",'
PARAMS+='"wal_keep_size":"100GB","max_slot_wal_keep_size":"300GB",'
PARAMS+='"password_encryption":"scram-sha-256","checkpoint_timeout":"15min"}}}'
echo $PARAMS
echo "$PARAMS" | jq . >/dev/null && echo "PARAMS JSON OK"
kubectl exec -n devstats-prod devstats-postgres-0 -c devstats-postgres -- \
  curl -s -X PATCH -H 'Content-Type: application/json' -d "$PARAMS" http://localhost:8008/config
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl show-config
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list

# RUNTIME verification gate - SHOW on EVERY member (0 1 2) must match:
for m in 0 1 2; do echo "== member $m =="; kubectl exec -n devstats-prod devstats-postgres-$m -c devstats-postgres -- \
  psql -U postgres -tAc "show shared_buffers; show work_mem; show effective_cache_size; show temp_file_limit; show wal_keep_size; show maintenance_work_mem; show max_wal_size; show min_wal_size; show checkpoint_timeout"; done
# expect per member: 64GB 1GB 128GB 100GB 100GB 4GB 128GB 4GB 15min
for m in 0 1 2; do echo "== member $m =="; kubectl exec -n devstats-prod devstats-postgres-$m -c devstats-postgres -- \
  psql -U postgres -tAc "show max_connections; show max_worker_processes; show max_parallel_workers; show max_parallel_workers_per_gather" \
  -c "show autovacuum_max_workers; show autovacuum_naptime; show autovacuum_vacuum_cost_limit; show autovacuum_vacuum_scale_factor" \
  -c "show autovacuum_analyze_scale_factor; show password_encryption; show max_locks_per_transaction"; done
# expect per member: 1024 32 32 16 then 4 30s 1000 0.05 then 0.02 scram-sha-256 1024

# failover sanity, then put the leader back on postgres-0:
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl switchover devstats-postgres --force
# WAIT for postgres-0 to rejoin as streaming (else switchback fails: "no good candidates"):
until kubectl exec -n devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list 2>/dev/null | grep 'devstats-postgres-0' | grep -q streaming; do sleep 5; done
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl switchover devstats-postgres --candidate devstats-postgres-0 --force
kubectl exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl list    # leader = devstats-postgres-0
echo 'done'
```

### 1.22 Log/WAL retention caps - nothing may grow unbounded [master]

Already-bounded by design (verify, don't change): container logs incl. PostgreSQL/Patroni
(image logs to stderr, `logging_collector=off` -> kubelet caps at 10Mi x 5 files per
container), etcd (2GB backend quota, lives on /data), `temp_file_limit` (§1.20/§1.21),
`archive_mode=off` (no WAL archive pile-up). The DCS PATCHes above already include
`max_slot_wal_keep_size` (100GB test / 300GB prod - prod bootstraps directly at its FINAL
value; §3.8's pre-flight re-applies the same 300GB as an idempotent verify/no-op and it is
never lowered afterwards) - WITHOUT it a dead replica pins WAL
via its replication slot (`use_slots=true`) until the LEADER's disk fills = full outage;
PG default is -1 = unlimited. Reloadable, no restart. What remains is OS log caps, on ALL 8:

```bash
cd /root/devstats-helm && source linodes.env.secret
for ip in $ALL_VPC_IPS; do ssh root@$ip '
mkdir -p /etc/systemd/journald.conf.d
printf "[Journal]\nSystemMaxUse=2G\nRuntimeMaxUse=512M\nMaxRetentionSec=2week\nSystemKeepFree=5%%\n" > /etc/systemd/journald.conf.d/00-devstats.conf
systemctl restart systemd-journald
sed -i "s/^\tweekly$/\tdaily/; s/^\trotate 4$/\trotate 7/" /etc/logrotate.d/rsyslog
grep -q maxsize /etc/logrotate.d/rsyslog || sed -i "/^\tdaily$/a\\\tmaxsize 500M" /etc/logrotate.d/rsyslog
echo "$(hostname): $(grep -cE "daily|rotate 7|maxsize 500M" /etc/logrotate.d/rsyslog)/3 journald=$(systemctl is-active systemd-journald)"
'; done
# expect from every node: 3/3 journald=active
# verify slot cap runtime (every member, both envs):
for ns in devstats-test devstats-prod; do kubectl exec -n $ns devstats-postgres-0 -c devstats-postgres -- psql -U postgres -tAc "show max_slot_wal_keep_size"; done
# expect: 100GB then 200GB
```

**Part 1 done** - full platform is up (nodes, k8s, storage, ingress+NB, certs pending DNS,
both Patroni clusters tuned and failover-tested, all log/WAL growth capped). No DevStats
data anywhere yet.

---

## Part 2 - fresh backups on the CURRENT OCI infra (Monday morning)

**Execution order - TEST-FIRST.** Drive the TEST env end-to-end before touching prod data:
1. §2.1 TEST block only (DONE 2026-08-24: all 12 projects `full` + affiliations; azf
   re-dumped from primary and `pg_restore -l` verified) → §2.3 test block → §2.4 test
   block (+ §2.2 test dry-run if you want to rehearse the debug-pod flow).
2. Immediately continue to the TEST restore track: §3.1 → §3.3 → §3.4(test) → §3.5 →
   §3.6 → §3.7. Test hourly syncs then run on Linode and keep it current on their own
   (OCI test keeps syncing too - both replay GH Archive independently, no conflict,
   DNS still points at OCI). Shake out every restore/scheduling/chart problem here.
3. Only after test looks healthy for ~a day: §2.1 PROD block (dumps stay maximally
   fresh), §2.2, §2.3, §2.4, then the PROD restore track §3.2 / §3.4(prod) / §3.8-§3.11.

This also shrinks the freshness gap per env - see §3.0 for why restore age is safe anyway.

### 2.1 Trigger the regular backups now [OCI]

Two pitfalls make the naive `create job --from=cronjob` insufficient:
- `NOAGE` unset - `backups.sh` SKIPS every DB whose dump is younger than 4-11 days
  (randomized); right after a scheduled run (`45 2 10,20 * *`) it mostly no-ops.
- the backups pod dumps from the RO service (replica) - long `pg_dump` COPYs get killed
  by WAL replay (`canceling statement due to conflict with recovery`, 30s default) when
  an hourly sync's lock replays; worse, a failed dump leaves a TRUNCATED `<db>.dump` on
  the PV, silently corrupting the previous good backup. Fix both: `NOAGE=1` + dump from
  the PRIMARY (`devstats-postgres` RW service; conflicts impossible there):

```bash
J='{apiVersion:"batch/v1",kind:"Job",metadata:{name:"devstats-backups-manual"},spec:.spec.jobTemplate.spec}'
J+=' | .spec.template.spec.containers[0].env |= map(if .name=="NOAGE" then .value="1"'
J+=' elif .name=="PG_HOST" then {name:"PG_HOST",value:"devstats-postgres"} else . end)'
kubectl config use-context prod
kubectl -n devstats-prod delete job devstats-backups-manual --ignore-not-found
kubectl -n devstats-prod get cronjob devstats-backups -o json | jq "$J" | kubectl -n devstats-prod create -f -
kubectl -n devstats-prod wait --for=condition=ready pod -l job-name=devstats-backups-manual --timeout=180s
kubectl -n devstats-prod logs -f job/devstats-backups-manual     # ~4.5-6h - leave running
kubectl config use-context test
kubectl -n devstats-test delete job devstats-backups-manual --ignore-not-found
kubectl -n devstats-test get cronjob devstats-backups -o json | jq "$J" | kubectl -n devstats-test create -f -
kubectl -n devstats-test wait --for=condition=ready pod -l job-name=devstats-backups-manual --timeout=180s
kubectl -n devstats-test logs -f job/devstats-backups-manual     # ~30-60 min
# PASS signal: "Force backup <all dbs>" header, then "<date> full <db>" per DB, ending
# "N full backups OK" and "All artificial events backups OK". On prod, "does not exist"
# failures for ~22 ARCHIVED projects (brigade, smi, keptn, ... xline) are expected+benign.
# Any OTHER "<db> full backup failed" line = that db's .dump on the PV is now TRUNCATED -
# re-dump just the failed ones (space-separated list) with an extra ONLY override:
#   J2="$J"' | .spec.template.spec.containers[0].env |= map(if .name=="ONLY" then .value="<failed dbs>" else . end)'
#   ... delete job, then create with jq "$J2" as above, watch for "full <db>" + OK.
```

Verify EVERY fresh dump is a readable archive before relying on it (TOC read; catches
truncation; run per env - context test shown, repeat with prod):

```bash
POD=$(kubectl -n devstats-test get po -o name | grep backups-manual | head -1 | cut -d/ -f2)
kubectl -n devstats-test exec $POD -- sh -c 'cd /root; for f in *.dump; do pg_restore -l "$f" >/dev/null 2>&1 && echo "OK $f" || echo "CORRUPT $f"; done'
# every line must be OK; CORRUPT for an archived project's ancient dump is ignorable,
# CORRUPT for a live project = re-dump it via the ONLY override above.
```

Optional (recommended during the prod run): suspend hourly syncs so the primary is quiet
while dumping - remember to RESUME after. Snapshot suspend-state FIRST (§2.4):

```bash
kubectl config use-context prod
for cj in $(kubectl -n devstats-prod get cj -o name | grep hourly-sync); do kubectl -n devstats-prod patch $cj -p '{"spec":{"suspend":true}}'; done
# ... run the backup job ...
for cj in $(kubectl -n devstats-prod get cj -o name | grep hourly-sync); do kubectl -n devstats-prod patch $cj -p '{"spec":{"suspend":false}}'; done
```

### 2.2 Refresh artificial-events backups (debug pod on OCI prod) [OCI] - OPTIONAL

**Skip if §2.1 prod completed cleanly**: `backups.sh` ALWAYS refreshes every project's
artificial archive (`<db>.tar.xz`) regardless of NOAGE - look for per-DB
`Creating backup archive <db>.tar.xz` lines + the final `All artificial events backups OK`.
That is also why there is NO test twin of this step: the §2.1 TEST run already did it
(verified 2026-08-24). This recipe stays here as the standalone way to refresh artificial
archives WITHOUT a multi-hour full backups run - reused at §4.2.

OPTIONAL dry-run on TEST first (validates the debug-pod flow cheaply before prod):

```bash
kubectl config use-context test
S='skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1'
S+=',skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1'
S+=',skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1'
S+=',bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s}'
S+=',bootstrapMountBackups=1'
helm install devstats-test-debug ./devstats-helm -n devstats-test --set "$S"
kubectl -n devstats-test exec -it debug -- bash -c "ONLY=\"\$(cat ./devel/all_test_dbs.txt)\" FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh"
helm delete -n devstats-test devstats-test-debug
# verify the artificial archives (<db>.tar.xz) got refreshed - timestamps = just now
# (DONE 2026-08-24 05:27-05:29; ignore the stale 308-byte allprj.tar.xz - prod stub):
curl -s https://teststats.cncf.io/backups/ | grep -E 'href="(azf|cii|cncf|fn|godotengine|linux|opencontainers|openfaas|openwhisk|riff|sam|zephyr)\.tar\.xz"'
```

PROD version (same skips + namespace/limits overrides):

```bash
kubectl config use-context prod
S='namespace=devstats-prod,skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1'
S+=',skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1'
S+=',skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1'
S+=',bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s}'
S+=',bootstrapMountBackups=1,limitsBackupsCPU=4000m,limitsBackupsMemory=64Gi'
helm install devstats-prod-debug ./devstats-helm -n devstats-prod --set "$S"
kubectl -n devstats-prod exec -it debug -- bash
# inside the pod (ONLY must be EXPLICIT - the pod defaults to the TEST db list):
ONLY="$(cat ./devel/all_prod_dbs.txt)" FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh
exit
helm delete -n devstats-prod devstats-prod-debug
# verify prod artificial archives got refreshed (spot-check a few of the ~130):
curl -s https://devstats.cncf.io/backups/ | grep -E 'href="(gha|allprj|prometheus|opentelemetry|argo)\.tar\.xz"'
```

### 2.3 Verify dumps are fresh [workstation]

nginx autoindex puts the timestamp AFTER `</a>`, so grep whole lines (not `[^<]*`).
PASS = every listed `.dump` shows today's date:

```bash
# TEST (run now, after the 2.1 test block):
curl -s https://teststats.cncf.io/backups/ | grep -E 'href="(azf|cii|cncf|fn|godotengine|linux|opencontainers|openfaas|openwhisk|riff|sam|zephyr|affiliations)\.dump"'
# ... and the artificial-events archives (refreshed by the same 2.1 run):
curl -s https://teststats.cncf.io/backups/ | grep -E 'href="(azf|cii|cncf|fn|godotengine|linux|opencontainers|openfaas|openwhisk|riff|sam|zephyr)\.tar\.xz"'
# PROD (run later, after the 2.1 prod block):
curl -s https://devstats.cncf.io/backups/  | grep -E 'href="(gha|allprj|affiliations)\.dump"'
curl -s https://devstats.cncf.io/backups/  | grep -E 'href="(gha|allprj|prometheus|opentelemetry|argo)\.tar\.xz"'
```

### 2.4 Snapshot OCI cronjob suspend-state (needed at cutover) [OCI]

OCI is ONE cluster - both kubectl contexts see all namespaces, so a single `-A` snapshot
covers test AND prod (DONE 2026-08-24, live-verified: 512 cronjobs - 486 devstats-prod +
26 devstats-test - and ZERO suspended; copy saved to `~ubuntu/oci-cron-suspends.secret`
on the OCI master). Re-run any time; §4.7 re-applies intentional suspends after cutover:

```bash
kubectl get cj -A -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name) suspend=\(.spec.suspend)"' > oci-cron-suspends.secret
wc -l oci-cron-suspends.secret    # 512 as of 2026-08-24; keep this file
grep 'suspend=true' oci-cron-suspends.secret || echo "none suspended"
```

Do NOT suspend anything on OCI yet - it keeps syncing until Part 4.

---

## Part 3 - DevStats on Linode + restore everything (Mon → Fri; restores run unattended)

All of Part 3 runs **[master]** in `/root/devstats-helm` with `source linodes.env.secret`,
except the Grafana tar (3.3, workstation). Restores download dumps from
`https://devstats.cncf.io/backups/` / `https://teststats.cncf.io/backups/` - these still
resolve to OCI until Part 4, which is exactly what we want. ALL restores must be finished
BEFORE the DNS switch.

Grafana pods (the most numerous pod type: 242 on prod, 12 on test) are auto-sized by the
chart, minimized to MEASURED live usage (2026-08-21 samples: 228Mi-1.35Gi RSS, ~idle CPU;
their queries only load data from Postgres): `requestsGrafanas* 50m/256Mi`,
`limitsGrafanas* 1000m/2Gi` - already the defaults in this repo's values.yaml, nothing
to pass; if a big-project grafana ever OOMs, raise per release with
`--set limitsGrafanasMemory=3Gi`.

### 3.0 Freshness model - why "data added on OCI after the backup" is never lost

No OCI→Linode delta copy is needed; the Postgres DBs are CACHES, not sources of truth -
every row recomputes from GH Archive (immutable public hourly files), the GitHub API and
git clones, all equally readable from Linode:

- **Events** (the core): `restore.sh` ends with `gha2db_sync`, which resumes from the max
  event time IN THE RESTORED DB and replays GH Archive up to now; hourly syncs continue
  from there. Zero loss regardless of how old the dump is.
- **API-only mutations** (labels/milestones/issue-PR state edited without generating
  events, stars/forks): normally `ghapi2db` (invoked by every sync) only re-checks the
  last `GHA2DB_RECENT_RANGE` = 8 hours. The `restore_test`/`restore_prod` helpers COMPUTE
  the window per restore: dump age (Last-Modified) + 2 days margin (`catchup_range`,
  fallback `$API_CATCHUP_RANGE`='12 days') so the catch-up sync inside each provision
  re-fetches exactly the backup→restore window straight from
  GitHub (same for orphan commits + recently-modified repos ranges). This is the
  upstream-documented catch-up knob (values.yaml ships `# ghapiRecentRange: '220 days'`).
  Hourly-sync crons do NOT get this value - they keep the 8h default (verified live).
- **Affiliations / artificial events**: restored explicitly (§3.4, §3.6, §3.10).

Per-project freshness gate after its provision pod completes (expect ≤ ~2-3 h behind now):

```bash
kubectl -n devstats-test exec devstats-postgres-0 -c devstats-postgres -- psql -U postgres <db> -tAc 'select max(created_at) from gha_events'
# (same gate for PROD restores: -n devstats-prod)
```

### 3.1 TEST env: statics, ingress, bootstrap, debug pod

```bash
cd /root/devstats-helm && source linodes.env.secret
kubectl config use-context test
helm install devstats-test-statics ./devstats-helm -n devstats-test --set "$(skips_except Static),projectsOverride=${TEST_PROJECTS},indexStaticsFrom=0,indexStaticsTo=1"
helm install devstats-test-ingress ./devstats-helm -n devstats-test --set "$(skips_except Ingress),indexDomainsFrom=0,indexDomainsTo=1,projectsOverride=${TEST_PROJECTS},ingressClass=nginx-test,sslEnv=test"
helm install devstats-test-bootstrap ./devstats-helm -n devstats-test --set "$(skips_except Bootstrap),projectsOverride=${TEST_PROJECTS}"
kubectl -n devstats-test get po -w    # Ctrl-C when bootstrap Completed and statics Running
helm install devstats-test-debug ./devstats-helm -n devstats-test --set "$(skips_except Bootstrap),bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1"
kubectl -n devstats-test get ingress    # hosts present, class nginx-test (certs stay Pending until DNS - OK)
```

### 3.2 PROD env: statics, ingress, bootstrap, debug pod

```bash
kubectl config use-context prod
helm install devstats-prod-statics ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except Static),indexStaticsFrom=1"
helm install devstats-prod-ingress ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except Ingress),skipAliases=1,indexDomainsFrom=1,ingressClass=nginx-prod,sslEnv=prod"
helm install devstats-prod-bootstrap ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except Bootstrap)"
kubectl -n devstats-prod get po -w    # Ctrl-C when bootstrap Completed
helm install devstats-prod-debug ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except Bootstrap),bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1"
```

### 3.3 Grafana artifacts tar [workstation - needs cncf/devstats + cncf/devstatscode checkouts]

```bash
cd ~/dev/go/src/github.com/cncf/devstats        # adjust to your checkout
# canonical script (does the cp of sqlitedb/runq/replacer + the exact file list itself;
# equivalent to ADDING_NEW_PROJECTS.md "Update shared Grafana data"):
# (needs the three binaries built in ../devstatscode - run `make` there if missing)
./devel/create_grafana_shared_data.sh           # writes ./devstats-grafana.tar
scp devstats-grafana.tar root@$MASTER_IP:/root/
```

Unpack ONCE PER NAMESPACE **[master]** - all pods in a namespace (both static deployments
AND every grafana pod, which mounts it at `/root`) share the same `devstats-backups` PVC,
so unpacking in ANY static pod of that namespace is enough - but grep the env-specific
deployment (`devstats-static-test`/`devstats-static-prod`) to keep the choice deterministic
(prod also runs `-cdf`/`-graphql`/`-default` statics).
TEST-FIRST: while only the test track is deployed, run the loop with `for ctx in test;` -
re-run with `for ctx in prod;` right after §3.2:

```bash
for ctx in test prod; do
  kubectl config use-context "$ctx"; ns="devstats-$ctx"
  SPOD="$(kubectl -n "$ns" get po -o name | grep "devstats-static-$ctx-" | head -1 | cut -d/ -f2)"
  kubectl -n "$ns" cp /root/devstats-grafana.tar "$SPOD":/usr/share/nginx/html/backups/devstats-grafana.tar
  kubectl -n "$ns" exec "$SPOD" -- sh -c 'cd /usr/share/nginx/html/backups && rm -rf grafana && tar xf devstats-grafana.tar && rm devstats-grafana.tar && chmod -R ugo+rwx grafana'
  kubectl -n "$ns" exec "$SPOD" -- ls /usr/share/nginx/html/backups/grafana
done
```

### 3.4 Restore `affiliations` DB manually (BOTH envs; it is NOT a chart project)

TEST-FIRST: run the `test` block now; run the `prod` block when starting the prod track
(§3.8) so its copy is fresh (it is re-restored at §4.3 delta anyway).

```bash
# check the exact dump name first: curl -s https://devstats.cncf.io/backups/ | grep -o 'affiliations[^<]*dump'
kubectl config use-context prod
kubectl -n devstats-prod exec -it devstats-postgres-0 -c devstats-postgres -- bash -c \
  'cd /tmp && curl -fsSL -o aff.dump https://devstats.cncf.io/backups/affiliations.dump && \
   dropdb -U postgres --if-exists affiliations && createdb -U postgres affiliations && \
   pg_restore -U postgres -j 4 -d affiliations aff.dump && rm aff.dump && \
   psql -U postgres affiliations -c "\dt+" | head'
kubectl config use-context test
kubectl -n devstats-test exec -it devstats-postgres-0 -c devstats-postgres -- bash -c \
  'cd /tmp && curl -fsSL -o aff.dump https://teststats.cncf.io/backups/affiliations.dump && \
   dropdb -U postgres --if-exists affiliations && createdb -U postgres affiliations && \
   pg_restore -U postgres -j 4 -d affiliations aff.dump && rm aff.dump && \
   psql -U postgres affiliations -c "\dt+" | head'
```

### 3.5 TEST restores - the 12 live test projects (`restore_test` from linodes.env.secret)

Each call helm-installs a provision release that drops/recreates the DB, downloads the dump
from teststats.cncf.io and pg_restores it, then keeps hourly syncs running via crons.

```bash
kubectl config use-context test
restore_test cncf 49 50                         # DONE 2026-08-24 (validated: sync success, FDW + hll OK)
# smallest dump first -> catch issues fast, then progressively bigger (sizes = dump bytes):
restore_test fn 62 63                           #   34 MB
restore_test openwhisk 63 64                    #   40 MB
restore_test sam 59 60                          #   47 MB
restore_test riff 61 62                         #   68 MB
restore_test openfaas 64 65                     #  110 MB
restore_test opencontainers 50 51               #  140 MB
restore_test linux 54 55                        #  356 MB
restore_test azf 60 61                          #  510 MB
restore_test zephyr 53 54                       #  1.5 GB
restore_test godotengine 97 98                  #  1.8 GB
restore_test cii 67 68                          #  5.0 GB
watch 'kubectl -n devstats-test get po | grep provision'   # Ctrl-C when all Completed
kubectl -n devstats-test delete po --field-selector=status.phase=Succeeded
```

NOTE: each `restore_test` returns immediately (helm install is async - the provision pod
does the work), so you CAN fire several in parallel; `wait_provisions 6 devstats-test` throttles at 6.
Completed pods are bare Pods (kind: Pod, no Job/TTL) - nothing auto-cleans them; they cost
zero resources, the `kubectl delete po --field-selector=...` line below removes them.

DONE 2026-08-24: `allprj` on TEST is NOT a live project (no crons/flags/syncs on OCI test) -
it is a 19 MB placeholder used only as the `merge_dbs` output target (ADDING_NEW_PROJECTS.md).
Copied in full OCI-test -> Linode-test (owner postgres, default ACL, single transaction):
```bash
kubectl --context prod -n devstats-test exec devstats-postgres-0 -c devstats-postgres -- pg_dump -U postgres -Fc allprj > /tmp/allprj-test.dump
kubectl --context linode-prod -n devstats-test exec devstats-postgres-0 -c devstats-postgres -- psql -U postgres -c 'create database allprj'
kubectl --context linode-prod -n devstats-test exec -i devstats-postgres-0 -c devstats-postgres -- pg_restore -U postgres -d allprj -1 < /tmp/allprj-test.dump
```
Verified: gha_* metadata fingerprint identical both sides; 114 tables, sannotations_shared=428 rows, 19 MB.
NOTE: `git-clone failed: ... exit status 128` / `repo not cloned` warnings in provision
logs are benign (archived/renamed/deleted repos - same on OCI). PASS per project =
`Sync success` + `database '<db>' marked as provisioned` at the end of the provision log.

INCIDENT 2026-08-24 (fixed same day; 3rd occurrence of the provision-vs-cron race): the
two biggest test DBs (cii 5G, godotengine 1.8G) lost `trepo_groups`+`tcompanies` - their
6-hourly crons (created ENABLED by restore_test, dumps carry the `provisioned` flag)
fired while the provision gha2db_sync was still computing full-history metrics; the
concurrent syncs interleaved a tags drop/create cycle. Symptom: `42P01 undefined_table`
retry loops. Fix: `pg_dump -t trepo_groups -t tcompanies` from OCI test -> psql into the
Linode DBs; verified t-table row counts match OCI 12/12 projects + next cron `Sync success`.
PREVENTION on any future restore wave: suspend the project's sync cron until its
provision pod completes (mirrors the §4.3 prod delta-restore guard).

PASS: extensions restored per project DB (image devstats-patroni-18-hll has all three;
restore.sh creates pgcrypto, pg_restore brings hll+postgres_fdw back from the dump - OCI parity).
Validated live on cncf 2026-08-24: FDW server -> local socket /var/run/postgresql,
count(*) on 1.98M-row foreign gha_actors = 154 ms, gha_admin mapping works:

```bash
kubectl -n devstats-test exec devstats-postgres-0 -c devstats-postgres -- \
  psql -U postgres -d cncf -At -c 'select extname from pg_extension'
# expect: plpgsql, pgcrypto, postgres_fdw, hll (affiliations having only plpgsql is correct)
```

### 3.6 TEST artificial rows(OPTIONAL) + affiliations import + API + backups(suspended)

NOTE: none of 3.6 gates the §3.7 smoke (that only needs grafana+ingress, already live).
But affs-import + API ARE required before the Part-4 cutover - do them now anyway.

```bash
# OPTIONAL - artificial rows: REDUNDANT for our full pg_restore flow (dumps already
# contain them - live-verified: gha_events id<0 fn=11, cncf=806; re-running just hits
# benign PK conflicts). Only needed for from-scratch gha2db provisions. Kept for reference:
# kubectl exec -it debug -- bash -c "ONLY='azf cii cncf fn godotengine linux opencontainers openfaas openwhisk riff sam zephyr' RESTORE_FROM='https://teststats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"

# REQUIRED - global gitdm affs-import cron (live check: only per-project
# devstats-affiliations-<proj> crons exist; this global import cron does not yet):
helm install devstats-test-affs-import ./devstats-helm -n devstats-test --set "$(skips_except),skipAffiliationsImport=,affiliationsDB=affiliations,prodServer=,testServer=1,backupsCronProd=45 2 16\,28 * *"
# REQUIRED (before Part 4, not for §3.7) - API deployment (live check: absent):
helm install devstats-test-api ./devstats-helm -n devstats-test --set "$(skips_except API),projectsOverride=${TEST_PROJECTS}"
# REQUIRED - install backups cron suspended; UNSUSPENDED 2026-08-24 right after the test
# track finished (user decision, ahead of the original §5.1b post-cutover plan); the OCI
# test backups cron got suspended at the same time - do NOT mirror that suspend in §4.7.
# Placement is fine: test backups NFS on devstats-test-db-01 is allowed - prod-db nodes
# are the only ones barred from backups/git-clones/anything-similarly-growable (§1.12;
# prod backups NFS lives on compute-02).
helm install devstats-test-backups ./devstats-helm -n devstats-test --set "$(skips_except Backups)"
kubectl -n devstats-test patch cronjob devstats-backups -p '{"spec":{"suspend":true}}'

# VERIFY all three landed (everything -n scoped, context-independent) - expect:
# cronjob devstats-affiliations-import + suspended devstats-backups + api 1/1 Running:
kubectl -n devstats-test get cj devstats-affiliations-import
kubectl -n devstats-test get cj devstats-backups -o jsonpath='{.spec.suspend}{"\n"}'   # true
kubectl -n devstats-test get deploy devstats-api                                       # READY 1/1
# (validated live 2026-08-24: all three present; helm -n flag makes context irrelevant)
```

### 3.7 TEST smoke (via NodeBalancer, fake Host - DNS still points to OCI)

```bash
curl -sk -H 'Host: k8s.teststats.cncf.io' "https://$TEST_NB_IP/" | grep -i grafana && echo TEST-OK
curl -s  -H 'Host: teststats.cncf.io'     "http://$TEST_NB_IP/"  | head -5
```

### 3.7b TEST cron rehearsal - manual-fire one of EACH future recurring job (medium project)

DONE 2026-08-24 (godotengine; ran as detached driver /root/rehearsal-test.sh on compute-01,
log: /root/rehearsal-test.log). Proves every job type that will ever fire from a cron
completes on Linode BEFORE relying on schedules: sync (4x/day), backups (monthly),
affiliations-import (weekly-ish) and per-project monthly affiliations. Run sequentially -
each waits for the previous (they share DB flags/locks like real cron overlaps would):

```bash
kubectl config use-context test
# 1/4 - hourly/4x-daily sync for a medium project:
kubectl -n devstats-test create job manual-sync-godotengine --from=cronjob/devstats-godotengine
kubectl -n devstats-test wait --for=condition=complete job/manual-sync-godotengine --timeout=45m
kubectl -n devstats-test logs job/manual-sync-godotengine --tail=4

# 2/4 - backups limited to that one project (ONLY=<proj>, NOAGE=1 skips dump aging):
J='{apiVersion:"batch/v1",kind:"Job",metadata:{name:"manual-backup-godotengine"},spec:.spec.jobTemplate.spec}'
J+=' | .spec.template.spec.containers[0].env |= map(if .name=="ONLY" then .value="godotengine"'
J+=' elif .name=="NOAGE" then .value="1" else . end)'
kubectl -n devstats-test get cronjob devstats-backups -o json | jq "$J" | kubectl -n devstats-test create -f -
kubectl -n devstats-test wait --for=condition=complete job/manual-backup-godotengine --timeout=30m

# 3/4 - global affiliations import (github_users.json refresh):
kubectl -n devstats-test create job manual-affs-import --from=cronjob/devstats-affiliations-import
kubectl -n devstats-test wait --for=condition=complete job/manual-affs-import --timeout=90m

# 4/4 - monthly per-project affiliations sync:
kubectl -n devstats-test create job manual-affs-godotengine --from=cronjob/devstats-affiliations-godotengine
kubectl -n devstats-test wait --for=condition=complete job/manual-affs-godotengine --timeout=120m

# verify all 4 Complete, check the dump landed on the backups PV (statics nginx serves it), clean up:
kubectl -n devstats-test get jobs | grep manual-
kubectl -n devstats-test exec deploy/devstats-static-default -- ls -l /usr/share/nginx/html/backups | grep godotengine
kubectl -n devstats-test delete job manual-sync-godotengine manual-backup-godotengine manual-affs-import manual-affs-godotengine
```

Repeat the same pattern on PROD (ns devstats-prod, e.g. proj=sam/karmada-sized medium) after
§3.10 installs prod crons - BEFORE trusting the first scheduled runs on cutover day.

### 3.8 PROD restores - kick off the two LONG poles first (many hours each)

Deliberately OPPOSITE order to §3.5: the test track (smallest-first) already shook out
process issues with fast feedback; prod starts with the two HUGE DBs so any scale-related
problems (disk, WAL, restore duration) surface first while the rest run in parallel.

PRE-FLIGHT - raise the replication-slot WAL cap first. Test observation (§3.5): 5 parallel
restores of ~10 GB dumps pushed replica lag to 15 GB against the 100 GB
max_slot_wal_keep_size cap; slot stayed `reserved` and lag drained to 0 in minutes. Prod
scales that up: a 120 GB-dump restore streams WAL for hours WHILE already-restored
projects run their live 4x/day sync crons in parallel (same overlap seen on test) - and
replica replay is single-threaded. Slot invalidation would force a full replica rebuild.
Disk is multi-TB, so buy headroom (DCS-level param per §1.20 - patch, don't edit helm).
NOTE: §1.20 now bootstraps prod at 300GB directly (its final value), so on a fresh install
this is an idempotent no-op - run it anyway as the pre-§3.8 verification gate:

```bash
kubectl config use-context prod
kubectl -n devstats-prod exec devstats-postgres-0 -c devstats-postgres -- patronictl edit-config --force -s postgresql.parameters.max_slot_wal_keep_size=300GB
kubectl -n devstats-prod exec devstats-postgres-0 -c devstats-postgres -- psql -U postgres -Atc 'show max_slot_wal_keep_size'   # 300GB (no restart needed)
# DONE 2026-08-24: applied+verified live (leader+2 replicas streaming, lag 0; test stays 100GB).
# keep 300GB permanently: Part-4 delta re-restores overlap live crons the same way.
# INTENTIONALLY NEVER REVERTED (Part 5 does not touch it): the cap costs nothing in
# steady state (WAL is only retained while a replica lags/is down), it is ~6% of the
# 4.8TB volume worst-case, and a higher cap lets a dead replica catch up instead of
# invalidating the slot and forcing a full multi-TB replica rebuild.
```

```bash
kubectl config use-context prod
restore_prod kubernetes 0 1                     # biggest DB (~120 GB dump)
restore_prod all 38 39                          # allprj - second biggest
```

Leave them running and start the rest immediately - `wait_provisions 8 devstats-prod` caps parallelism
at 8 concurrent provisions (the two above included) so Patroni is never overwhelmed.

### 3.8b PROD smoke set - the 6 SMALLEST projects in parallel with the long poles

While the two giants download/restore, fire the 6 tiniest dumps (<0.2 MB each, seconds to
restore) - this exercises the FULL provision path (helm release, DB create, download,
pg_restore, grafana pod, crons) end-to-end 6 more times and surfaces any systemic issue
before the bulk §3.9 batch. Total = 8 concurrent provisions, the `wait_provisions 8` cap:

```bash
kubectl config use-context prod
restore_prod carina 175 176                     #  36 KB
restore_prod pyrsia 184 185                     #  47 KB
restore_prod tratteria 239 240                  #  67 KB
restore_prod sermant 236 237                    #  78 KB
restore_prod container2wasm 243 244             # 100 KB
restore_prod opcr 177 178                       # 105 KB
watch 'kubectl -n devstats-prod get po | grep provision'   # 6 small ones Complete in ~1-2 min
# PASS per project = provision log ends with: Sync success + database '<db>' marked as provisioned
for p in carina pyrsia tratteria sermant container2wasm opcr; do
  kubectl -n devstats-prod logs devstats-provision-$p --tail=3 | grep -E 'Sync success|marked as provisioned' && echo "$p OK"
done
kubectl -n devstats-prod delete po --field-selector=status.phase=Succeeded 2>/dev/null
```

### 3.9 PROD restores - the remaining 234 projects in 39 packs of <=6 + 4 singles

LIST PROVENANCE (regenerated 2026-08-24): values.yaml projects (283) filtered to live OCI
prod DBs = 242 restores (234 below + the 2 long poles in 3.8 + the 6 smallest in 3.8b). Excluded = archived
projects whose DBs were already dropped on OCI (brigade, smi, keptn, openservicemesh,
pravega, cnigenie, openmetrics->merged into prometheus, ...) and test-env-only projects
(cncf, cii, godotengine, sam, azf, riff, fn, openwhisk, openfaas, opencontainers, zephyr,
linux, prestodb). Every entry below had a FRESH 24-Aug tar.xz verified live on
devstats.cncf.io/backups. Archived projects keep their values.yaml index, so `i` numbers
have gaps - that is correct, do NOT renumber.

Fire packs ONE AT A TIME, smallest-first: run a pack's `restore_prod` lines, then its
`verify_pack` line - it BLOCKS (polls every 30s) until EVERY listed project is done,
prints `PACK DONE` and returns 0; only then start the next pack. Done = provision pod
Succeeded / final `Sync success` in pod logs / `Sync success` row in the `devstats`
logs DB (authoritative - still works after Succeeded pods were cleaned away, which the
function also does each round; Ctrl+C is safe, just re-run). While the two §3.8 giants are still
restoring this keeps total concurrency <= 8 (6 + 2), the same cap `wait_provisions 8`
would enforce. The final 4 SINGLES are the daily-cron giants - strictly ONE at a time.
If a project fails: `helm delete -n devstats-prod devstats-prod-<proj>` then re-run its
`restore_prod` line. `verify_pack` is also saved in `linodes.env.secret` (compute-01), so
`source linodes.env.secret` restores it after any shell restart; inline copy for reference:

```bash
kubectl config use-context prod
# BLOCKS until every listed project's provision is done, then prints PACK DONE (rc 0).
# A Failed pod is reported every round (fix: helm delete + re-run restore_prod).
verify_pack() {
  local ns=devstats-prod round=0 p st all inlist sql done_projs
  inlist=$(printf "'%s'," "$@"); inlist=${inlist%,}
  sql="select distinct proj from gha_logs where proj in ($inlist) and prog = 'gha2db_sync' and msg = 'Sync success' and dt > now() - '2 days'::interval"
  while true; do
    all=1
    done_projs=$(kubectl -n $ns exec devstats-postgres-0 -c devstats-postgres -- psql -U postgres -Atc "$sql" devstats 2>/dev/null)
    for p in "$@"; do
      st=$(kubectl -n $ns get po "devstats-provision-$p" -o jsonpath='{.status.phase}' 2>/dev/null)
      if [ "$st" = "Failed" ]; then
        echo "$p FAILED -> helm delete -n $ns devstats-prod-$p ; then re-run its restore_prod line"; all=0
      elif echo "$done_projs" | grep -qx "$p"; then
        echo "$p OK"
      elif [ "$st" = "Succeeded" ]; then
        echo "$p OK"
      elif kubectl -n $ns logs "devstats-provision-$p" --tail=3 2>/dev/null | grep -qE 'Sync success|marked as provisioned'; then
        echo "$p OK"
      else
        echo "$p NOT-READY${st:+ (pod $st)}"; all=0
      fi
    done
    kubectl -n $ns delete po --field-selector=status.phase=Succeeded >/dev/null 2>&1
    if [ "$all" = 1 ]; then echo "PACK DONE: $*"; return 0; fi
    round=$((round+1)); echo "--- waiting 30s (round $round) ---"; sleep 30
  done
}
```

The 39 packs + 4 singles (sizes = tar.xz bytes on the backups server):

```bash
# --- PACK 1/39 (total 1 MB)
restore_prod slimfaas 242 243                   # 72 KB
restore_prod kuasar 206 207                     # 89 KB
restore_prod composefs 251 252                  # 189 KB
restore_prod cohdi 271 272                      # 210 KB
restore_prod slimtoolkit 190 191                # 217 KB
restore_prod kubeelasti 272 273                 # 263 KB
verify_pack slimfaas kuasar composefs cohdi slimtoolkit kubeelasti

# --- PACK 2/39 (total 2 MB)
restore_prod aerakimesh 155 156                 # 271 KB
restore_prod interlink 253 254                  # 289 KB
restore_prod expressgraphql 47 48               # 291 KB
restore_prod serverlessdevs 164 165             # 377 KB
restore_prod opengemini 223 224                 # 383 KB
restore_prod loxilb 226 227                     # 408 KB
verify_pack aerakimesh interlink expressgraphql serverlessdevs opengemini loxilb

# --- PACK 3/39 (total 3 MB)
restore_prod clusternet 181 182                 # 417 KB
restore_prod bfe 83 84                          # 447 KB
restore_prod kubeslice 212 213                  # 482 KB
restore_prod stacker 220 221                    # 486 KB
restore_prod hwameistor 195 196                 # 506 KB
restore_prod kbind 281 282                      # 522 KB
verify_pack clusternet bfe kubeslice stacker hwameistor kbind

# --- PACK 4/39 (total 4 MB)
restore_prod kubean 215 216                     # 566 KB
restore_prod kusionstack 233 234                # 679 KB
restore_prod cdevents 182 183                   # 686 KB
restore_prod kuberhealthy 113 114               # 689 KB
restore_prod trickster 115 116                  # 705 KB
restore_prod gitopswg 105 106                   # 748 KB
verify_pack kubean kusionstack cdevents kuberhealthy trickster gitopswg

# --- PACK 5/39 (total 5 MB)
restore_prod agones 274 275                     # 755 KB
restore_prod kubeclipper 198 199                # 838 KB
restore_prod inclavarecontainers 136 137        # 844 KB
restore_prod akri 133 134                       # 894 KB
restore_prod nmstate 277 278                    # 931 KB
restore_prod clusterpedia 153 154               # 968 KB
verify_pack agones kubeclipper inclavarecontainers akri nmstate clusterpedia

# --- PACK 6/39 (total 7 MB)
restore_prod modelpack 263 264                  # 980 KB
restore_prod easegress 209 210                  # 1 MB
restore_prod screwdrivercd 185 186              # 1 MB
restore_prod paralus 174 175                    # 1 MB
restore_prod devspace 171 172                   # 1 MB
restore_prod oxia 266 267                       # 1 MB
verify_pack modelpack easegress screwdrivercd paralus devspace oxia

# --- PACK 7/39 (total 10 MB)
restore_prod xregistry 262 263                  # 1 MB
restore_prod youki 234 235                      # 2 MB
restore_prod kured 167 168                      # 2 MB
restore_prod containerssh 165 166               # 2 MB
restore_prod oauth2proxy 265 266                # 2 MB
restore_prod graphqlspec 46 47                  # 2 MB
verify_pack xregistry youki kured containerssh oauth2proxy graphqlspec

# --- PACK 8/39 (total 12 MB)
restore_prod kudo 76 77                         # 2 MB
restore_prod dalec 269 270                      # 2 MB
restore_prod shipwrightcncf 231 232             # 2 MB
restore_prod kitops 256 257                     # 2 MB
restore_prod kaischeduler 273 274               # 2 MB
restore_prod chaosblade 118 119                 # 2 MB
verify_pack kudo dalec shipwrightcncf kitops kaischeduler chaosblade

# --- PACK 9/39 (total 14 MB)
restore_prod kmesh 237 238                      # 2 MB
restore_prod vscodek8stools 142 143             # 2 MB
restore_prod runmenotebooks 245 246             # 2 MB
restore_prod openfunction 150 151               # 2 MB
restore_prod schemahero 98 99                   # 2 MB
restore_prod cni 9 10                           # 3 MB
verify_pack kmesh vscodek8stools runmenotebooks openfunction schemahero cni

# --- PACK 10/39 (total 16 MB)
restore_prod eraser 193 194                     # 3 MB
restore_prod urunc 261 262                      # 3 MB
restore_prod kubeburner 205 206                 # 3 MB
restore_prod ko 176 177                         # 3 MB
restore_prod kubefleet 247 248                  # 3 MB
restore_prod cedarpolicy 268 269                # 3 MB
verify_pack eraser urunc kubeburner ko kubefleet cedarpolicy

# --- PACK 11/39 (total 18 MB)
restore_prod velero 275 276                     # 3 MB
restore_prod openebs 36 37                      # 3 MB
restore_prod parsec 82 83                       # 3 MB
restore_prod ratify 229 230                     # 3 MB
restore_prod curvine 282 283                    # 3 MB
restore_prod score 224 225                      # 3 MB
verify_pack velero openebs parsec ratify curvine score

# --- PACK 12/39 (total 21 MB)
restore_prod holmesgpt 267 268                  # 3 MB
restore_prod bootc 250 251                      # 3 MB
restore_prod trestlegrc 221 222                 # 3 MB
restore_prod graphqljs 44 45                    # 4 MB
restore_prod athenz 108 109                     # 4 MB
restore_prod distribution 111 112               # 4 MB
verify_pack holmesgpt bootc trestlegrc graphqljs athenz distribution

# --- PACK 13/39 (total 23 MB)
restore_prod kubevip 127 128                    # 4 MB
restore_prod spinkube 241 242                   # 4 MB
restore_prod spin 240 241                       # 4 MB
restore_prod shipwright 186 187                 # 4 MB
restore_prod emissaryingress 116 117            # 4 MB
restore_prod bpfman 225 226                     # 4 MB
verify_pack kubevip spinkube spin shipwright emissaryingress bpfman

# --- PACK 14/39 (total 26 MB)
restore_prod koordinator 216 217                # 4 MB
restore_prod virtualkubelet 31 32               # 4 MB
restore_prod piraeus 106 107                    # 4 MB
restore_prod pixie 123 124                      # 4 MB
restore_prod kpt 196 197                        # 5 MB
restore_prod k8up 145 146                       # 5 MB
verify_pack koordinator virtualkubelet piraeus pixie kpt k8up

# --- PACK 15/39 (total 29 MB)
restore_prod carvel 168 169                     # 5 MB
restore_prod chubaofs 69 70                     # 5 MB
restore_prod kubers 146 147                     # 5 MB
restore_prod kcp 203 204                        # 5 MB
restore_prod werf 178 179                       # 5 MB
restore_prod kepler 191 192                     # 5 MB
verify_pack carvel chubaofs kubers kcp werf kepler

# --- PACK 16/39 (total 34 MB)
restore_prod cadence 259 260                    # 5 MB
restore_prod kanister 202 203                   # 6 MB
restore_prod capsule 172 173                    # 6 MB
restore_prod openeverest 276 277                # 6 MB
restore_prod copacetic 200 201                  # 6 MB
restore_prod sops 188 189                       # 6 MB
verify_pack cadence kanister capsule openeverest copacetic sops

# --- PACK 17/39 (total 37 MB)
restore_prod kcl 204 205                        # 6 MB
restore_prod intoto 57 58                       # 6 MB
restore_prod kserve 264 265                     # 6 MB
restore_prod cartography 227 228                # 6 MB
restore_prod krknchaos 207 208                  # 6 MB
restore_prod artifacthub 80 81                  # 6 MB
verify_pack kcl intoto kserve cartography krknchaos artifacthub

# --- PACK 18/39 (total 45 MB)
restore_prod drasi 252 253                      # 7 MB
restore_prod fluid 121 122                      # 7 MB
restore_prod telepresence 21 22                 # 8 MB
restore_prod armada 162 163                     # 8 MB
restore_prod spiderpool 210 211                 # 8 MB
restore_prod pipecd 192 193                     # 8 MB
verify_pack drasi fluid telepresence armada spiderpool pipecd

# --- PACK 19/39 (total 50 MB)
restore_prod keylime 96 97                      # 8 MB
restore_prod higress 278 279                    # 8 MB
restore_prod graphiql 45 46                     # 8 MB
restore_prod opencost 154 155                   # 9 MB
restore_prod dex 78 79                          # 9 MB
restore_prod k8sgpt 211 212                     # 9 MB
verify_pack keylime higress graphiql opencost dex k8sgpt

# --- PACK 20/39 (total 56 MB)
restore_prod serverlessworkflow 88 89           # 9 MB
restore_prod tuf 13 14                          # 9 MB
restore_prod cloudevents 20 21                  # 9 MB
restore_prod lima 169 170                       # 10 MB
restore_prod loggingoperator 201 202            # 10 MB
restore_prod ortelius 183 184                   # 10 MB
verify_pack serverlessworkflow tuf cloudevents lima loggingoperator ortelius

# --- PACK 21/39 (total 62 MB)
restore_prod porter 93 94                       # 10 MB
restore_prod k8gb 114 115                       # 10 MB
restore_prod metallb 134 135                    # 10 MB
restore_prod cloudcustodian 77 78               # 10 MB
restore_prod notary 12 13                       # 11 MB
restore_prod kagent 260 261                     # 11 MB
verify_pack porter k8gb metallb cloudcustodian notary kagent

# --- PACK 22/39 (total 67 MB)
restore_prod spiffe 18 19                       # 11 MB
restore_prod ovnkubernetes 238 239              # 11 MB
restore_prod bankvaults 218 219                 # 11 MB
restore_prod hyperlight 257 258                 # 11 MB
restore_prod openyurt 94 95                     # 11 MB
restore_prod openkruise 101 102                 # 11 MB
verify_pack spiffe ovnkubernetes bankvaults hyperlight openyurt openkruise

# --- PACK 23/39 (total 77 MB)
restore_prod microcks 197 198                   # 12 MB
restore_prod perses 228 229                     # 12 MB
restore_prod kubearmor 144 145                  # 13 MB
restore_prod kuadrant 222 223                   # 13 MB
restore_prod kubevela 126 127                   # 13 MB
restore_prod tremor 91 92                       # 13 MB
verify_pack microcks perses kubearmor kuadrant kubevela tremor

# --- PACK 24/39 (total 85 MB)
restore_prod apicurioregistry 280 281           # 13 MB
restore_prod kgateway 255 256                   # 14 MB
restore_prod oras 131 132                       # 14 MB
restore_prod wasmedge 117 118                   # 14 MB
restore_prod zot 173 174                        # 14 MB
restore_prod atlantis 219 220                   # 15 MB
verify_pack apicurioregistry kgateway oras wasmedge zot atlantis

# --- PACK 25/39 (total 91 MB)
restore_prod devfile 147 148                    # 15 MB
restore_prod connect 213 214                    # 15 MB
restore_prod opentofu 258 259                   # 15 MB
restore_prod k0s 244 245                        # 15 MB
restore_prod tinkerbell 102 103                 # 15 MB
restore_prod kaito 235 236                      # 15 MB
verify_pack devfile connect opentofu k0s tinkerbell kaito

# --- PACK 26/39 (total 105 MB)
restore_prod flatcar 232 233                    # 16 MB
restore_prod cdk8s 99 100                       # 17 MB
restore_prod contour 85 86                      # 17 MB
restore_prod kubeovn 109 110                    # 18 MB
restore_prod chaosmesh 87 88                    # 18 MB
restore_prod openchoreo 270 271                 # 19 MB
verify_pack flatcar cdk8s contour kubeovn chaosmesh openchoreo

# --- PACK 27/39 (total 118 MB)
restore_prod kubescape 179 180                  # 19 MB
restore_prod hami 230 231                       # 19 MB
restore_prod litmuschaos 79 80                  # 19 MB
restore_prod radius 217 218                     # 20 MB
restore_prod graphql 48 49                      # 20 MB
restore_prod inspektorgadget 180 181            # 21 MB
verify_pack kubescape hami litmuschaos radius graphql inspektorgadget

# --- PACK 28/39 (total 154 MB)
restore_prod cortex 27 28                       # 23 MB
restore_prod confidentialcontainers 149 150     # 25 MB
restore_prod podmancontainertools 249 250       # 26 MB
restore_prod coredns 6 7                        # 26 MB
restore_prod openclustermanagement 141 142      # 27 MB
restore_prod kubeedge 32 33                     # 27 MB
verify_pack cortex confidentialcontainers podmancontainertools coredns openclustermanagement kubeedge

# --- PACK 29/39 (total 181 MB)
restore_prod k3s 89 90                          # 28 MB
restore_prod antrea 120 121                     # 29 MB
restore_prod thanos 55 56                       # 29 MB
restore_prod buildpacks 28 29                   # 30 MB
restore_prod konveyor 161 162                   # 31 MB
restore_prod volcano 73 74                      # 33 MB
verify_pack k3s antrea thanos buildpacks konveyor volcano

# --- PACK 30/39 (total 208 MB)
restore_prod externalsecretsoperator 163 164    # 34 MB
restore_prod strimzi 58 59                      # 34 MB
restore_prod cozystack 254 255                  # 34 MB
restore_prod kairos 214 215                     # 34 MB
restore_prod cloudnativepg 246 247              # 35 MB
restore_prod wasmcloud 132 133                  # 37 MB
verify_pack externalsecretsoperator strimzi cozystack kairos cloudnativepg wasmcloud

# --- PACK 31/39 (total 236 MB)
restore_prod dragonfly 30 31                    # 37 MB
restore_prod dapr 139 140                       # 38 MB
restore_prod podmandesktop 248 249              # 40 MB
restore_prod karmada 135 136                    # 40 MB
restore_prod kubewarden 158 159                 # 41 MB
restore_prod spire 19 20                        # 41 MB
verify_pack dragonfly dapr podmandesktop karmada kubewarden spire

# --- PACK 32/39 (total 268 MB)
restore_prod keda 70 71                         # 42 MB
restore_prod openfga 166 167                    # 42 MB
restore_prod llmd 279 280                       # 45 MB
restore_prod nats 16 17                         # 46 MB
restore_prod headlamp 189 190                   # 46 MB
restore_prod flux 56 57                         # 48 MB
verify_pack keda openfga llmd nats headlamp flux

# --- PACK 33/39 (total 356 MB)
restore_prod networkservicemesh 35 36           # 50 MB
restore_prod fluentd 3 4                        # 56 MB
restore_prod submariner 122 123                 # 61 MB
restore_prod metal3 92 93                       # 61 MB
restore_prod etcd 25 26                         # 63 MB
restore_prod harbor 24 25                       # 65 MB
verify_pack networkservicemesh fluentd submariner metal3 etcd harbor

# --- PACK 34/39 (total 441 MB)
restore_prod jenkinsx 41 42                     # 65 MB
restore_prod opa 17 18                          # 71 MB
restore_prod spinnaker 40 41                    # 71 MB
restore_prod keycloak 187 188                   # 74 MB
restore_prod rook 14 15                         # 80 MB
restore_prod crossplane 84 85                   # 81 MB
verify_pack jenkinsx opa spinnaker keycloak rook crossplane

# --- PACK 35/39 (total 511 MB)
restore_prod jaeger 11 12                       # 83 MB
restore_prod kuma 81 82                         # 83 MB
restore_prod meshery 124 125                    # 84 MB
restore_prod vitess 15 16                       # 85 MB
restore_prod containerd 7 8                     # 86 MB
restore_prod operatorframework 86 87            # 90 MB
verify_pack jaeger kuma meshery vitess containerd operatorframework

# --- PACK 36/39 (total 592 MB)
restore_prod certmanager 100 101                # 92 MB
restore_prod longhorn 66 67                     # 92 MB
restore_prod openfeature 157 158                # 98 MB
restore_prod falco 29 30                        # 99 MB
restore_prod kyverno 104 105                    # 104 MB
restore_prod crio 34 35                         # 106 MB
verify_pack certmanager longhorn openfeature falco kyverno crio

# --- PACK 37/39 (total 840 MB)
restore_prod linkerd 4 5                        # 118 MB
restore_prod kubeflow 199 200                   # 130 MB
restore_prod kubestellar 208 209                # 130 MB
restore_prod prometheus 1 2                     # 136 MB
restore_prod tikv 26 27                         # 137 MB
restore_prod helm 22 23                         # 189 MB
verify_pack linkerd kubeflow kubestellar prometheus tikv helm

# --- PACK 38/39 (total 1.6 GB)
restore_prod grpc 5 6                           # 214 MB
restore_prod knative 52 53                      # 224 MB
restore_prod tekton 39 40                       # 253 MB
restore_prod argo 72 73                         # 274 MB
restore_prod backstage 90 91                    # 317 MB
restore_prod envoy 10 11                        # 325 MB
verify_pack grpc knative tekton argo backstage envoy

# --- PACK 39/39 (total 811 MB)
restore_prod cilium 138 139                     # 348 MB
restore_prod kubevirt 65 66                     # 463 MB
verify_pack cilium kubevirt

# --- SINGLE 1/4 (daily-cron giant)
restore_prod istio 51 52                        # 318 MB
verify_pack istio

# --- SINGLE 2/4 (daily-cron giant)
restore_prod jenkins 42 43                      # 526 MB
verify_pack jenkins

# --- SINGLE 3/4 (daily-cron giant)
restore_prod allcdf 43 44                       # 881 MB
verify_pack allcdf

# --- SINGLE 4/4 (daily-cron giant)
restore_prod opentelemetry 37 38                # 1.1 GB
verify_pack opentelemetry
echo 'ALL PROD RESTORES SUBMITTED'
```

Monitor (any time, e.g. next Mon/Fri):

```bash
kubectl -n devstats-prod get po | grep provision | grep -cv Completed          # still-running count
kubectl -n devstats-prod get po -o wide | grep provision | awk '{print $8}' | sort | uniq -c   # ALL on devstats-compute-* (git clones/hostpath!)
kubectl -n devstats-prod get po | grep provision | grep -Ev 'Completed|Running' # failures - MUST be empty
# retry a failed one: helm delete -n devstats-prod devstats-prod-<proj> ; restore_prod <proj> <from> <to>
# DB-level completeness vs the list above:
kubectl -n devstats-prod exec devstats-postgres-0 -c devstats-postgres -- psql -U postgres -Atc "select datname from pg_database where datname not in ('postgres','template0','template1') order by 1" | wc -l
# expect 244: 242 project DBs (kubernetes=gha, all=allprj, 6 from 3.8b, + the 234 above) + affiliations + devstats;
# compare the name list against the RESTORELIST above if the count is off 
```

### 3.10 PROD artificial rows + affiliations import + API + backups(hold)

INCIDENT 2026-08-25 (jenkins, fixed same day; pre-existing upstream bug, NOT migration-caused):
`devstats-provision-jenkins` died in gha2db_sync 'Update structure' — `scripts/shared/repo_groups.sql`
does `update gha_repos set repo_group = alias` but a vandal-renamed repo
(`jenkinsci/Checkmarx-Fully-Hacked-...`, 81 chars) overflows `repo_group varchar(80)` →
PqError 22001 retry-loop → 3600s timeout → exit 102. OCI prod jenkins had been failing the
SAME way daily for ~2 weeks (104 hits/14d, no 'Sync success' there either), so the dump was
already stale — no data was lost relative to OCI. Fix (applied to BOTH clusters):
`alter table gha_repos|gha_repo_groups|gha_events_commits_files alter column repo_group type varchar(160)`
on jenkins+allcdf+allprj+devspace (the 4 DBs with 81-char names); `left(...,80)` guards added to
`../devstats/scripts/shared/repo_groups.sql` + `repo_group varchar(80)→varchar(160)` in
`../devstatscode/structure.go` (both dirty for commit + next image build). Because OCI was ALTERed
too, the §4.2 final dumps carry varchar(160) DDL → §4.3 delta re-restores self-heal, no re-ALTER needed.
Same day also: Linode `github-oauth` secret had 13 revoked tokens (of 59) causing constant
`401 Bad credentials` noise in every ghapi2db phase — replaced with OCI's live 49-token list in
BOTH namespaces + master's `devstats-helm/secrets/GHA2DB_GITHUB_OAUTH.secret`; new sync pods pick
it up automatically.

Only after ALL provisions in 3.8/3.9 are Completed:

```bash
kubectl config use-context prod
# OPTIONAL for full-dump restores (§3.6 note: dumps already carry artificial rows):
kubectl -n devstats-prod exec -it debug -- bash -c "ONLY=\"\$(cat ./devstats-helm/all_prod_dbs.txt)\" RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"

helm install devstats-prod-affs-import ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except),skipAffiliationsImport=,affiliationsDB=affiliations,prodServer=1,testServer="
helm install devstats-prod-api ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except API),apiImage=lukaszgryglicki/devstats-api-prod"
helm install devstats-prod-backups ./devstats-helm -n devstats-prod --set "namespace=devstats-prod,$(skips_except Backups),backupsTestServer=,backupsProdServer=1"
kubectl -n devstats-prod edit cronjob devstats-backups   # set schedule: '45 2 10,20 * *'
# keep it SUSPENDED until after cutover (two backup sources must never run at once):
kubectl -n devstats-prod patch cronjob devstats-backups -p '{"spec":{"suspend":true}}'
# DONE 2026-08-25 differently: left ENABLED per operator decision (observe everything
# running); schedule '45 2 10,20 * *' = OCI original, next fire Sep 10 - after the
# accelerated cutover, so the two-sources conflict cannot happen anyway.
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
serving. Proceed to Part 4 as soon as ready (2026-08-25 decision: no Friday wait - cutover
ASAP in parallel with LF; test domains switch first, prod right after test DNS confirmed).

---

## Part 4 - delta restore + DNS cutover (ASAP; originally a Friday - accelerated 2026-08-25)

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
Linode from GH Archive within the hour). Plain `--from=cronjob` would hit the §2.1 NOAGE
pitfall (Friday run vs Monday dumps = 4-day age vs the randomized 4-11-day threshold →
kubernetes/allprj could be SILENTLY SKIPPED and 4.3 would re-restore stale dumps), so use
the §2.1 jq clone with an ONLY override - crons are frozen (4.1), primary is quiet:

```bash
J='{apiVersion:"batch/v1",kind:"Job",metadata:{name:"devstats-backups-final"},spec:.spec.jobTemplate.spec}'
J+=' | .spec.template.spec.containers[0].env |= map(if .name=="NOAGE" then .value="1"'
J+=' elif .name=="ONLY" then {name:"ONLY",value:"gha allprj"}'
J+=' elif .name=="PG_HOST" then {name:"PG_HOST",value:"devstats-postgres"} else . end)'
kubectl -n devstats-prod delete job devstats-backups-final --ignore-not-found
kubectl -n devstats-prod get cronjob devstats-backups -o json | jq "$J" | kubectl -n devstats-prod create -f -
kubectl -n devstats-prod wait --for=condition=ready pod -l job-name=devstats-backups-final --timeout=180s
kubectl -n devstats-prod logs -f job/devstats-backups-final    # ~2-3h, gates everything
# PASS: "Force backup gha allprj", "full gha", "full allprj", "full affiliations", "3 full backups OK"
# refresh artificial archives for ALL prod projects too (debug pod, as in 2.2):
S='namespace=devstats-prod,skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1'
S+=',skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1'
S+=',skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1'
S+=',bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s}'
S+=',bootstrapMountBackups=1,limitsBackupsCPU=4000m,limitsBackupsMemory=64Gi'
helm install devstats-prod-debug ./devstats-helm -n devstats-prod --set "$S"
kubectl -n devstats-prod exec -it debug -- bash -c "ONLY=\"\$(cat ./devel/all_prod_dbs.txt)\" FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh"
helm delete -n devstats-prod devstats-prod-debug
curl -s https://devstats.cncf.io/backups/ | grep -E 'href="(gha|allprj|affiliations)\.dump"'   # timestamp = today
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
helm delete -n devstats-prod devstats-prod-kubernetes; sleep 10; restore_prod kubernetes 0 1
helm delete -n devstats-prod devstats-prod-all;        sleep 10; restore_prod all 38 39
# CRITICAL (kubevirt 2026-08-24 lesson): restore_prod re-creates each project's CronJobs
# ENABLED, and the dump carries the `provisioned` flag - so a cron sync can fire MID-pg_restore
# (devstats-kubernetes 03:04, devstats-all 09:09 - allprj restore takes hours = near-certain hit),
# insert rows before the unique indexes are built, and silently corrupt PKs. Suspend both
# sync CJs IMMEDIATELY after the two restore_prod calls (affiliations CJs are monthly - no risk):
kubectl -n devstats-prod patch cronjob devstats-kubernetes -p '{"spec":{"suspend":true}}'
kubectl -n devstats-prod patch cronjob devstats-all        -p '{"spec":{"suspend":true}}'
# fresh affiliations too - §4.2's NOAGE run re-dumped it AFTER gha+allprj (backups.sh
# dumps affiliations outside the ONLY loop), so this pulls today's copy:
kubectl -n devstats-prod exec -it devstats-postgres-0 -c devstats-postgres -- bash -c \
  'cd /tmp && curl -fsSL -o aff.dump https://devstats.cncf.io/backups/affiliations.dump && \
   dropdb -U postgres --if-exists affiliations && createdb -U postgres affiliations && \
   pg_restore -U postgres -j 4 -d affiliations aff.dump && rm aff.dump && \
   psql -U postgres affiliations -c "select count(*) from gha_actors_affiliations"'
# fresh artificial rows AFTER the two provisions complete (same as 3.10):
watch 'kubectl -n devstats-prod get po | grep provision'   # Ctrl-C when Completed
# provisions done -> re-enable the two sync CJs suspended above:
kubectl -n devstats-prod patch cronjob devstats-kubernetes -p '{"spec":{"suspend":false}}'
kubectl -n devstats-prod patch cronjob devstats-all        -p '{"spec":{"suspend":false}}'
kubectl -n devstats-prod exec -it debug -- bash -c "ONLY=\"\$(cat ./devstats-helm/all_prod_dbs.txt)\" RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"
# (artificial rows OPTIONAL here - the delta full dumps already carry them, §3.6 note)
```

The helpers compute `ghapiRecentRange` from dump age automatically (§3.0), so these two
re-provisions also re-heal API-only state (labels/milestones/state) for the whole window
since their Monday dumps - the other ~86 projects were healed the same way during §3.9
and stay current via hourly syncs.

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
kubectl -n devstats-prod get certificate,order,challenge    # certificates: READY=True (minutes, not hours)
kubectl config use-context test
kubectl -n devstats-test get certificate,order,challenge
curl -sI https://devstats.cncf.io/  | head -3    # real cert now, no -k needed
curl -sI https://k8s.devstats.cncf.io/ | head -3
curl -sI https://teststats.cncf.io/ | head -3
```

### 4.6 Populate the Linode backups PV NOW + enable prod backups cron [master]

The moment DNS flips, `https://devstats.cncf.io/backups/` serves the LINODE backups PV -
which is empty. gitdm/cncf tooling and future restores need it populated:

```bash
kubectl config use-context prod
kubectl -n devstats-prod patch cronjob devstats-backups -p '{"spec":{"suspend":false}}'
kubectl -n devstats-prod create job --from=cronjob/devstats-backups devstats-backups-initial
kubectl -n devstats-prod logs -f job/devstats-backups-initial    # hours; runs unattended
# ALSO refresh artificial dumps INTO the Linode PV (debug pod, backup direction):
kubectl -n devstats-prod exec -it debug -- bash -c "ONLY=\"\$(cat ./devstats-helm/all_prod_dbs.txt)\" FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh"
```

### 4.7 Re-apply intentional cron suspends from the OCI snapshot [master]

```bash
grep 'suspend=true' oci-cron-suspends.secret   # (scp to the master if needed)
# 2026-08-24 snapshot: NOTHING suspended on OCI (512/512 suspend=false) - so nothing to
# mirror unless the final pre-cutover re-snapshot (4.1 freeze happens AFTER it) differs:
# for each intentionally-suspended cron that exists on Linode, mirror it:
# kubectl -n <ns> patch cronjob <name> -p '{"spec":{"suspend":true}}'
# test backups: ALREADY unsuspended on Linode + suspended on OCI (2026-08-24, see §3.6/§5.1b)
# - deliberate divergence from the OCI snapshot; do NOT re-suspend and do NOT mirror:
kubectl -n devstats-test get cj devstats-backups -o jsonpath='{.spec.suspend}{"\n"}'   # false
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
for ctx in prod test; do kubectl config use-context $ctx; kubectl -n devstats-$ctx get jobs --sort-by=.metadata.creationTimestamp | tail -30; done
# affiliations import cron ran (or run it once manually) and dashboards show updated affs
# scheduled prod backup (10th/20th 02:45) or the manual one is green AND restorable:
kubectl config use-context prod
kubectl -n devstats-prod exec -it debug -- bash -c 'cd /tmp && curl -fsSL -o t.dump https://devstats.cncf.io/backups/homebrew.dump && pg_restore --list t.dump | head && rm t.dump'
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

### 5.1b Unsuspend TEST backups (now that the switchover is confirmed) [master]

DONE EARLY 2026-08-24 (user decision): unsuspended right after the §3.5 test track
completed + §3.7 smoke passed - and the OCI test backups cron was suspended at the same
moment (Linode is now the only teststats backup writer). Kept here for the record:

```bash
kubectl config use-context test
kubectl -n devstats-test patch cronjob devstats-backups -p '{"spec":{"suspend":false}}'
kubectl -n devstats-test get cj devstats-backups -o jsonpath='{.spec.suspend}{"\n"}'   # false
# optional: fire one immediately and confirm dumps appear on the backups page:
kubectl -n devstats-test create job --from=cronjob/devstats-backups devstats-backups-first
curl -s https://teststats.cncf.io/backups/ | grep -c '\.dump'   # grows as it runs
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
