DevStats deployment on Akamai Cloud (Linode) dedicated Kubernetes nodes using Helm.

This is deployed:
- [CNCF prod](https://devstats.cncf.io), [CNCF test](https://teststats.cncf.io), [CDF](https://devstats.cd.foundation), [GraphQL](https://devstats.graphql.org).

# Current architecture (since 2026-08, migrated from Oracle OCI)

- 8 × Linode `g7-dedicated-256-56` (56 vCPU, 256 GB RAM, 5 TB NVMe each), region `us-ord`, VPC `10.60.0.0/24`:
  - `devstats-compute-01` (`10.60.0.31`) - Kubernetes master + web/ingress,
  - `devstats-compute-02` (`10.60.0.32`), `devstats-compute-03` (`10.60.0.33`) - web/ingress + sync workers,
  - `devstats-prod-db-01..03` (`10.60.0.11-13`) - prod Patroni PostgreSQL (leader + 2 replicas),
  - `devstats-test-db-01..02` (`10.60.0.21-22`) - test Patroni PostgreSQL (leader + 1 replica).
- Kubernetes `1.36.x` installed with `kubeadm`, flannel CNI, `/22` pod CIDRs, up to 1024 pods per node.
- `ingress-nginx` `v1.15.1` (chart `4.15.1`), two independent controllers/classes: `nginx-prod` + `nginx-test`.
- `cert-manager` with per-namespace Let's Encrypt issuers; TLS certificates are bucketed per domain
  (a domain that cannot pass ACME validation can never block certificate issuance for other domains).
- Two Linode NodeBalancers (TCP pass-through 80/443 → ingress NodePorts): prod `172.233.210.24`, test `172.233.210.165`.
- Storage: OpenEBS (`openebs-hostpath` on `/data`, 4.8 TB btrfs per node) + OpenEBS dynamic NFS provisioner (shared backups volume).
- PostgreSQL 17 via Patroni (Zalando spilo images), streaming replication, sync/backup jobs run as Kubernetes CronJobs.
- Namespaces: `devstats-prod` (~240 projects) and `devstats-test` (~13 projects).

# Installation

The complete, command-by-command install + migration runbook (infrastructure creation, Kubernetes,
storage, Patroni, ingress, certificates, restores, DNS cutover, validation) is in
[devstats-linodes-migration-step-by-step.md](devstats-linodes-migration-step-by-step.md).

Helper scripts for the Linode infrastructure live in [akamai/](akamai/).

Adding/archiving projects, backups and other operational docs:
[ADDING_NEW_PROJECTS.md](ADDING_NEW_PROJECTS.md), [ARCHIVING.md](ARCHIVING.md),
[BACKUPS.md](BACKUPS.md), [GRADUATING.md](GRADUATING.md), [ADD_ORG_REPO.md](ADD_ORG_REPO.md).

# Historical deployments

- Oracle Cloud Infrastructure (2025-2026): [oci/README_oci.md](oci/README_oci.md) + [oci/](oci/) scripts.
- Equinix Metal: [equinix/README_equinix.md](equinix/README_equinix.md).
- Packet (pre-Equinix): [equinix/README-prev.md](equinix/README-prev.md).
