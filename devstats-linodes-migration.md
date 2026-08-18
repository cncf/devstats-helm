# DevStats migration: Oracle OCI → Akamai Linode

Status: EXECUTION PLAN (final approved hardware: `3 × G7 Dedicated 512 GB` + `4 × G7 Dedicated 256 GB`).

Deadline: OCI must be off in September. This plan is designed to complete in 14 calendar days,
with DNS cutover around day 10-11 and OCI teardown as the last step.

Related material:

- `akamai/initial-plan.md` - earlier research covering 6/9/10-node variants (superseded by this doc).
- `README.md` - the current OCI runbook. This plan reuses its structure and Helm sequence.
- `akamai/*.sh` - executable helpers created for this migration (see script index in section 19).
- Research/emails: `~/devstats-linode-migration` (offline reference).

---

## 0. Executive summary

| | Current (OCI) | Target (Akamai Linode) |
|---|---|---|
| Nodes | 6 × bare-metal (devstats-master, devstats-node-0..4) | 7 × G7 Dedicated VMs (`TOPOLOGY=mixed`; alternatives 8×256/7×256 - §1.4) |
| OS | Ubuntu 24.04 LTS | Ubuntu 26.04 LTS |
| Kubernetes | 1.35.0, kubeadm, 1 master, flannel /22, 1024 pods/node | same model, newest stable (1.36.x) at install time |
| Prod Patroni | 6 members, PVC 23000Gi, on all nodes | **3 members** on 3 × G7 512 GB, PVC 6000Gi |
| Test Patroni | 6 members (shared nodes) | **2 members** on 2 × G7 256 GB, PVC 3600Gi |
| PostgreSQL | 18.x + HLL (`devstats-patroni-18-hll`), Patroni 4.x | same images, newest available |
| Storage | 8 × NVMe mdadm RAID-10 → /data, OpenEBS hostpath + NFS RWX | plan-included local SSD → /data, OpenEBS hostpath + NFS RWX |
| Ingress | 2 × ingress-nginx NodePort (30080/30443, 31080/31443) | identical |
| Public LB | 2 × OCI NLB (132.226.49.222 prod / 152.70.192.23 test) | 2 × Akamai NodeBalancer (TCP pass-through) |
| TLS | cert-manager + Let's Encrypt HTTP-01 | identical |
| Networking | OCI VCN 10.0.0.0/16, NSG allow-all-internal | Linode VPC 10.60.0.0/24, 1:1 NAT public IPv4 |

Explicit non-goals (decided; do not re-add):

- No LKE / LKE Enterprise - self-managed kubeadm only.
- No multi-master - exactly one control plane, schedulable.
- No MetalLB - NodeBalancers replace OCI NLBs.
- No VLANs, no Block Storage for PGDATA, no disk encryption, no GPU.
- **Firewalls: two ready options** (§16): Option A = none at all (OCI-equivalent, simplest,
  day-1 default) vs Option B = one shared allowlist Cloud Firewall (`create-firewall.sh`,
  `FW_MODE=allowlist`). Pick either; switching later is a 2-minute, zero-downtime operation.
- No managed PostgreSQL (Aiven-based offering rejected: 3-node cap per service was acceptable
  but no superuser, unproven HLL parity, FDW-over-TLS latency and reader-endpoint uncertainty;
  see the research file for the full analysis).

---

## 0.1 Will this actually work? - feasibility verdict (live-measured 2026-08-18)

**Verdict: YES - very likely to work, comfortably. Estimated probability of success:
~90-95% by the 2-week deadline, and ~99% technically (the residual is schedule risk -
restore hours and human time - not capacity).** This is NOT a squeeze: the OCI cluster is
massively over-provisioned, and hard measurements prove the 7 Linodes are enough.

All numbers below were read from the live OCI cluster (`/proc` on every node via pods,
psql, kubectl) - not estimated:

| Resource | Measured on OCI (live) | Linode target capacity | Fit |
|---|---|---|---|
| CPU, 243-day *average* busy | **≈39 cores** total (6 devstats nodes ≈13.1 + asgardr ≈25.8) of 2,048 vCPU = 2% util | **416 vCPU** (3×64 + 4×56) | ~10× headroom over the average; even a 5× sync-peak burst fits |
| CPU, peak snapshot | loadavg 9.7 on the busiest node (prod PG leader), ~12 cluster-wide | 56-64 vCPU per node | fits per-node with 5-6× margin |
| RAM, real app usage (non-PG-cache) | ≈100-170 GiB/node → ≈0.6-0.9 TiB cluster-wide (the other ~710 GiB/node is PG shared_buffers+page cache, deliberately shrunk on Linode to 128/48 GB) | **2,560 GiB** (3×512 + 4×256) | fits; PG gets 128 GB sb + ~200-300 GiB cache on prod DB nodes |
| Disk, prod DB | 1.9 TiB PGDATA (2.4 TiB with WAL/temp peaks), 247 DBs | 6,000 Gi PVC on ~6.9 TiB /data | 2.5× headroom |
| Disk, test DB | 283 GiB PGDATA | 3,600 Gi PVC on ~4.7 TiB /data | 12× headroom |
| Backups | 149 GiB / 792 files | 2 Ti RWX PV | 13× headroom |
| Pods | 1,346 total ≈ 192/node avg on 7 nodes | 1,024 max/node × 7 | 5× headroom |
| K8s objects | 486 cronjobs, 247 deploys, 242 grafanas | same cluster software, same limits | proven at this scale on 6-7 nodes already |

Why the huge OCI boxes look "used": ~800 GiB/node consumed is almost entirely PostgreSQL
shared_buffers (500 GB runtime on BOTH prod and test - test's DCS config says 250 GB but was
never restart-applied, verified via `SHOW shared_buffers` vs `patronictl show-config`
2026-08-18) plus page cache - exactly the knobs
`patroni-tune.sh` shrinks. iowait today is ≈0.0%, so the DB is nowhere near disk-bound even
with all that cache; losing most of it costs some query latency, not correctness.

The 5 real risks (all mitigated in this plan):

1. **Restore duration** for `allprj` (56 GB dump) + `gha` (17 GB dump): hours each.
   Mitigation: start them first (§9), restore in parallel across the 3 prod nodes' NVMe.
2. **Sync-peak CPU alignment** of ~490 hourly cronjobs on 64-vCPU nodes. Mitigation:
   `splitcrons` already staggers schedules cluster-wide (§9); worst case, lengthen sync
   intervals of the top-5 projects - a config change, not an architecture change.
3. **Smaller page cache** (512 vs 2,048 GiB nodes) → more physical reads on big
   dashboards. Mitigation: local NVMe-class SSD, `random_page_cost=1.1`,
   `effective_cache_size=256GB`, watch `pg_stat_io`/iowait in week 1.
4. **G7 stock in the chosen region** on day 1. Mitigation: §4.1 - reserve all 7 on day 1,
   pilot-first order, support-ticket fallback, second-region fallback.
5. **NodeBalancer↔VPC specifics** (§7.2). Mitigation: NodePort backends over private/VPC
   interface work regardless; TCP pass-through identical to OCI NLBs.

What would make it fail? Only ordering/scheduling mistakes (e.g., skipping the disk resize
before PVC creation, or letting test grow gha/allprj - both now explicitly guarded), or
multi-day G7 unavailability. No measured resource comes within 2.5× of its limit.

The verdict holds for the alternative all-256 topologies too (§1.4): `8x256` ≈ same
probability (more vCPU, page cache halves on prod DB nodes - only latency-tail impact);
`7x256` ≈ 85-90% (same, minus one compute node's slack). And 512-availability risk #4
disappears entirely in both.

---

## 1. Target architecture

### 1.1 Node inventory

| Hostname | Plan | vCPU / RAM / local SSD | VPC IP | K8s role | DB role | Labels |
|---|---|---|---|---|---|---|
| `devstats-prod-db-01` | G7 Dedicated 512 GB | 64 / 512 GB / 7,200 GB | `10.60.0.11` | worker | prod Patroni | `node=devstats-app`, `node2=devstats-db-prod` |
| `devstats-prod-db-02` | G7 Dedicated 512 GB | 64 / 512 GB / 7,200 GB | `10.60.0.12` | worker | prod Patroni | `node=devstats-app`, `node2=devstats-db-prod`, `ingress=prod` |
| `devstats-prod-db-03` | G7 Dedicated 512 GB | 64 / 512 GB / 7,200 GB | `10.60.0.13` | worker | prod Patroni | `node=devstats-app`, `node2=devstats-db-prod`, `ingress=prod` |
| `devstats-test-db-01` | G7 Dedicated 256 GB | 56 / 256 GB / 5,000 GB | `10.60.0.21` | worker | test Patroni | `node=devstats-app`, `node2=devstats-db-test`, `ingress=test` |
| `devstats-test-db-02` | G7 Dedicated 256 GB | 56 / 256 GB / 5,000 GB | `10.60.0.22` | worker | test Patroni | `node=devstats-app`, `node2=devstats-db-test`, `ingress=test` |
| `devstats-compute-01` | G7 Dedicated 256 GB | 56 / 256 GB / 5,000 GB | `10.60.0.31` | **master** + worker | none | `node=devstats-app`, `ingress=prod` |
| `devstats-compute-02` | G7 Dedicated 256 GB | 56 / 256 GB / 5,000 GB | `10.60.0.32` | worker | none | `node=devstats-app`, `ingress=test` |

Totals: 416 dedicated vCPUs, 2,560 GB RAM, 41.6 TB local SSD.
Public list price: 3 × $5,530 + 4 × $2,765 = **$27,650/month before CNCF credits** (+ 2 NodeBalancers, ~$10 each).

Type IDs (live API re-verified 2026-08-18 directly against `api.linode.com/v4`):
256 GB = **`g7-dedicated-256-56`** (class `dedicated`, 56 vCPU, 5,120,000 MB disk - Linode
API disk units are MiB, so that is 5,000 GB as marketed - 11 TB
pooled transfer, $2,765/mo) - `g7-premium-56` is the identically-specced/priced premium
tier of the same size; either works, scripts default to `g7-dedicated-256-56`.
The public G7 dedicated ladder ENDS at 256 GB - **there is NO public 512 GB G7 plan**
("limited deployment availability" per official docs). The 512 GB type ID **must be
confirmed with Akamai on day 0** (§4.1); its assumed specs above (64 vCPU / 7,200 GB) are
unverified. Fallbacks: `g8-dedicated-512-256` (256 vCPU / 5,368,832 MB = 5,243 GB disk / usage-based
egress) - or **drop 512s entirely and use TOPOLOGY=8x256/7x256 (§1.4), orderable today**.

Notes:

- One Kubernetes cluster for everything; both namespaces (`devstats-prod`, `devstats-test`) share it.
- Master is `devstats-compute-01` (untainted, schedulable) - same single-master model as OCI.
- Test Patroni runs **2 members**. This is safe with the Kubernetes-DCS Patroni model
  (quorum lives in the Kubernetes API/etcd, not in Patroni member count): leader + 1 replica,
  automatic failover works. If a 3rd test member is ever required, label `devstats-compute-02`
  with `node2=devstats-db-test` and `helm upgrade` test patroni with `postgresNodes=3`
  (compute-02 has the same 5 TB local disk, so nothing else changes).
- The chart's built-in Patroni pod anti-affinity (`topologyKey: kubernetes.io/hostname`)
  guarantees 1 member per node; `postgresNodes` must never exceed matching labeled nodes.

### 1.2 Effective database capacity (hard go/no-go)

Every Patroni member holds a full copy, so the DB must fit on ONE node:

| Cluster | Node /data (after 150 GB root) | PVC (`postgresStorageSize`) | Safe steady-state DB size |
|---|---|---|---|
| prod | ~7,050 GiB (≈6.89 TiB) | `6000Gi` (≈6.44 TB) | ≤ 5.5 TB |
| test | ~4,850 GiB (≈4.74 TiB) | `3600Gi` (≈3.86 TB) | ≤ 3.2 TB |

OpenEBS hostpath does NOT enforce PVC size - these are accounting values. The real guard is
`df -h /data` monitoring. Measure current sizes on OCI **before anything else** (section 3.1).
If post-shrink prod > 5.5 TB, stop and renegotiate hardware; do not start the migration.

**GATE PASSED - live-verified 2026-08-18** (read-only psql against both leaders):

| Cluster | `sum(pg_database_size)` | DBs | pgdata du (incl. WAL/temp) | Gate | Margin |
|---|---|---|---|---|---|
| prod | **1,769 GB** | 247 | 1.9 T (du) / 2.4 T (fs) | ≤ 5.5 TB | **3.1+ TB free** ✓ |
| test | **170 GB** | 18 | 283 G | ≤ 3.2 TB | **~3 TB free** ✓ |

Top prod DBs: allprj 507 GB, gha 210 GB, jenkins 67 GB, opentelemetry 49 GB, allcdf 47 GB -
long tail of 13-28 GB each. Top test DBs: cii 85 GB, zephyr 22 GB, godotengine 21 GB,
cncf 17 GB. Re-run the measurement on migration day 0 as confirmation, but the sizing in
this plan is now validated against reality.

### 1.3 OCI → Linode object mapping

| OCI object | Linode/Akamai equivalent |
|---|---|
| Region + availability domain | one core compute region (must have G7 + VPC + Placement Groups + NodeBalancers) |
| VCN 10.0.0.0/16 + subnet | VPC `devstats-vpc`, subnet `devstats-nodes` 10.60.0.0/24 |
| NSG / security lists (allow all internal) | Option A: nothing (VPC is isolated by design) or Option B: one allowlist Cloud Firewall - both in §16, `create-firewall.sh` |
| VNIC `--skip-source-dest-check` | not needed (no equivalent required for flannel vxlan in VPC) |
| Public NLB + reserved IP (`oci/nlb-setup.sh`, `oci/oci-create-nlbs.sh`) | 2 × NodeBalancer (TCP 80/443 → NodePorts) — `akamai/create-nodebalancers.sh` |
| Bare-metal 8×NVMe + `mdadm` RAID-10 | plan-included SSD re-partitioned into root(150GB)+`/data` — `akamai/resize-node-disks.sh` |
| Fault domains | strict anti-affinity Placement Groups (max 5 Linodes each) |
| Instance public IP | public IPv4 via VPC 1:1 NAT |
| OCIDs / compartments / `oci-env.sh` | `akamai/linode-env.sh` + `linode-cli` |

Everything Kubernetes-inward (helm chart, images, namespaces, secrets, NodePorts, cert-manager,
OpenEBS, crons, grafanas, API, statics, reports) is provider-independent and migrates unchanged
except for the sizing overrides listed in section 14.

### 1.4 Alternative topologies: 8×256 and 7×256 (no 512 GB nodes at all)

Because the 512 GB G7 plan is not publicly orderable (§1.1), the scripts support three
topologies - set `TOPOLOGY` in `akamai/linode-env.sh` before `create-infra.sh`; everything
downstream (placement groups, disks, labels, patroni sizing, tuning) adapts automatically:

| | `TOPOLOGY=mixed` (default) | `TOPOLOGY=8x256` | `TOPOLOGY=7x256` (last resort) |
|---|---|---|---|
| Nodes | 3×512 GB + 4×256 GB | **8 × g7-dedicated-256-56** | **7 × g7-dedicated-256-56** |
| Prod Patroni | 3 × 512 GB nodes | 3 × 256 GB nodes | 3 × 256 GB nodes |
| Test Patroni | 2 × 256 GB nodes | 2 × 256 GB nodes | 2 × 256 GB nodes |
| Pure compute | 2 × 256 GB | **3** × 256 GB (adds `devstats-compute-03`, 10.60.0.33) | 2 × 256 GB |
| Totals | 416 vCPU / 2,560 GB / 41.6 TB | 448 vCPU / 2,048 GB / 40 TB | 392 vCPU / 1,792 GB / 35 TB |
| List price | $27,650/mo (assuming 512 ≈ 2×256) | **$22,120/mo** | $19,355/mo |
| Orderable today | NO - 512s need Akamai | **YES - all from public catalog** | YES |
| Prod PG params | sb 128GB, ecs 256GB, wm 2GB, temp 200GB, PVC 6000Gi, lim 400Gi/56c | sb 64GB, ecs 128GB, wm 1GB, temp 100GB, PVC 4500Gi, lim 180Gi/48c | same as 8x256 |
| Placement groups | prod=3, test/compute=4 (strict, max 5 ✓) | prod=3, test/compute=**5** (exactly at the strict max ✓) | prod=3, test/compute=4 ✓ |

Feasibility of prod Patroni on 256 GB nodes (live-measured, §0.1): prod PGDATA 1.9-2.4 TiB
fits the 4,850 GiB `/data` (PVC 4500Gi) with 2× headroom; post-shrink PostgreSQL needs
sb 64 GB + workers ≈ 100-140 GiB, apps ≈ 100 GiB → ~240 GiB worst case vs 256 GiB node -
tight but real usage is far below worst case (live prod pg anon memory is <1 GiB + shmem);
the page cache shrinks further vs `mixed`, so heavy dashboards (allprj/gha) get slower disk-
bound tails - acceptable, NVMe-backed. CPU: 39 cores avg cluster-wide vs 448/392 - non-issue.

**Recommendation: if Akamai has not confirmed the 512 GB type ID by Wednesday, switch to
`TOPOLOGY=8x256` and order Friday morning without them.** Prefer 8x256 over 7x256 - the
extra $2,765 buys 25% more app capacity and keeps prod DB nodes freer of app pods (13% more
headroom everywhere); 7x256 also works (it is the same 7-node shape as `mixed`, just with
smaller prod DB nodes). Do NOT mix in `g8-dedicated-*` for individual nodes unless forced:
different egress billing and smaller disks complicate accounting for zero benefit here.

---

## 2. Prerequisites (day 0)

1. Linode account access confirmed (`lukaszg` @ cloud.linode.com, the DevStats Linode account with CNCF credits).
2. Written/ticket confirmation from Akamai:
   - a single US core region with 3 × G7-512 + 4 × G7-256 available simultaneously;
   - strict anti-affinity placement groups supported there;
   - credits cover compute + NodeBalancers + transfer (+ Object Storage if used for backups).
3. Workstation with: `linode-cli` (`pip install linode-cli`), `jq`, `ssh`, this repo including all
   gitignored `*.secret` files (`devstats-helm/secrets/*.secret`, `cert/cert-issuer.yaml.secret`).
4. Create an API token: cloud.linode.com → Profile → API Tokens (read/write: Linodes, VPCs,
   NodeBalancers, Placement Groups, Firewalls, IPs, Images). `linode-cli configure`.
5. Reduce DNS TTL to 300 s NOW for: `devstats.cncf.io`, `teststats.cncf.io`, `devstats.cd.foundation`,
   `devstats.graphql.org` and every per-project host in `devstats-helm/values.yaml` `domains`/`projects`
   (they are wildcards/aliases of the 4 zones; confirm at the DNS provider). TTL change needs ~1 day
   to propagate - do it first.

---

## 3. Phase A - pre-flight on OCI (day 0-1, cluster stays live)

**Live OCI cluster snapshot (read-only verified 2026-08-18)** - the ground truth this plan
was checked against:

| Fact | Live value |
|---|---|
| Nodes | 7 total: `devstats-master`, `node-0..4` (256 vCPU / 2 TiB each) + `asgardr` (512 vCPU / 3 TiB, `node=devstats-app` only) |
| k8s / CRI / OS | v1.35.0 / containerd 2.1.4 / Ubuntu 24.04.3 LTS |
| Labels | ALL 6 devstats nodes carry `node2=devstats-db` (prod+test patroni share nodes!); `ingress=prod` on node-0/2/4, `ingress=test` on master/node-1/3 |
| Patroni | 6 members in EACH namespace, co-located pairwise on the same 6 nodes; sts requests 32 CPU/128Gi, limits 160 CPU/1Ti; image `devstats-patroni-18-hll` (PG 18.1, patroni 4.1.0, hll 2.19) |
| Patroni helm releases | pure chart defaults - NO `--set` sizing (verified `helm get values`); all sizing lives in values.yaml + REST `/config` |
| DB sizes | prod 1,769 GB / 247 DBs (top: allprj 507G, gha 210G); test 170 GB / 18 DBs (top: cii 85G) |
| Top tables | allprj: gha_texts 136G, gha_issues 55G, gha_issues_events_labels 40G; gha: gha_texts 44G, gha_issues_events_labels 30G - restore time is dominated by these + index rebuilds |
| Memory really used | prod leader: shmem 510 GiB + cache; test leader: shmem 200 GiB (cgroup v2, page cache dominates) |
| FDW | server `affiliations` → LOCAL socket `/var/run/postgresql` (shared affs DB is inside each cluster; 11 foreign tables in allprj) |
| Backups | CJs live: prod `45 2 10,20 * *`, test `45 2 8,15,22,28 * *`, not suspended; 2Ti RWX NFS PV; 149 GB / 792 files, freshest 2026-08-10; served by `devstats-static-default` at `/usr/share/nginx/html/backups` |
| affs-import | `devstats-{prod,test}-affs-import` releases → daily `import_affs_shared.sh` cron (prod 02:10, test 01:10) |
| Vacuum | NO vacuum cronjob anywhere (skipVacuum=1 everywhere) |
| Scale | prod: 1235 pods, 486 CJs, 247 deploys, 252 svcs, 242 grafanas, 8 ingresses; test: 76 pods, 26 CJs, 2 ingresses; per-node requests ≈66 CPU / ≈260Gi |
| Storage | openebs 3.10.0 (hostpath default SC) + nfs-provisioner 0.11.0; cert-manager v1.19.2; ingress-nginx 4.13.3 |

### 3.1 Measure real database sizes (go/no-go)

```bash
# context prod
./switch_context.sh prod
k exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- psql -U devstats_team -d postgres -c \
  "select sum(pg_database_size(datname))/1024^4 as tib from pg_database where not datistemplate;"
k exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- psql -U devstats_team -d postgres -c \
  "select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate order by pg_database_size(datname) desc limit 20;"
# repeat with context test / namespace devstats-test
```

Gate: prod total ≤ 5.5 TiB, test total ≤ 3.2 TiB. Record the numbers in this file.
**Done 2026-08-18: prod 1,769 GB / test 170 GB - PASSED with >3 TB margin (see section 1.2).**
(Note: `-d postgres` not `gha` on test - test has no gha DB; `devstats_team` role works
read-only on both. Also verified live: FDW server `affiliations` points at the LOCAL socket
`/var/run/postgresql` - the shared affiliations DB lives inside each Patroni cluster itself,
so restoring the `affiliations` DB early (before project DBs) is required and sufficient;
extensions in use: hll 2.19, pgcrypto, postgres_fdw.)

### 3.2 Refresh backups on OCI

The migration restores from the OCI backups page over HTTPS, so backups must be fresh:

```bash
# prod: trigger the backups cronjob now instead of waiting for its schedule
k -n devstats-prod create job --from=cronjob/devstats-backups devstats-backups-manual
k -n devstats-prod logs -f job/devstats-backups-manual
# test:
k -n devstats-test create job --from=cronjob/devstats-backups devstats-backups-manual
```

This runs `./devstats-helm/backups.sh` and publishes `*.dump` files under
`https://devstats.cncf.io/backups/` and `https://teststats.cncf.io/backups/`.
Verify a few dumps exist and have today's date:
`curl -s https://devstats.cncf.io/backups/ | grep -o 'gha.dump[^<]*'`.

Also refresh artificial-events backups (used by `restore_artificial.sh` later):

```bash
# debug pod on OCI prod (sleep pod with backups PV mounted) - README "backups pod" recipe:
helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1,limitsBackupsCPU=4000m,limitsBackupsMemory=64Gi
../devstats-k8s-lf/util/pod_shell.sh debug
# inside:
ONLY='' FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh
exit
helm delete devstats-prod-debug
```

### 3.3 Keep OCI syncing until cutover

Do NOT suspend OCI crons yet. OCI keeps running normally until the final delta restore
(section 11). Only avoid destructive operations (reinits, drops) from now on.

---

## 4. Phase B - Akamai infrastructure (day 1-2)

All commands below are wrapped in the scripts; run them from this repo:

```bash
cd akamai
vim linode-env.sh              # set REGION (from Akamai confirmation), SSH key, root pass
source linode-env.sh
./create-infra.sh              # VPC + subnet + 2 placement groups + 7-8 Linodes per TOPOLOGY (pilot mode available)
./resize-node-disks.sh all     # per node: shrink root to 150GB, drop swap, create ext4 "data" disk
```

Details / decisions encoded in the scripts:

1. **Pilot first**: `./create-infra.sh pilot` creates only `devstats-prod-db-01` and
   `devstats-compute-01`. Benchmark before creating the rest (they are kept as final nodes):
   ```bash
   # on each pilot node:
   lscpu; free -h; lsblk --bytes; df -h
   ping -c 50 10.60.0.31          # cross-node VPC latency (expect << 1 ms)
   iperf3 -s                       # on one; iperf3 -c 10.60.0.11 -P 8 on the other
   fio --name=t --filename=/data/fio.t --size=10G --rw=randwrite --bs=8k --iodepth=32 --numjobs=4 --direct=1 --runtime=60 --group_reporting
   ```
   Gate: latency < 1 ms, ≥ several Gbps throughput, random IOPS in the NVMe class.
   Then `./create-infra.sh rest`.
2. **Placement groups** (max 5 Linodes each, strict anti-affinity):
   - `devstats-prod-pg`: the 3 prod nodes;
   - `devstats-test-compute-pg`: the 4 × 256 GB nodes.
   Same region/VPC/subnet keeps everything on one low-latency fabric; anti-affinity only
   guarantees separate physical hosts (this is what we want for Patroni - do NOT ask for
   same-host affinity).
3. **Ubuntu 26.04 LTS** image - confirmed available in the catalog as `linode/ubuntu26.04`
   (status `available`, EOL 2031-05, cloud-init capable). No custom upload needed.
4. **VPC IPs are manual** (table in 1.1) with "assign public IPv4 (1:1 NAT)" enabled;
   NEVER use the first/last two subnet addresses (Akamai reserves them).
5. **No Cloud Firewall attached at creation** (avoids provider-filter debugging during the
   migration); pick Option A or B afterwards per §16 - `create-firewall.sh` applies either.
6. **Disk layout** (replaces OCI `mdadm` RAID-10 - Linode exposes one plan-storage pool, not 8 NVMe devices):
   - root disk resized to 150 GB, swap deleted;
   - one ext4 disk `data` using the full remainder (~7,050 GiB on 512s / ~4,850 GiB on 256s);
   - attached as `sdc` in the config profile; mounted `/data` by `node-setup.sh`.

### 4.1 How exactly to reserve the 7 Linodes "in vicinity to each other"

There is no same-host/same-rack affinity at Akamai - the ONLY placement control is
anti-affinity placement groups. "Vicinity" is achieved by putting all 7 in **one region on
one VPC subnet** (same DC fabric, sub-millisecond latency - the pilot benchmark in step 1
proves it), while placement groups spread them across different physical hosts *within* that
DC - exactly what Patroni HA needs. Concretely:

1. **Pick ONE region** with confirmed G7 stock (from the Akamai email thread; `us-ord`
   assumed - **re-verified 2026-08-18**: us-ord capabilities include Premium Plans,
   Placement Group, VPCs, NodeBalancers, Cloud Firewall, Metadata). Set `REGION` in
   `linode-env.sh`. Verified type IDs (queried directly from `api.linode.com/v4`):
   - 256 GB → **`g7-dedicated-256-56`** (class `dedicated`, 56 vCPU, 5,120,000 MB disk,
     11 TB pooled transfer, $2,765/mo); `g7-premium-56` is its premium-tier twin (same
     specs/price). Both exist - scripts default to `g7-dedicated-256-56`.
   - 512 GB → **NOT in the public catalog** (G7 dedicated ladder ends at 256 GB; docs:
     "G6 and G7 Dedicated 512 GB plans have limited deployment availability"). **Day-0
     action: reply on the Akamai credits thread asking either for the exact 512 GB type ID
     + a region with 3 in stock, OR their blessing to go `TOPOLOGY=8x256` (§1.4)**. Pin
     `TYPE_512` in `linode-env.sh` if confirmed. Last-resort fallback:
     `g8-dedicated-512-256` (512 GB, 256 vCPU, 5,368,832 MB disk, class `dedicated`,
     usage-based egress $0.005/GB - negligible for DevStats, but disk is 5.37 TB not
     7.2 TB: still 2× the 2.4 TB prod DB; OpenEBS hostpath does not enforce PVC size).
   Check what your account sees: `linode-cli linodes types --json | jq -r '.[] |
   select(.class=="dedicated" or .class=="premium") | select(.memory>=262144) | .id'`.
2. **Day-0 support ticket (required)**: new/low-history accounts have default instance/RAM
   caps (typically far below 7 nodes / 2,560 GB RAM). Open a ticket at
   cloud.linode.com/support referencing the CNCF credit arrangement: ask to (a) raise the
   account limit to ≥ 8 dedicated instances / ≥ 2,560 GB RAM (covers every topology incl.
   `8x256`), (b) confirm G7-512 stock in
   the chosen region, (c) confirm the 512 GB type ID. **Reserve ALL 7 on day 1** once
   unblocked - 512 GB plans are stock-limited per DC and credits already cover them; if a
   create still returns a capacity error, escalate on the same ticket.
3. **Create the two placement groups first**, then create Linodes INTO them (joining an
   existing Linode to a group later can force a migration):
   ```bash
   linode-cli placement group-create --label devstats-prod-pg --region "${REGION}" \
     --placement_group_type anti_affinity:local --placement_group_policy strict
   linode-cli placement group-create --label devstats-test-compute-pg --region "${REGION}" \
     --placement_group_type anti_affinity:local --placement_group_policy strict
   ```
   Max 5 Linodes per group → 3-node prod group + 4-node test/compute group (never mergeable).
   `strict` = creation FAILS rather than co-locating two members on one host - we want that.
4. **One VPC + subnet** (`devstats-vpc`, `devstats-nodes` 10.60.0.0/24) created once; every
   Linode gets its VPC interface as the primary interface with the manual IP from table 1.1
   and "1:1 NAT to a public IPv4" enabled.
5. All of the above is what `./create-infra.sh` does (pilot → benchmark → rest). In the UI the
   equivalent per Linode is: Create → Region `us-ord` → Image `Ubuntu 26.04 LTS` → Plan
   `Dedicated 512 GB`/`Dedicated 256 GB` → label per table 1.1 → SSH Keys ticked → VPC:
   `devstats-vpc`/`devstats-nodes`, manual IP, NAT 1:1 → Placement Group per table 1.1.
6. **Verify compliance** after creation:
   `linode-cli placement group-list --json | jq '.[] | {label, is_compliant, members}'`
   (older CLI versions name it `placement groups-list`) - `is_compliant: true` on both
   groups proves every member is on a distinct physical host.

### 4.2 SSH keys end-to-end

1. Dedicated key pair on the workstation (do not reuse personal keys):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/devstats_linode -C "devstats-linode-$(date +%Y%m)"
   ```
   Point `SSH_PUB_KEY_FILE=~/.ssh/devstats_linode.pub` in `linode-env.sh`; `create-infra.sh`
   passes it via `--authorized_keys` so **root on every node trusts it from first boot**.
   (Optionally also add it under cloud.linode.com → Profile → SSH Keys so UI-created Linodes
   can tick it.)
2. Workstation `~/.ssh/config` (public IPs printed by `create-infra.sh`; also add the VPC IPs
   reachable once you are on any node):
   ```
   Host devstats-prod-db-01 devstats-prod-db-02 devstats-prod-db-03 devstats-test-db-01 devstats-test-db-02 devstats-compute-01 devstats-compute-02 devstats-compute-03
     User root
     IdentityFile ~/.ssh/devstats_linode
     StrictHostKeyChecking accept-new
   # plus one HostName line per host with its public IP
   ```
3. Node-to-node ssh (scp of tars, kubeadm joins, `devstats-master` alias workflows): generate
   ONE internal admin key on `devstats-compute-01` and append its `.pub` to
   `/root/.ssh/authorized_keys` on all nodes (one loop from the workstation). `node-setup.sh`
   already writes `/etc/hosts` entries for all node names + the `devstats-master` alias.
4. After everything works: set `PasswordAuthentication no` + `PermitRootLogin prohibit-password`
   in sshd on all nodes (section 16). The `--root_pass` set at creation remains usable through
   **Lish** (Cloud Manager web console) as the no-SSH rescue path, and Linode's Rescue Mode
   covers disk-level recovery.
5. kubeconfig: after `kubeadm init`, copy `/etc/kubernetes/admin.conf` to the workstation and
   merge as contexts `prod`/`test`/`shared` exactly like today (`switch_context.sh` keeps working).

---

## 5. Phase C - OS + Kubernetes on all nodes (7-8, day 2-4)

### 5.1 Common node preparation

Copy and run `akamai/node-setup.sh` on every node (root). It reproduces the README's
"Shared steps for all nodes" minus OCI/mdadm parts:

```bash
scp akamai/linode-env.sh akamai/node-setup.sh root@<node-public-ip>:/root/
ssh root@<node-public-ip> 'cd /root && ./node-setup.sh'
```

What it does (identical philosophy to the OCI runbook):

- `/etc/hosts` with all VPC IPs (incl. `devstats-compute-03` for `8x256`; inert otherwise) + `devstats-master` alias → 10.60.0.31;
- mounts the `data` disk at `/data` (UUID fstab entry, `noatime`), disables swap permanently;
- creates `/data/{openebs,containerd,kubelet,etcd,logs/{containers,pods}}` and symlinks
  `/var/openebs`, `/var/lib/containerd`, `/var/lib/kubelet`, `/var/lib/etcd`,
  `/var/log/pods`, `/var/log/containers` into `/data`;
- kernel modules `overlay`,`br_netfilter`; sysctls (`ip_forward`, `rp_filter=0`, bridge-nf-call);
- iptables FORWARD ACCEPT;
- containerd (latest 2.x release binary) + `SystemdCgroup = true`, runc, crictl;
- kubelet/kubeadm/kubectl from `pkgs.k8s.io` newest stable stream (`v1.36` - v1.36.3 - at
  plan time; bump `K8S_STREAM` in `linode-env.sh` if newer exists on install day), `apt-mark hold`;
- scale sysctls (`gc_thresh*`, inotify, conntrack 2621440, somaxconn 4096);
- helm (latest), nfs-common, mc/btop/jq QoL.

### 5.2 Master init (on devstats-compute-01)

```bash
kubeadm init --apiserver-advertise-address=10.60.0.31 --pod-network-cidr=10.244.0.0/16
mkdir -p $HOME/.kube && cp /etc/kubernetes/admin.conf $HOME/.kube/config
# pinned flannel release (v0.28.9, §15) - not the moving master-branch manifest
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.9/kube-flannel.yml
kubectl taint nodes devstats-compute-01 node-role.kubernetes.io/control-plane:NoSchedule-
```

Join the remaining nodes with the printed `kubeadm join` (or `kubeadm token create --print-join-command`).
Join via `10.60.0.31` (VPC address), never the public IP. Verify `kubectl get nodes -o wide`
shows 10.60.0.x INTERNAL-IPs on all nodes.

### 5.3 High-density settings (1024 pods/node, /22 pod CIDRs)

Exactly as the OCI README (still required - ~250 grafanas + ~490 cronjobs). **Live-verified
2026-08-18**: every OCI node runs `maxPods: 1024` (kubelet `config.yaml` +
`kubelet-config` CM), controller-manager has `--node-cidr-mask-size-ipv4=22`, flannel
`net-conf.json` has `"SubnetLen": 22`, and every node's podCIDR is a /22. IP math: 7-8
nodes × /22 = 7,168-8,192 pod IPs out of `10.244.0.0/16` - plenty (live cluster runs ~1,350 pods
total, ≈193/node average on 7 nodes).

1. `kubectl -n kube-flannel edit cm kube-flannel-cfg` → add `"SubnetLen": 22` to `net-conf.json`;
   `kubectl -n kube-flannel rollout restart ds/kube-flannel-ds`.
2. On every node `vim /var/lib/kubelet/config.yaml` → `maxPods: 1024`; `systemctl restart kubelet`.
3. On master `/etc/kubernetes/manifests/kube-controller-manager.yaml` →
   `--allocate-node-cidrs=true --cluster-cidr=10.244.0.0/16 --node-cidr-mask-size-ipv4=22`.
4. Per-node flannel/cni reset dance from README (drain → stop kubelet/containerd → delete
   cni0/flannel.1 links → start → uncordon), master last.
5. Gate before continuing:
   ```bash
   kubectl get nodes -o custom-columns=NAME:.metadata.name,CAP:.status.capacity.pods,PODCIDR:.spec.podCIDR
   # every node MUST show 1024 and a /22
   ```
6. `./k8s/test-networking.sh` for cross-node pod networking.

### 5.4 Labels, namespaces, contexts

```bash
./akamai/label-nodes.sh     # applies the label table from section 1.1
kubectl create ns devstats-test; kubectl create ns devstats-prod
```

Add the three contexts to `~/.kube/config` exactly as in README (`prod` → devstats-prod,
`test` → devstats-test, `shared` → default). Copy admin.conf to `root` and `ubuntu`(-equivalent)
users on all nodes (README habit - every node is an admin box).

---

## 6. Phase D - storage (day 3)

Newest OpenEBS (4.5.1 umbrella chart - localpv hostpath only, replicated/LVM/ZFS engines off;
see §15 note) + the same dynamic-nfs provisioner as OCI:

```bash
helm repo add openebs https://openebs.github.io/openebs && helm repo update
helm install openebs openebs/openebs -n openebs --create-namespace \
  --set engines.replicated.mayastor.enabled=false \
  --set engines.local.lvm.enabled=false \
  --set engines.local.zfs.enabled=false \
  --set localpv-provisioner.hostpathClass.isDefaultClass=true
kubectl -n openebs get pods -w   # wait Ready
kubectl get sc                   # openebs-hostpath must exist and be (default)
helm repo add openebs-dynamic-nfs https://openebs-archive.github.io/dynamic-nfs-provisioner/ && helm repo update
helm install openebs-nfs openebs-dynamic-nfs/nfs-provisioner --namespace openebs-nfs --create-namespace \
  --set nfsStorageClass.name=nfs-openebs-localstorage --set-string nfsStorageClass.backendStorageClass=openebs-hostpath
```

Fallback (zero-risk, OCI-proven exact pair: openebs 3.10.0): `helm repo add openebs
https://openebs.github.io/charts` + plain `helm install openebs openebs/openebs -n openebs`
+ the same default-class patch as the README - use it if 4.5.1 misbehaves on install day.

Notes:

- `/var/openebs` already points at `/data/openebs` (node-setup.sh), so hostpath PVs land on the big disk.
- The two `devstats-backups` RWX PVCs (2Ti each, `nfs-openebs-localstorage`) get a backing
  hostpath PV on whichever node the NFS server pod lands; prefer compute nodes - if needed pin
  the `openebs-nfs` provisioner-created deployment with a nodeSelector after creation, or just
  verify with `kubectl -n openebs-nfs get po -o wide` that it did not land on a prod-db node.

Quick storage gate: create/delete a 1Gi PVC+pod in both classes (RWO hostpath, RWX nfs).

---

## 7. Phase E - ingress, NodeBalancers, cert-manager (day 3-4)

### 7.1 ingress-nginx × 2

```bash
./akamai/install-ingresses.sh
```

Identical to OCI (DaemonSet, NodePort, scoped per namespace, `externalTrafficPolicy=Local`):

- `nginx-ingress-prod` → class `nginx-prod`, ns `devstats-prod`, nodeSelector `ingress=prod`, NodePorts 30080/30443;
- `nginx-ingress-test` → class `nginx-test`, ns `devstats-test`, nodeSelector `ingress=test`, NodePorts 31080/31443;
- then `ULIMIT_N=65535 ./k8s/update_ingress_limits.sh` (avoids "too many open files").

### 7.2 NodeBalancers (replaces `oci/oci-create-nlbs.sh`)

```bash
./akamai/create-nodebalancers.sh
```

- `devstats-prod-nb`: TCP 80→30080, TCP 443→30443; backends = the `ingress=prod` nodes
  (10.60.0.31, 10.60.0.12, 10.60.0.13).
- `devstats-test-nb`: TCP 80→31080, TCP 443→31443; backends = `ingress=test`
  (10.60.0.32, 10.60.0.21, 10.60.0.22).
- TCP mode (pass-through) - TLS keeps terminating in ingress-nginx/cert-manager.
- Backends are VPC addresses: **VPC-integrated NodeBalancers are GA** - the VPC is bound at
  NB creation (`--vpcs '[{"vpc_id":...,"subnet_id":...}]'`, a /30 inside the subnet is
  auto-assigned) and **cannot be changed afterwards** (delete + recreate if wrong). Health
  check = TCP connect. $10/month each; NB egress counts against the pooled transfer.
  `externalTrafficPolicy=Local` makes non-ingress nodes fail health checks by design -
  only the 3 labeled nodes per NB are added.
- **Classic (non-VPC) NB fallback only**: if VPC-attached creation fails, the script creates a
  classic NB - but classic NB backends require Linode *private* IPv4s, and our nodes are created
  WITHOUT them (`--private_ip false`). First: `linode-cli linodes ip-add <linode-id> --type ipv4
  --public false` on each backend node + reboot it, then add `192.168.x.y:<NodePort>` backends
  (UI or `nodebalancers node-create`). With firewall Option B additionally allow TCP
  30000-32767 from `192.168.255.0/24` (classic NB source range). The VPC path avoids all this.
- Record both public IPs in `akamai/linode-env.sh` (`PROD_NB_IP`, `TEST_NB_IP`).

Gate: `curl -I --resolve devstats.cncf.io:80:$PROD_NB_IP http://devstats.cncf.io/` returns an
nginx response (404/308 is fine at this stage) - and same for test NB.

### 7.3 cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --set crds.enabled=true
cp cert/cert-issuer.yaml.secret cert/cert-issuer.yaml   # already-tweaked issuers (or re-derive from .example)
kubectl apply -f cert/cert-issuer.yaml
```

Certificates will only be issued AFTER DNS points at the NodeBalancers (HTTP-01 through port 80).
That is expected; ingresses can be installed before DNS cutover.

---

## 8. Phase F - DevStats TEST environment (day 4-6)

Test goes first (smaller, proves the whole pipeline). Contexts: `./switch_context.sh test`.

**Test is deliberately tiny and MUST stay tiny** (live-verified: 170 GB total, 18 DBs).
It serves ONLY the 12 test projects - biggest are cii (85G), zephyr (22G), godotengine (21G),
cncf (17G), linux (3.8G). It has **NO `gha` database and no real `allprj`** (the 20 MB
`allprj` on live test is artificial-rows-only). Never restore `gha`/`allprj` into test -
they alone are 717 GB and would defeat the 2-node/256 GB sizing. The `projectsOverride`
list in `deploy-devstats-test.sh` is the only allowed scope.

Run the scripted sequence (wraps the README commands with Linode sizing):

```bash
./akamai/deploy-devstats-test.sh secrets     # devstats-test-secrets
./akamai/deploy-devstats-test.sh backups-pv  # 2Ti RWX backups PVC
./akamai/deploy-devstats-test.sh pvcs        # git PVCs (test projectsOverride); delete Pending non-test PVCs after
./akamai/deploy-devstats-test.sh patroni     # postgresNodes=2, 3600Gi, node2=devstats-db-test, right-sized resources
```

Patroni checks + tuning:

```bash
k exec -itn devstats-test devstats-postgres-0 -- patronictl list   # leader + 1 replica, both running
ENV=test ./akamai/patroni-tune.sh                                  # PATCH /config with 256GB-node parameters (section 14.2)
k exec -itn devstats-test devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
k exec -itn devstats-test devstats-postgres-0 -- patronictl show-config
```

Then:

```bash
./akamai/deploy-devstats-test.sh statics     # static page handlers (test domain)
./akamai/deploy-devstats-test.sh ingress     # ingressClass=nginx-test, sslEnv=test
./akamai/deploy-devstats-test.sh bootstrap   # logs DB bootstrap; k logs -f devstats-provision-bootstrap; delete pod after OK
```

Grafana shared data (one-time, from `cncf/devstats` repo on your workstation - README recipe):

```bash
cp ../devstatscode/sqlitedb ../devstatscode/runq ../devstatscode/replacer grafana/
tar cf devstats-grafana.tar grafana/runq grafana/sqlitedb grafana/replacer grafana/shared \
  grafana/img/*.svg grafana/img/*.png grafana/*/change_title_and_icons.sh grafana/*/custom_sqlite.sql grafana/dashboards/*/*.json
# scp to a node, k cp into the devstats-static-test pod, then inside the pod:
# rm -rf /grafana && tar xf /devstats-grafana.tar && rm -rf /usr/share/nginx/html/backups/grafana \
#   && mv /grafana /usr/share/nginx/html/backups/grafana && rm /devstats-grafana.tar \
#   && chmod -R ugo+rwx /usr/share/nginx/html/backups/grafana/ && echo 'All OK'
```

Restore the 12 test projects from OCI backups (azf cii cncf fn godotengine linux opencontainers
openfaas openwhisk riff sam zephyr; indexes [49,51),[53,55),[59,65),[67,68),[97,98)):

```bash
# per project: provision pod runs devstats-helm/restore.sh with restoreFrom=https://teststats.cncf.io/backups/
./scripts/deploy_backup_to_test.sh cncf 49 50      # etc. - the script prints the log-follow command
...
```

then artificial rows + finish:

```bash
# debug pod (deploy-devstats-test.sh debug), inside:
ONLY='azf cii cncf fn godotengine linux opencontainers openfaas openwhisk riff sam zephyr' \
  RESTORE_FROM='https://teststats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh
```

Note: test also hosts a local `affiliations` DB (live: 1.4 GB) used through the local-socket
FDW - restore it early like on prod (`./scripts/deploy_backup_to_test.sh affiliations <i> <i+1>`).

```bash
./akamai/deploy-devstats-test.sh affs-import # devstats-test-affs-import: daily import_affs_shared.sh cron (live: 10 1 * * *)
./akamai/deploy-devstats-test.sh api         # devstats-test-api
./akamai/deploy-devstats-test.sh backups     # installs the cron then SUSPENDS it immediately
```

**Decision - test backups are DISABLED on Linode** (OCI ran them 4×/month). Rationale:
test data is rebuildable from prod backups + git in hours, dumps eat NFS space and I/O on a
much smaller cluster, and nothing external depends on fresh `teststats.cncf.io/backups/*`
dumps (velocity/gitdm read the PROD backups page). The script leaves the cronjob installed
but `suspend: true`; flip to monthly (`45 2 28 * *`, unsuspend) later if ever wanted. Keep
the old OCI-era dumps already sitting in the 2Ti backups PV - they serve as restore sources
during the migration itself.

Keep all test cronjobs suspended until validation (the restore scripts install crons; suspend:
`k -n devstats-test get cj -o name | xargs -I{} kubectl -n devstats-test patch {} -p '{"spec":{"suspend":true}}'`).

Validate test env via `curl --resolve teststats.cncf.io:443:$TEST_NB_IP https://teststats.cncf.io/...`
(cert will be self-signed/absent until DNS cutover - `-k` for now), grafana loads, API answers.

---

## 9. Phase G - DevStats PROD environment (day 5-9)

Context: `./switch_context.sh prod`. Same sequence, prod sizing:

```bash
./akamai/deploy-devstats-prod.sh secrets
./akamai/deploy-devstats-prod.sh backups-pv
./akamai/deploy-devstats-prod.sh pvcs
./akamai/deploy-devstats-prod.sh patroni     # postgresNodes=3, 6000Gi, node2=devstats-db-prod
k exec -itn devstats-prod devstats-postgres-0 -- patronictl list
ENV=prod ./akamai/patroni-tune.sh            # 512GB-node parameters (section 14.1)
k exec -itn devstats-prod devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
./akamai/deploy-devstats-prod.sh statics
./akamai/deploy-devstats-prod.sh ingress
./akamai/deploy-devstats-prod.sh bootstrap
# grafana shared data tar into devstats-static-prod pod (same recipe as test)
```

Bulk restore of ~240 prod projects from `https://devstats.cncf.io/backups/`:

- `scripts/deploy_prod.sh` is the full ordered list of `./scripts/deploy_backup_to_prod.sh <proj> <i> <i+1>`
  calls (kubernetes 0 1 → ... → all 38 39 (the `allprj` DB) → CDF/GraphQL → ... ). Run it in slices so the
  cluster is not saturated; each restore pod pulls the dump over HTTPS and pg_restores it.
- Parallelism guidance: 6-10 concurrent restore pods; the big ones (gha=kubernetes, allprj)
  alone can take hours - start `kubernetes 0 1` and `all 38 39` FIRST, they are the long poles.
- Watch: `k get po | grep provision`; `clear && k logs -f -l type=provision --max-log-requests=40 --tail=10`.
- Failures: rerun single project, or use the README "fix pod" recipe
  (`provisionCommand=sleep` + `fix-after-fail.sh proj`). Cap any manual override at
  `limitsProvisionsMemory=400Gi`, `nCPUs<=32` (the old 640Gi/1Ti examples DO NOT fit Linode nodes;
  they only fit the 512 GB prod-db nodes and only up to ~400Gi).
- Archived projects are commented out in `scripts/deploy_prod.sh` already - skip them
  (cross-check `cncf/devstats/metrics/all/sync_vars.yaml`).
- Shared affiliations DB: since the July 2026 switchover there is one shared `affiliations` DB +
  FDW. Restore it EARLY (right after bootstrap, before dependent projects) -
  `./scripts/deploy_backup_to_prod.sh affiliations <i> <i+1>` with its index from values.yaml
  (grep `- proj: affiliations` / check `affiliationsDB: 'affiliations'`), because per-project
  metrics read it through postgres_fdw on localhost service - verify
  `k exec -itn devstats-prod devstats-postgres-0 -- psql gha -c "select count(*) from gha_actors_affiliations"`-style
  sanity queries afterwards.

Artificial rows for all prod projects (debug pod):

```bash
./akamai/deploy-devstats-prod.sh debug
../devstats-k8s-lf/util/pod_shell.sh debug
RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh
exit; helm delete devstats-prod-debug
```

Finish:

```bash
./akamai/deploy-devstats-prod.sh affs-import # devstats-prod-affs-import: daily import_affs_shared.sh cron (live: 10 2 * * *)
./akamai/deploy-devstats-prod.sh api
./akamai/deploy-devstats-prod.sh backups     # then k edit cj devstats-backups: schedule 45 2 10,20 * *  - keep suspended
# NOTE (live-verified): NO vacuum cronjob exists on OCI in either namespace (skipVacuum=1
# everywhere) - do not expect one; vacuuming is autovacuum + per-project sync tooling.
```

ALL prod cronjobs stay suspended until cutover:

```bash
k -n devstats-prod get cj -o name | xargs -I{} kubectl -n devstats-prod patch {} -p '{"spec":{"suspend":true}}'
```

---

## 10. Phase H - validation gates (day 9-10)

Infrastructure:

- [ ] 7 nodes (8 for `TOPOLOGY=8x256`) `Ready`, INTERNAL-IP = 10.60.0.x, 1024 pods, /22 podCIDR each
- [ ] both placement groups "compliant" in Cloud Manager
- [ ] `df -h /data` on every node: prod-db < 80% after full restore, test-db < 75%
- [ ] NodeBalancer backends: 3/3 healthy on both NBs

Databases:

- [ ] `patronictl list` prod: 1 leader + 2 replicas, lag ≈ 0; test: 1 leader + 1 replica
- [ ] controlled switchover works, old leader rejoins:
      `k exec -itn devstats-prod devstats-postgres-0 -- patronictl switchover devstats-postgres --force`
      (then switch back)
- [ ] kill-test: delete leader pod → new leader elected < 1 min, deleted pod rejoins as replica
- [ ] `select version();` = PostgreSQL 18.x; `select extname, extversion from pg_extension;`
      shows `hll`, `pgcrypto`, `postgres_fdw` in the DBs that use them
- [ ] row-count spot-check 5 projects vs OCI (same query both sides):
      `select max(id) from gha_events;` / `select count(*) from gha_events;` on gha, allprj, 3 others
- [ ] FDW to shared affiliations works from a project DB
- [ ] one full manual `devstats-backups` job runs green ON LINODE and the dump is downloadable

Application (all through `curl --resolve` against NB IPs, before DNS):

- [ ] `https://devstats.cncf.io` dashboard loads (Grafana), `-k` until certs
- [ ] `https://devstats.cncf.io/api/v1` API answers (POST a simple health/list query)
- [ ] per-project grafanas sample (k8s, prometheus, envoy, cdf, graphql domains)
- [ ] static/backups pages serve
- [ ] one manual hourly-sync run for ONE project completes green:
      un-suspend just `devstats-<proj>` cron, `k create job --from=cronjob/...`, watch logs, re-suspend
- [ ] one affiliations cron dry-run green

---

## 11. Phase I - cutover (day 10-11)

Order matters; total DevStats "stale window" is a few hours, no visible downtime:

1. **Suspend OCI crons** (prod + test) - hourly syncs, affs, backups, vacuum:
   `k -n devstats-prod get cj -o name | xargs ... suspend=true` on OCI; let running jobs finish
   (`k get po | grep -E 'sync|affs'`).
2. **Final delta**: on OCI run the backups job once more (fresh dumps + `backup_artificial_all.sh`),
   then on Linode re-run restores ONLY for projects whose data changed since the phase-G restore
   (in practice: all of them changed - but the second restore is much faster with warm caches;
   if time is short, accept dumps from phase G + let hourly syncs catch up from GHA archives -
   DevStats is designed to backfill; `gha2db` will fetch the gap. Decide per DB size:
   re-restore gha/allprj, backfill the small ones).
3. **DNS switch** (TTL is already 300 s): point `devstats.cncf.io`, `devstats.cd.foundation`,
   `devstats.graphql.org` + wildcards → `$PROD_NB_IP`; `teststats.cncf.io` + wildcards → `$TEST_NB_IP`.
4. **Watch cert-manager** issue Let's Encrypt certs via HTTP-01 (needs DNS live):
   ```bash
   kubectl -n devstats-prod get certificate,order,challenge
   kubectl -n devstats-prod describe certificate devstats-tls-1
   # ingress cert counts, as in README:
   kubectl -n devstats-prod get ingress devstats-ingress-1 -o json | jq '.spec.tls[0].hosts | length'
   ```
   Rate-limit note: LE = 50 certs/week per domain; `tlsMaxHostsPerCert: 35` splits hosts into
   a handful of SAN certs - fine, but do not delete/recreate ingresses repeatedly.
5. **Un-suspend Linode crons** - prod first, in waves (syncs are staggered by `splitcrons`-generated
   schedules already embedded in values.yaml/new-values.yaml):
   ```bash
   k -n devstats-prod get cj -o name | xargs -I{} kubectl -n devstats-prod patch {} -p '{"spec":{"suspend":false}}'
   k -n devstats-test get cj -o name | xargs -I{} kubectl -n devstats-test patch {} -p '{"spec":{"suspend":false}}'
   ```
   (Re-apply the intentional suspends afterwards if any cron is meant to stay off - check OCI's
   previous suspend state captured in phase A.)
6. Monitor for 24 h: `patronictl list` lag, `df -h /data`, `k top nodes` (install metrics-server
   if wanted), failing cronjob pods (`k get po | grep -E 'Error|CrashLoop'`), ingress 5xx.
7. `devstats-landscape-sync` cron: re-point/reinstall its crontab on the new environment
   (it ran on the OCI `node-0` host crontab: `0 3 * * *` `check_sync.sh` - move to
   `devstats-compute-02` host cron or keep wherever it currently runs; it only needs DB/API access).
8. `cncf/gitdm` + `cncf/velocity` workflows (verified in-repo, no hardcoded IPs anywhere -
   they use `devstats.cncf.io`/`teststats.cncf.io` URLs which survive the DNS flip):
   - `gitdm/src/login_contributions.sh` uses `kubectl config use-context prod` + `kubectl exec
     ... psql` - keeps working as long as the workstation kubeconfig contexts point at Linode;
   - the ~4-weekly affiliations refresh (`import_affs.sh`/`rerun_data.sh`) and its
     GitHub/Clearbit/etc API keys live on the operator workstation - nothing to migrate on nodes;
   - velocity chart generation shells into a reports pod (`docs/cncf_chart_creation.md`) and
     downloads from `https://devstats.cncf.io/backups/...` - re-test once after cutover.

Rollback (any time before OCI teardown): flip DNS back to OCI NLB IPs (132.226.49.222 /
152.70.192.23), un-suspend OCI crons, suspend Linode crons. Data divergence is bounded by
GHA-backfill, so rollback is cheap in the first days.

---

## 12. Phase J - soak + OCI decommission (day 11-14)

- [ ] 48-72 h soak: syncs green two full days, affiliations cron green once, one scheduled
      backup green ON LINODE, restore-tested (`pg_restore --list` at minimum).
- [ ] Reports: run one `devstats-reports` pod/queries against the new cluster (velocity/reports
      workflows read the same DBs; nothing provider-specific).
- [ ] Copy any remaining wanted artifacts off OCI backups page (old dumps if you want history).
- [ ] Snapshot OCI configuration for the archive: `helm list -A -o yaml`, `k get cj -A -o yaml`,
      values/secrets already in this repo.
- [ ] Tear down OCI (reverse of `devstats-k8s-lf`/OCI docs): delete NLBs, instances, boot volumes,
      subnets/VCN, NSGs, reserved IPs - or simply terminate per LF/Oracle guidance since the
      account is being sunset. Confirm with Shah/Ihor BEFORE deleting (billing evidence etc.).
- [ ] Update repo docs: mark README.md as historical-OCI, add Akamai runbook pointer, commit
      `akamai/linode-env.sh` sans secrets.

---

## 13. Day-by-day schedule (2 weeks)

| Day | Work |
|---|---|
| 0 | DNS TTL → 300 s; Akamai ticket (account limits + G7-512 type ID/stock, §4.1); measure DB sizes on OCI (gate); fresh OCI backups |
| 1 | `create-infra.sh pilot`; benchmarks (fio/iperf3); `create-infra.sh rest`; `resize-node-disks.sh all` |
| 2 | `node-setup.sh` on all nodes; kubeadm init + joins |
| 3 | flannel /22 + maxPods 1024 + gates; labels/ns/contexts; OpenEBS + NFS; ingresses |
| 4 | NodeBalancers; cert-manager+issuers; TEST: secrets→patroni→tune; statics/ingress/bootstrap |
| 5 | TEST: restores (12 projects) + artificial; API; validation of test |
| 6 | PROD: secrets→patroni→tune→statics→ingress→bootstrap; grafana tar; start gha + allprj restores |
| 7-8 | PROD: bulk project restores in slices; affiliations early; fix failures |
| 9 | PROD: artificial restores; API; backups cron (suspended; NO vacuum cron - OCI parity); validation gates |
| 10 | Full validation pass; final OCI backup; suspend OCI crons; delta restores |
| 11 | DNS cutover; certs; un-suspend Linode crons (test backups STAY suspended - §8); monitoring |
| 12-13 | Soak; Linode-native backup + restore test; reports check; fix stragglers |
| 14 | OCI decommission sign-off; docs updated |

Buffer: phases F/G can overlap (test restores while prod patroni installs). If G7-512 delivery
slips, run EVERYTHING on the 4 × 256 first (test env + infra), attach prod nodes when they land.

### 13.1 Friday fast-track: reserve + full platform install in ONE day (no DevStats yet)

Goal for Friday: all Linodes reserved, Kubernetes + helm + OpenEBS/NFS storage + ingresses +
NodeBalancers + cert-manager + BOTH Patroni clusters (tuned, empty) running. DevStats itself
(bootstrap, projects, restores, crons, grafanas) starts afterwards. This compresses plan
days 1-4 into one; it works because every step is scripted and none of them wait on data.

**Prerequisites - MUST be done Mon-Thu (blocking):**

- [ ] TODAY: Akamai ticket/credits-thread reply - account limits (≥ 8 instances / ≥ 2,560 GB
      RAM), 512 GB type ID + stock OR approve `8x256` (§4.1). **If no answer by Thursday
      EOD → decision: `TOPOLOGY=8x256`, fully orderable without them.**
- [ ] `linode-cli configure` with a full-scope token; `pip install linode-cli`; jq present.
- [ ] SSH key pair created + `SSH_PUB_KEY_FILE` set (§4.2); `ROOT_PASS` chosen.
- [ ] `linode-env.sh` reviewed: `REGION`, `TOPOLOGY`, `FW_MODE` (recommend `open` for now).
- [ ] Workstation: kubectl v1.36.x + helm 4.2.4 installed (§15).
- [ ] DNS TTL of devstats.cncf.io/teststats.cncf.io/devstats.cd.foundation/devstats.graphql.org
      lowered to 300 s (cutover is later, but do it now).

**Friday sequence (times are cumulative estimates; every step has its gate):**

| When | What | Gate before next |
|---|---|---|
| 08:00 | `source akamai/linode-env.sh && ./akamai/create-infra.sh pilot` | 2 Linodes `running`; SSH in as root works |
| 08:30 | quick benchmark on pilots (§4: ping/iperf3/fio one-liners) | <1 ms VPC RTT, NVMe-class IOPS |
| 09:00 | `./akamai/create-infra.sh rest` | all nodes `running`; `is_compliant: true` on both placement groups |
| 09:30 | `./akamai/resize-node-disks.sh all` (sequential ~15 min/node; to parallelize run one `./akamai/resize-node-disks.sh <name>` per terminal) | every node boots, `lsblk` shows sdc |
| 11:00 | `akamai/node-setup.sh` on ALL nodes in parallel (`for h in ...; do ssh root@$h 'bash -s' < akamai/node-setup.sh & done; wait`) | `/data` mounted; containerd running; kubeadm/kubelet v1.36 installed |
| 12:00 | kubeadm init on devstats-compute-01 + join all workers (§5.2) | `kubectl get nodes` - all Ready |
| 12:30 | 1024-pods dance: flannel SubnetLen 22 + controller-manager mask 22 + kubelet maxPods (§5.3) | every node `capacity.pods: 1024` + /22 podCIDR |
| 13:00 | `./akamai/label-nodes.sh`; create namespaces; merge kubeconfig contexts prod/test/shared | labels match §1.1; `switch_context.sh` works |
| 13:15 | OpenEBS 4.5.1 + dynamic-nfs + default SC (§6) | `kubectl get sc` shows openebs-hostpath (default) + nfs-openebs-localstorage |
| 13:45 | `./akamai/install-ingresses.sh` (both classes) + `./akamai/create-nodebalancers.sh` + cert-manager + issuers (§7) | 2 ingress DaemonSets on right nodes; NB backends healthy (3/3 per NB); `curl --resolve` via NB IPs answers |
| 14:30 | secrets + PVs: `./akamai/deploy-devstats-{test,prod}.sh secrets`, `... backups-pv`, `... pvcs` (§8/§9 phase 1) | PVCs Bound |
| 15:00 | Patroni TEST: `./akamai/deploy-devstats-test.sh patroni` then `ENV=test ./akamai/patroni-tune.sh` + member restart | `patronictl list`: 1 leader + 1 replica, streaming |
| 15:30 | Patroni PROD: `./akamai/deploy-devstats-prod.sh patroni` then `ENV=prod ./akamai/patroni-tune.sh` + restart | `patronictl list`: leader + 2 replicas; `psql -c 'show shared_buffers'` = 128GB (512-node) / 64GB (256-node) |
| 16:00 | done - platform complete, empty | snapshot `kubectl get all -A | wc -l`; write down NB IPs |

Slippable to Saturday without consequence: NodeBalancers + cert-manager (nothing needs
public traffic until restores are served), and the prod patroni tune restart. NOT slippable:
disk resize before any PVC exists (§4), maxPods/flannel /22 before any workload lands.

Common Friday failure modes: G7 capacity error on create (→ ticket escalation, §4.1);
`linode-cli` action-name drift (every call is also a 1-liner in Cloud Manager UI - §4.1
step 5 documents the exact UI path); flannel pods crash-looping after SubnetLen edit
(delete the flannel DS pods + cni0/flannel.1 on each node exactly as §5.3, order matters).

---

## 14. Sizing reference (the ONLY numbers that change vs OCI)

**Live-verified 2026-08-18** against the running OCI cluster (`patronictl show-config`,
`kubectl get sts -o jsonpath`, `psql`): OCI nodes are 256 vCPU / 2 TiB RAM (+ `asgardr`
512 vCPU / 3 TiB, app-only), both patroni statefulsets run 6 members with requests
32 CPU / 128Gi and limits 160 CPU / 1Ti, image `lukaszgryglicki/devstats-patroni-18-hll`
(PostgreSQL 18.1, patroni 4.1.0, hll 2.19). Real memory in use (cgroup): prod leader
anon 0.5 GiB + shmem 510 GiB (≈ shared_buffers 500GB) + page cache; test leader
shmem 200 GiB. Those values MUST NOT be copied. The deploy scripts pass the following
as `--set` overrides (values.yaml stays untouched):

### 14.1 Prod Patroni (3 × G7-512: 64 vCPU, 512 GB, /data ≈ 7 TB)

| Helm value | OCI (live) | Linode |
|---|---|---|
| `postgresNodes` | 6 | **3** |
| `postgresStorageSize` | 23000Gi | **6000Gi** (real data: 1.9T du / 2.4T fs on leader) |
| `dbNodeSelector.node2` | devstats-db (shared prod+test!) | **devstats-db-prod** |
| `requestsPostgresCPU` / `limitsPostgresCPU` | 32000m / 160000m | **24000m / 56000m** |
| `requestsPostgresMemory` / `limitsPostgresMemory` | 128Gi / 1Ti | **96Gi / 400Gi** |

Patroni REST `/config` PATCH (applied by `ENV=prod ./akamai/patroni-tune.sh`); changes vs
the LIVE config (captured 2026-08-18, identical to README except where noted):

```
shared_buffers: 500GB → 128GB          effective_cache_size: 256GB (keep live value)
work_mem: 8GB → 2GB                    max_parallel_workers_per_gather: 28 → 16
max_worker_processes/max_parallel_workers: 32 → 32 (keep)
maintenance_work_mem: 2GB (keep)       max_connections: 1024 (keep)
temp_file_limit: 200GB (keep)          wal_keep_size: 100GB (keep)
max_wal_size: 128GB (keep)             min_wal_size: 4GB (keep)
autovacuum_*: all kept exactly as live (max_workers 1, naptime 120s, cost_limit 100, ...)
```

Rationale: memory-bound params scale with the 4× smaller box (500→128GB = 25% of node RAM,
same ratio as live 500GB/2TiB); disk-bound params (temp_file_limit, wal_keep_size,
max_wal_size) keep live values because the 6000Gi PVC affords them (2.4T data + 3.6T free);
effective_cache_size 256GB still fits (128GB shared_buffers + ~128GB cache under the 400Gi
limit). The box must also host ingress + some app pods.

#### 14.1.1 Prod Patroni on 256 GB nodes (`TOPOLOGY=8x256`/`7x256`, §1.4)

`linode-env.sh` switches these automatically when `PROD_DB_NODE_GB=256`:

| Helm value | mixed (512 GB nodes) | 8x256/7x256 (256 GB nodes) |
|---|---|---|
| `postgresStorageSize` | 6000Gi | **4500Gi** (/data ≈ 4,850 GiB after 150 GB root) |
| `requestsPostgresCPU` / `limitsPostgresCPU` | 24000m / 56000m | **16000m / 48000m** |
| `requestsPostgresMemory` / `limitsPostgresMemory` | 96Gi / 400Gi | **64Gi / 180Gi** |

`patroni-tune.sh` (reads `PROD_DB_NODE_GB`): `shared_buffers 64GB` (25% of node),
`effective_cache_size 128GB`, `work_mem 1GB`, `temp_file_limit 100GB` (smaller PVC);
everything else identical to the 512 profile. Same ratios as live OCI, one binary size down.

### 14.2 Test Patroni (2 × G7-256: 56 vCPU, 256 GB, /data ≈ 4.85 TB)

| Helm value | OCI (live) | Linode |
|---|---|---|
| `postgresNodes` | 6 | **2** |
| `postgresStorageSize` | 23000Gi | **3600Gi** (real data: 283G du - huge headroom) |
| `dbNodeSelector.node2` | devstats-db | **devstats-db-test** |
| `requestsPostgresCPU` / `limitsPostgresCPU` | 32000m / 160000m | **8000m / 40000m** |
| `requestsPostgresMemory` / `limitsPostgresMemory` | 128Gi / 1Ti | **48Gi / 160Gi** |

Patroni PATCH vs LIVE test config: `shared_buffers 250GB → 48GB` (250GB is the live DCS
value; runtime still shows 500GB because the patch was never restart-applied on OCI - on
Linode our PATCH + rolling restart applies 48GB for real), `work_mem 4GB → 1GB`,
`max_worker_processes/max_parallel_workers 16 (keep live)`, `max_parallel_workers_per_gather
28 → 8`, `effective_cache_size 128GB (keep live)`, `temp_file_limit 200GB (keep)`,
`wal_keep_size 100GB (keep)`, `max_wal_size 128GB (keep)`.

### 14.3 Job/pod caps (whole cluster)

- `limitsProvisionsMemory`: default stays, but manual overrides ≤ **400Gi** (fits only prod-db
  nodes) or ≤ **180Gi** (fits any node). The README's `640Gi`/`1Ti` examples are OCI-only.
- `nCPUs` for provisioning: ≤ 32 on prod-db nodes, ≤ 16 elsewhere (56/64 vCPU nodes).
- Backups PV: keep `2Ti` (live content is 149G in 792 files - fits compute-node disks fine).
- Grafanas/API/statics/syncs: defaults are small; no change. Live prod runs 1235 pods
  (242 grafanas, 247 deployments, 252 services, 486 cronjobs, 8 ingresses), test runs
  76 pods / 26 cronjobs / 2 ingresses. Live per-node requests on OCI: ~66 CPU / ~260Gi
  → on 7 Linode nodes the same workload minus 9 patroni members fits: ≈150 CPU /
  ≈600Gi total requests vs 416 vCPU / 2.5 TiB capacity.

---

## 15. Version matrix ("newest" policy)

Install the newest stable of each at execution time. Column 3 = newest as of 2026-08-18
(re-check on install day); column 2 = live-verified on the OCI cluster:

| Component | OCI today (live-verified) | Linode target (newest, 2026-08-18) |
|---|---|---|
| Ubuntu | 24.04.3 LTS | **26.04 LTS** (mandatory; custom image upload if not in catalog) |
| Kubernetes | v1.35.0 | **v1.36.3** (`pkgs.k8s.io` stream `v1.36`, `K8S_STREAM` in linode-env.sh) |
| containerd / runc / crictl | 2.1.4 / 1.3.0 / 1.34.0 | **2.3.4 / 1.5.1 (distro pkg ok) / v1.36.0** |
| flannel | v0.27.4 | **v0.28.9** (pinned release manifest URL, §5.2) |
| helm | 4.0.4 | **4.2.4** |
| OpenEBS | 3.10.0 | **4.5.1** (umbrella chart; enable only localpv hostpath - see §6 note) |
| OpenEBS dynamic-nfs | 0.11.0 | **0.11.0** (still the latest release; unchanged) |
| ingress-nginx chart | 4.13.3 (controller v1.13.3) | **4.15.1** |
| cert-manager | v1.19.2 | **v1.21.1** |
| PostgreSQL / Patroni | 18.1 / 4.1.0 (`devstats-patroni-18-hll`, hll 2.19, postgres_fdw local-socket) | same image family; newest = **PG 18.6 / patroni 4.1.5** - rebuild `devstats-docker-images/images/Dockerfile.patroni.18` right before migration, or reuse the exact current image (restores are pg_dump-based, minor-version mismatch is a non-issue) |
| Grafana | 8.5.27 (custom image) | unchanged (do not upgrade during migration) |

**OpenEBS 4.x note**: the 4.x umbrella chart bundles Mayastor/replicated storage which we do
NOT want. Install with replicated + LVM + ZFS engines disabled so only `localpv-provisioner`
(hostpath) is active, then install `dynamic-nfs-provisioner` 0.11.0 exactly as on OCI:

```bash
helm install openebs openebs/openebs -n openebs --create-namespace \
  --set engines.replicated.mayastor.enabled=false \
  --set engines.local.lvm.enabled=false \
  --set engines.local.zfs.enabled=false \
  --set localpv-provisioner.hostpathClass.isDefaultClass=true
kubectl get sc   # must show openebs-hostpath (default)
# then dynamic-nfs (unchanged vs OCI, creates nfs-openebs-localstorage SC via k8s/ manifests)
```

If anything looks off with 4.5.1 on install day, falling back to the OCI-proven
`openebs 3.10.0 + nfs-provisioner 0.11.0` pair is fully supported and zero-risk.

Docker images: nothing else changes - all `lukaszgryglicki/devstats*` images are
provider-independent and pulled from Docker Hub.

---

## 16. Firewalls - the two options (choose one; switchable anytime) + other hardening

Both options are fully scripted (`akamai/create-firewall.sh`, driven by `FW_MODE` in
`linode-env.sh`). Switching between them is a ~2-minute, zero-downtime operation in either
direction. Verified against techdocs `post-firewalls`/`post-firewall-device` (2026-06):
without a Cloud Firewall ALL ports on the public IP are open; a Linode has at most one
firewall; with legacy config-profile interfaces (what `create-infra.sh` builds) the firewall
attaches to the Linode and filters both its public and VPC interfaces.

### Option A - no firewall at all (`FW_MODE=open`, the simplest thing that works)

No Cloud Firewall, no ufw/nftables on nodes. Functionally identical to today's OCI posture
(allow-all NSGs) - zero new failure modes during the migration.

- Exposed on every node public IP (via 1:1 NAT): SSH 22 (key-only auth), kube-apiserver
  6443 (TLS cert auth), kubelet 10250 (cert auth), NodePorts 30000-32767 (the two
  nginx-ingress classes), etcd 2379-2380 on the master (kubeadm etcd binds 127.0.0.1 AND
  the VPC IP, and 1:1 NAT forwards the public IP to the VPC IP - so it IS reachable, but
  requires mTLS client certs; one more argument for Option B), anything a future
  hostNetwork pod binds.
- Protection = the same thing that protects OCI today: key-only SSH, mTLS on all k8s
  control-plane ports, nginx in front of everything HTTP.
- Cost of a mistake: a service accidentally bound to 0.0.0.0 is internet-reachable.
- When to choose: during the 2-week migration (fewest moving parts), and afterwards if
  OCI-parity is considered good enough. **This is the default in the scripts.**

```bash
# nothing to do; verify nothing is attached:
FW_MODE=open ./akamai/create-firewall.sh
```

### Option B - one shared allowlist firewall (`FW_MODE=allowlist`)

ONE Cloud Firewall `devstats-nodes-fw` attached to all 7-8 nodes (free of charge, filtering
happens at the hypervisor, zero agents on nodes):

| Rule | Proto/Ports | Source | Why |
|---|---|---|---|
| inbound default | - | - | **DROP** |
| `vpc-tcp` | TCP 1-65535 | 10.60.0.0/24 | all node↔node k8s traffic (apiserver, kubelet, etcd, NodePorts, patroni 8008/5432) |
| `vpc-udp` | UDP 1-65535 | 10.60.0.0/24 | flannel vxlan 8472, DNS |
| `icmp` | ICMP | 0.0.0.0/0 | ping/path-MTU |
| `ssh` | TCP 22 | `ADMIN_CIDRS` | admin SSH |
| `kube-apiserver` | TCP 6443 | `ADMIN_CIDRS` | kubectl/helm from workstation |
| outbound default | - | - | ACCEPT |

- Public 80/443/NodePorts stay **closed on the nodes** - internet traffic enters only
  through the NodeBalancers, whose backend/health-check traffic originates INSIDE the VPC
  subnet (VPC-integrated NBs hold a /30 in 10.60.0.0/24) and is covered by the vpc-* rules.
  Let's Encrypt HTTP-01 also arrives via NB:80 → NodePort - unaffected.
- Pod-to-pod traffic between nodes travels vxlan-encapsulated (outer = node VPC IPs, UDP
  8472) - covered; the firewall never sees pod IPs.
- REQUIRES: VPC-attached NodeBalancers (the default in `create-nodebalancers.sh`). If the
  classic-NB fallback was used, add a rule allowing TCP 30000-32767 from 192.168.255.0/24
  (NB backend source range) before enabling Option B.
- Set `ADMIN_CIDRS` to your workstation/VPN CIDRs (comma-separated). Leaving the default
  `0.0.0.0/0` still shrinks the surface to 22+6443 - already a big win.
- Cost of a mistake: locking yourself out of SSH/kubectl → fix via **Lish** web console
  (out-of-band, never firewalled) or `./akamai/create-firewall.sh detach`.

```bash
export FW_MODE=allowlist ADMIN_CIDRS="203.0.113.7/32"   # your IPs
./akamai/create-firewall.sh          # create/update rules + attach to all nodes
./akamai/create-firewall.sh detach   # instant rollback to Option A
```

**Recommendation**: migrate with Option A (identical-to-OCI behavior removes one variable);
flip to Option B in the soak week (day 12-13) once NodeBalancer/VPC paths are proven - test
on ONE node first (`linode-cli firewalls device-create <fw> --id <one-node> --type linode`),
verify SSH/kubectl/NB, then attach the rest.

### Other post-migration hardening (optional)

1. sshd: `PasswordAuthentication no` + `PermitRootLogin prohibit-password` (§4.2).
2. Move long-term backups off-cluster (Akamai Object Storage bucket + s3cmd cron).
3. etcd snapshot cron on the master (`etcdctl snapshot save`) - single-master model
   makes `/data/etcd` + `/etc/kubernetes` backups the DR story for the control plane.

---

## 17. Risks and mitigations

| Risk | Mitigation |
|---|---|
| G7-512 limited availability (not in public catalog) | Akamai ticket day 0; **primary fallback: `TOPOLOGY=8x256` (§1.4) - orderable today, prod DB (1.77 TB, gate-verified) fits 256 GB nodes' 4500Gi PVC with 2× headroom**; last resort 7x256 or g8-dedicated-512-256 |
| Post-shrink prod DB > 5.5 TB | gate 3.1 fails → renegotiate (4th 512 node changes nothing - capacity is per-node; need bigger plan or split DBs) |
| Local-disk perf worse than OCI NVMe RAID-10 | pilot fio/pgbench gate (phase B); Patroni params already downsized; if unacceptable → escalate to Akamai before building everything |
| Restore window too long for gha/allprj | start them first (day 6); dumps download over HTTPS at NB speed; parallel `pg_restore` jobs are inside restore.sh; worst case accept older dump + GHA backfill |
| LE rate limits during cert issuance | `tlsMaxHostsPerCert=35` SAN batching (existing); don't churn ingresses; staging issuer available in cert-issuer example if needed |
| 2-member test Patroni loses a node | remaining member continues (k8s-DCS); rebuild replica = pod reschedule; if paranoid → 3rd member via compute-02 relabel |
| Single k8s master dies | pods (incl. Patroni) keep running; rebuild master from /data/etcd backup; accepted trade-off (same as OCI today) |
| Provisioning jobs OOM on smaller nodes | hard rule: manual jobs ≤ 400Gi/32 CPU; big one-offs run on prod-db nodes via `dbNodeSelector`-style overrides |
| NodeBalancer VPC-backend feature gaps in CLI | `create-nodebalancers.sh` falls back to instructing Cloud Manager UI creation; backends can also use private IPs if VPC backends unavailable in region |

---

## 18. Secrets checklist (copy from OCI workstation, never commit)

`devstats-helm/secrets/`: `GF_SECURITY_ADMIN_PASSWORD.secret`, `GF_SECURITY_ADMIN_USER.secret`,
`GHA2DB_GITHUB_OAUTH.secret`, `PG_ADMIN_USER.secret`, `PG_HOST.secret`, `PG_HOST_RO.secret`,
`PG_PASS.secret`, `PG_PASS_REP.secret`, `PG_PASS_RO.secret`, `PG_PASS_TEAM.secret`,
`PG_PORT.secret`, `PG_USER_RO.secret` (all must be single-line, no trailing newline - verify:
`cat devstats-helm/secrets/*.secret` prints one long line). Plus `cert/cert-issuer.yaml.secret`.
PG_HOST stays `devstats-postgres` / PG_HOST_RO `devstats-postgres-ro` (in-cluster service names -
unchanged). Passwords: reuse existing (same DB contents) - rotation optional post-migration.

---

## 19. Script index (`akamai/`)

| Script | Purpose | Replaces (OCI) |
|---|---|---|
| `linode-env.sh` | single source of truth: region, plans, **`TOPOLOGY=mixed\|8x256\|7x256`**, names, IPs, **`FW_MODE`**, NB ports, topology-aware patroni sizing | `oci/oci-env.sh`, `*.secret` env files |
| `create-infra.sh [pilot\|rest\|all]` | VPC, subnet, placement groups, 7-8 Linodes (manual VPC IPs, 1:1 NAT, PGs; topology-aware) | OCI instance/console setup |
| `resize-node-disks.sh [node\|all]` | shrink root→150 GB, drop swap, create+attach ext4 `data` disk | `mdadm` RAID-10 section |
| `node-setup.sh` | full per-node OS + containerd + kubeadm/kubelet/kubectl + sysctls + /data layout | README "Shared steps" |
| `label-nodes.sh` | apply node/node2/ingress labels per section 1.1 (auto-detects compute-03) | README label loop |
| `install-ingresses.sh` | both ingress-nginx releases with exact OCI flags/NodePorts | README nginx-ingress section |
| `create-firewall.sh [apply\|detach]` | firewall Option A/B per §16 (`FW_MODE=open\|allowlist`), attach/detach all nodes | OCI NSGs (allow-all) |
| `create-nodebalancers.sh` | 2 NodeBalancers, TCP 80/443 → NodePorts, ingress-node backends | `oci/nlb-setup.sh`, `oci/oci-create-nlbs.sh` |
| `patroni-tune.sh` (`ENV=prod\|test`) | PATCH Patroni /config with Linode-sized parameters (baseline = live OCI config captured 2026-08-18; honors `PROD_DB_NODE_GB`) | README curl PATCH blocks |
| `deploy-devstats-prod.sh <phase>` | helm sequence for prod with Linode sizing overrides (phases incl. `affs-import`) | README prod install commands + live `devstats-prod-affs-import` |
| `deploy-devstats-test.sh <phase>` | helm sequence for test with Linode sizing overrides (phases incl. `affs-import`) | README test install commands + live `devstats-test-affs-import` |

Existing repo tooling reused unchanged: `scripts/deploy_prod.sh`, `scripts/deploy_backup_to_prod.sh`,
`scripts/deploy_backup_to_test.sh`, `scripts/helm_install_set.sh`, `reinit_seq.sh`,
`orphan_restore_seq.sh`, `switch_context.sh`, `k8s/update_ingress_limits.sh`,
`k8s/test-networking.sh`, `../devstats-k8s-lf/util/*` helpers.

**Note:** every consumer script above **self-sources `akamai/linode-env.sh`** (bash arrays like
`NODES` cannot cross process boundaries, so relying on a prior `source` alone would fail).
`source akamai/linode-env.sh && ./akamai/<script>.sh` still works (idempotent), but a forgotten
`source` is harmless - just `export TOPOLOGY=...`/`FW_MODE=...`/`ROOT_PASS=...` overrides
before running and the scripts pick everything else up themselves.
