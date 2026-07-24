# DevStats deployment on Akamai Cloud using self-managed Kubernetes

## Status

This document describes the planned migration of DevStats from Oracle OCI to
Akamai Cloud/Linode.

The final number and type of nodes depend on:

1. Akamai capacity in a single US core compute region.
2. Availability of G7 Dedicated 512 GB instances.
3. LF/CNCF credit approval.
4. Final production and test database sizes after the current database shrink.
5. Storage and network benchmark results on pilot instances.

The supported range is:

- Minimum: 6 × G7 Dedicated 256 GB.
- Preferred fallback when 512 GB instances are unavailable: 9 × G7 Dedicated 256 GB.
- Maximum: 4 × G7 Dedicated 512 GB plus 6 × G7 Dedicated 256 GB.

All nodes are members of one Kubernetes cluster.

---

# 1. Fixed architecture decisions

The deployment uses:

- One Akamai core compute region.
- One Akamai VPC.
- One VPC subnet.
- One self-managed Kubernetes cluster installed with `kubeadm`.
- One Kubernetes control-plane/master node.
- All nodes, including the master, remain schedulable for application workloads.
- One `devstats-prod` namespace.
- One `devstats-test` namespace.
- One production Patroni cluster.
- One test Patroni cluster.
- OpenEBS local storage using the SSD capacity included with each Linode.
- An OpenEBS-backed NFS provisioner for DevStats RWX storage.
- Two ingress-nginx installations:
  - `nginx-prod`
  - `nginx-test`
- Two Akamai NodeBalancers:
  - one for production;
  - one for test.
- Ubuntu 26.04 LTS on every node.
- Fixed/manual VPC IPv4 addresses.
- Public IPv4 access through Akamai 1:1 NAT for simple administration and
  outbound internet access.
- Strict anti-affinity Placement Groups for Patroni nodes.

The deployment does not use:

- LKE or LKE Enterprise.
- Multiple Kubernetes clusters.
- Multiple Kubernetes control-plane nodes.
- Dedicated control-plane instances.
- MetalLB.
- VLANs.
- Akamai Block Storage for Patroni PGDATA.
- GPUs.
- Disk encryption.
- OCI VCN, NSG, VNIC, NLB, OCID, or availability-domain objects.
- OCI-specific `mdadm` RAID creation.

---

# 2. Hardware profiles

## 2.1 Minimum configuration

The minimum configuration has no database-free compute nodes.

| Pool | Quantity | Plan | Per-node resources |
|---|---:|---|---|
| Production Patroni | 3 | G7 Dedicated 256 GB | 56 vCPUs, 256 GB RAM, 5,000 GB local SSD |
| Test Patroni | 3 | G7 Dedicated 256 GB | 56 vCPUs, 256 GB RAM, 5,000 GB local SSD |

Total:

- 6 nodes
- 336 dedicated vCPUs
- 1,536 GB RAM
- 30 TB decimal local SSD
- Approximately 27.3 TiB aggregate local SSD
- Public VM list-price cap: approximately USD 16,590/month before credits

All six nodes also run Grafanas, cron jobs, API pods, provisioning jobs, ingress,
and other DevStats workloads.

In this profile, `devstats-test-db-01` is also the Kubernetes master.

This profile is feasible only when:

- production safely fits on a G7 256 GB node;
- test safely fits on a G7 256 GB node;
- enough residual local storage remains for container images, logs, OpenEBS
  project PVCs, and the shared NFS volume.

## 2.2 Preferred all-256 GB fallback

Use this profile if G7 512 GB instances are unavailable but LF/CNCF can approve
nine G7 256 GB instances.

| Pool | Quantity | Plan | Per-node resources |
|---|---:|---|---|
| Production Patroni | 3 | G7 Dedicated 256 GB | 56 vCPUs, 256 GB RAM, 5,000 GB local SSD |
| Test Patroni | 3 | G7 Dedicated 256 GB | 56 vCPUs, 256 GB RAM, 5,000 GB local SSD |
| Database-free compute | 3 | G7 Dedicated 256 GB | 56 vCPUs, 256 GB RAM, 5,000 GB local SSD |

Total:

- 9 nodes
- 504 dedicated vCPUs
- 2,304 GB RAM
- 45 TB decimal local SSD
- Approximately 40.9 TiB aggregate local SSD
- Public VM list-price cap: approximately USD 24,885/month before credits

In this profile, `devstats-compute-01` is the Kubernetes master.

## 2.3 Maximum configuration

This is the preferred configuration when four G7 512 GB nodes are available.

| Pool | Quantity | Plan | Per-node resources |
|---|---:|---|---|
| Production Patroni | 4 | G7 Dedicated 512 GB | 64 vCPUs, 512 GB RAM, 7,200 GB local SSD |
| Test Patroni | 3 | G7 Dedicated 256 GB | 56 vCPUs, 256 GB RAM, 5,000 GB local SSD |
| Database-free compute | 3 | G7 Dedicated 256 GB | 56 vCPUs, 256 GB RAM, 5,000 GB local SSD |

Total:

- 10 nodes
- 592 dedicated vCPUs
- 3,584 GB RAM
- 58.8 TB decimal local SSD
- Approximately 53.5 TiB aggregate local SSD
- Public VM list-price cap: approximately USD 38,710/month before credits

In this profile, `devstats-compute-01` is the Kubernetes master.

## 2.4 Intermediate configurations

The valid range between minimum and maximum is:

- Production Patroni: 3 or 4 nodes.
- Test Patroni: exactly 3 nodes.
- Database-free compute: 0 to 3 nodes.

Each additional G7 Dedicated 256 GB compute node adds:

- 56 dedicated vCPUs
- 256 GB RAM
- 5 TB local SSD
- approximately USD 2,765/month of public list-price consumption

The Patroni minimum is three members for both production and test.

---

# 3. Effective database storage capacity

Aggregate cluster storage is not the effective capacity of a Patroni database.

Every Patroni member contains a full PostgreSQL copy. The production database
must therefore fit on one production node, and the test database must fit on one
test node.

## G7 Dedicated 512 GB

Advertised capacity:

- 7,200 GB decimal
- approximately 6.55 TiB

After allocating approximately 100–150 GB for Ubuntu and system storage, the
remaining local data allocation is approximately:

- 7,050–7,100 GB decimal
- approximately 6.41–6.46 TiB

A planning ceiling of approximately `6000Gi` for the PostgreSQL PVC leaves
useful space for:

- filesystem overhead;
- WAL accumulation;
- PostgreSQL temporary files;
- reindexing;
- vacuum operations;
- container images and logs;
- OpenEBS metadata;
- operational growth.

The final PVC size must be selected from the post-shrink production measurement,
not from the advertised plan size alone.

## G7 Dedicated 256 GB

Advertised capacity:

- 5,000 GB decimal
- approximately 4.55 TiB

After allocating approximately 100–150 GB for Ubuntu and system storage, the
remaining local data allocation is approximately:

- 4,850–4,900 GB decimal
- approximately 4.41–4.46 TiB

A planning ceiling of approximately `4000Gi` for a PostgreSQL PVC leaves some
space for maintenance, WAL, system storage, container images, and growth.

If the shrunken production database does not fit safely within this capacity,
the all-256 GB fallback cannot be used for production. Production then requires
the 512 GB plan, a custom larger local-storage shape from Akamai, or a separately
benchmarked network storage design.

---

# 4. Node inventory and addresses

Create one VPC:

```text
VPC:       devstats-vpc
Subnet:    devstats-nodes
VPC CIDR:  10.60.0.0/24
```

Reserve addresses as follows.

| Hostname | VPC address | Function |
|---|---:|---|
| `devstats-prod-db-01` | `10.60.0.11` | Production Patroni |
| `devstats-prod-db-02` | `10.60.0.12` | Production Patroni |
| `devstats-prod-db-03` | `10.60.0.13` | Production Patroni |
| `devstats-prod-db-04` | `10.60.0.14` | Optional fourth production Patroni member |
| `devstats-test-db-01` | `10.60.0.21` | Test Patroni; master in the six-node profile |
| `devstats-test-db-02` | `10.60.0.22` | Test Patroni |
| `devstats-test-db-03` | `10.60.0.23` | Test Patroni |
| `devstats-compute-01` | `10.60.0.31` | Compute; master when compute pool exists |
| `devstats-compute-02` | `10.60.0.32` | Compute |
| `devstats-compute-03` | `10.60.0.33` | Compute |

Profile membership:

### Minimum six-node profile

Use:

```text
devstats-prod-db-01
devstats-prod-db-02
devstats-prod-db-03
devstats-test-db-01
devstats-test-db-02
devstats-test-db-03
```

All are G7 Dedicated 256 GB.

Master:

```text
devstats-test-db-01
```

### Nine-node all-256 GB profile

Use:

```text
devstats-prod-db-01
devstats-prod-db-02
devstats-prod-db-03
devstats-test-db-01
devstats-test-db-02
devstats-test-db-03
devstats-compute-01
devstats-compute-02
devstats-compute-03
```

All are G7 Dedicated 256 GB.

Master:

```text
devstats-compute-01
```

### Maximum ten-node profile

Use all listed nodes.

Plans:

```text
devstats-prod-db-01..04:  G7 Dedicated 512 GB
devstats-test-db-01..03:  G7 Dedicated 256 GB
devstats-compute-01..03:  G7 Dedicated 256 GB
```

Master:

```text
devstats-compute-01
```

Add the complete inventory to `/etc/hosts` on every node, including an alias for
the active master:

```text
10.60.0.11 devstats-prod-db-01
10.60.0.12 devstats-prod-db-02
10.60.0.13 devstats-prod-db-03
10.60.0.14 devstats-prod-db-04

10.60.0.21 devstats-test-db-01
10.60.0.22 devstats-test-db-02
10.60.0.23 devstats-test-db-03

10.60.0.31 devstats-compute-01
10.60.0.32 devstats-compute-02
10.60.0.33 devstats-compute-03
```

Add this alias according to the chosen profile:

```text
10.60.0.21 devstats-master
```

or:

```text
10.60.0.31 devstats-master
```

---

# 5. Physical placement and network proximity

## Requirement

Patroni replicas must be:

- in the same Akamai core region;
- in the same data center;
- on the same VPC and subnet;
- on different physical hosts;
- connected through the same regional network fabric.

They must not share one physical host.

Placing multiple Patroni replicas on the same physical host would allow one host
failure to remove multiple database members simultaneously.

## Placement Groups

Create strict anti-affinity Placement Groups.

### Production group

```text
Name:    devstats-prod-pg
Type:    Anti-affinity
Policy:  Strict
```

Members:

- three production nodes in minimum and all-256 profiles;
- four production nodes in the maximum profile.

### Test group

```text
Name:    devstats-test-pg
Type:    Anti-affinity
Policy:  Strict
```

Members:

- all three test nodes.

### Compute group

Create this only when compute nodes exist:

```text
Name:    devstats-compute-pg
Type:    Anti-affinity
Policy:  Strict
```

Members:

- one to three compute nodes.

Placement Groups do not create separate networks or separate Kubernetes
clusters. They control physical-host placement only.

All nodes remain on the same VPC, same subnet, and same Kubernetes cluster.

## Meaning of "close"

Akamai's current public Placement Group workflow exposes anti-affinity, not
affinity. It can guarantee separate hosts in one region, but the public interface
does not provide a same-rack or same-row placement control.

The correct public-cloud approximation is therefore:

```text
same core region
+ same VPC
+ same subnet
+ strict anti-affinity
```

Before ordering all nodes, ask Akamai support to confirm that:

- all nodes will be in one physical facility;
- all nodes use the same low-latency regional fabric;
- private VPC traffic remains inside that facility;
- replacement nodes can be supplied in the same region;
- all required G7 capacity can be provisioned simultaneously.

Benchmark VPC latency and throughput with `ping`, `iperf3`, PostgreSQL replica
creation, and WAL streaming before migration.

---

# 6. Akamai cloud object inventory

## Required objects

| Object | Quantity |
|---|---:|
| Akamai core compute region | 1 |
| VPC | 1 |
| VPC subnet | 1 |
| Production Placement Group | 1 |
| Test Placement Group | 1 |
| Compute Placement Group | 0 or 1 |
| G7 compute instances | 6–10 |
| Per-node public IPv4 through 1:1 NAT | 6–10 |
| Production NodeBalancer | 1 |
| Test NodeBalancer | 1 |
| Production public DNS records | Existing records updated at cutover |
| Test public DNS records | Existing records updated at cutover |

## Optional objects

| Object | Purpose |
|---|---|
| One shared Cloud Firewall | Provider-level filtering of node public access |
| NodeBalancer Cloud Firewall | Restrict NodeBalancer frontends, normally unnecessary when only ports 80/443 are configured |
| Object Storage bucket | Off-node PostgreSQL, WAL, etcd, and DevStats backup retention |
| Reserved NodeBalancer IPs | Preserve public frontend addresses independently of a NodeBalancer rebuild |

## Objects not required

```text
VLAN
MetalLB
LKE
LKE Enterprise
Akamai Block Storage for Patroni
GPU instances
disk encryption
dedicated control-plane instances
Kubernetes API NodeBalancer
```

---

# 7. VPC, public IP, and VLAN decision

## VPC

Use one VPC and one subnet for all nodes.

The VPC replaces the OCI VCN and private subnet.

All Kubernetes, Patroni, PostgreSQL replication, OpenEBS, kubelet, and ingress
backend traffic must use VPC addresses.

## Public IPv4 access

For the simplest deployment, enable:

```text
Allow public IPv4 access / 1:1 NAT
```

on every node's VPC interface.

This provides:

- SSH administration;
- Ubuntu package downloads;
- container image downloads;
- GitHub access;
- outbound access required by DevStats;
- a stable public address while the Linode exists.

Do not add a separate VLAN or an additional private-network design.

A more isolated design would remove public access from worker nodes and add an
egress proxy or gateway. That is intentionally outside this plan because it
would add extra infrastructure and operational complexity.

## VLANs

Do not create a VLAN.

A VLAN would duplicate the private connectivity already provided by the VPC and
would require separate routing and address management.

---

# 8. Cloud Firewall decision

Cloud Firewalls are not required for:

- VPC connectivity;
- Kubernetes;
- Patroni;
- OpenEBS;
- NodeBalancers;
- ingress-nginx.

It is possible to deploy every node by selecting:

```text
No firewall
```

## What no firewall means

Without a Cloud Firewall there is no Akamai provider-level inbound filter.

This does not make every possible port active. It means that every port on which
the operating system or a process is listening may be reachable through the
node's public 1:1 NAT address.

Potentially reachable services can include:

- SSH;
- Kubernetes API;
- kubelet;
- NodePorts;
- Patroni REST API;
- PostgreSQL, if bound to a public-reachable interface;
- monitoring agents;
- future host-network pods.

Although DevStats data is public, the infrastructure contains non-public
administrative assets:

- GitHub OAuth tokens;
- PostgreSQL passwords;
- PostgreSQL replication credentials;
- Grafana administrator credentials;
- Kubernetes certificates;
- Kubernetes service-account tokens;
- write access to production databases.

## Recommended rollout

To minimize firewall-related troubleshooting:

1. Create pilot nodes without a Cloud Firewall.
2. Build and validate VPC connectivity.
3. Build Kubernetes.
4. Validate Patroni and NodeBalancer traffic.
5. Create one simple shared firewall.
6. Attach it to one non-master node.
7. Validate that the node remains healthy.
8. Attach it to the remaining nodes one at a time.

Recommended policy:

```text
Inbound default: DROP
Outbound default: ACCEPT

Allow all protocols from 10.60.0.0/24
Allow TCP 22 from approved administrator/VPN public CIDRs
Optionally allow ICMP from approved administrator CIDRs
Drop all other public inbound traffic
```

This closely reproduces the existing OCI model:

```text
allow all private-subnet traffic
allow all outbound traffic
do not expose backend ports directly to the internet
```

The two public NodeBalancers remain the intended public entry points.

## Alternative without Cloud Firewall

A local `nftables` or `iptables` policy can provide the same filtering. Avoid
using two competing firewall systems unless their interaction is understood.

Running permanently without either a Cloud Firewall or a host firewall is
possible, but it explicitly accepts direct internet exposure of every listening
service.

---

# 9. Why MetalLB is not used

Do not install MetalLB.

MetalLB is normally used when Kubernetes has no external cloud load balancer and
must advertise service IPs using layer-2 or BGP networking.

Akamai already provides NodeBalancers with:

- public frontend IPs;
- VPC backends;
- TCP forwarding;
- health checks;
- backend removal after failures.

The Akamai equivalent of the current OCI design is:

```text
OCI Network Load Balancer
        becomes
Akamai NodeBalancer
```

The Kubernetes ingress Services remain `NodePort`, exactly as in the current
OCI deployment.

Manual NodeBalancers are preferred over installing Linode Cloud Controller
Manager during the initial migration. This keeps the architecture close to the
existing OCI deployment and avoids automatically created load-balancer objects.

---

# 10. Ubuntu 26.04 LTS

Ubuntu 26.04 LTS is mandatory for all nodes.

## Native-image path

During instance creation, check the Cloud Manager image list for:

```text
Ubuntu 26.04 LTS
```

Use the native Akamai image when it is available.

## Custom-image path

If Ubuntu 26.04 LTS is not present:

1. Open an Akamai support request asking for Ubuntu 26.04 LTS to be enabled.
2. Alternatively obtain the official Canonical Ubuntu 26.04 cloud image.
3. Convert it to an Akamai-compatible raw disk image if necessary.
4. Use an ext4 filesystem.
5. Compress the raw image with gzip.
6. Upload it under:
   `Compute -> Images -> Create Image -> Upload Image`.
7. Mark it cloud-init compatible only after validating the image's cloud-init
   and metadata configuration.
8. Deploy one pilot Linode from the custom image.
9. Validate networking, boot, kernel, SSH, cloud-init, and package management.
10. Reuse the validated image for the remaining nodes.

Do not silently substitute Ubuntu 24.04.

## Validation

On every node:

```bash
cat /etc/os-release
lsb_release -a
uname -a
```

The installation must report Ubuntu 26.04 LTS before Kubernetes installation
begins.

## Disk encryption

Do not enable Linode disk encryption.

DevStats processes public data and the priority for this deployment is maximum
available capacity and the simplest storage path.

---

# 11. Creating the Linodes

## Pilot phase

Do not create all final nodes immediately.

First create:

```text
1 × G7 Dedicated 256 GB
```

If available, also create:

```text
1 × G7 Dedicated 512 GB
```

Use final hostnames and retain these instances as production nodes after
validation.

For every pilot:

1. Select the approved single core region.
2. Select Ubuntu 26.04 LTS or the validated custom image.
3. Select the G7 Dedicated plan.
4. Assign the appropriate Placement Group.
5. Assign `devstats-vpc`.
6. Assign subnet `devstats-nodes`.
7. Assign the planned manual VPC IPv4 address.
8. Enable public IPv4 access through 1:1 NAT.
9. Select no disk encryption.
10. Initially select no Cloud Firewall if firewall troubleshooting is being
    deferred.
11. Add administrator SSH public keys.
12. Deploy the Linode.

Validate:

```bash
lscpu
free -h
lsblk --bytes
ip address
ip route
curl -4 https://ifconfig.me
```

Run VPC tests between pilots:

```bash
ping -c 100 <other-vpc-ip>
iperf3 -s
iperf3 -c <other-vpc-ip> -P 8
```

Run local-storage tests before ordering all nodes.

## Full creation

After pilot approval, create the remaining instances with:

- the same region;
- the same VPC;
- the same subnet;
- the same Ubuntu image;
- manual VPC addresses;
- 1:1 NAT public IPv4;
- the correct strict anti-affinity Placement Group;
- no disk encryption;
- identical common initialization.

Do not create nodes in multiple regions merely because one region lacks
capacity. Obtain a capacity commitment from Akamai first.

---

# 12. Included local storage

The G7 plans already include their advertised local SSD capacity.

No separately billed storage volume needs to be created or attached for the
initial design.

However, the full plan capacity may initially be allocated to the default root
disk and swap. It may not appear automatically as a separate `/data` device.

## Desired local disk layout

Use approximately:

```text
100–150 GB  Ubuntu/root disk
remaining   local data disk mounted at /data
no swap
```

Approximate result:

| Plan | Approximate `/data` capacity before filesystem overhead |
|---|---:|
| G7 Dedicated 512 GB | 7,050–7,100 GB decimal |
| G7 Dedicated 256 GB | 4,850–4,900 GB decimal |

## Creation procedure

For each node:

1. Complete the first boot and verify Ubuntu.
2. Power off the Linode.
3. Open the Linode's `Storage` page.
4. If the root disk consumes the complete plan allocation, resize it to
   approximately 100–150 GB.
5. Delete or minimize the swap disk.
6. Create an empty ext4 disk using the remaining included plan allocation.
7. Add that disk to the active configuration profile.
8. Boot the Linode.
9. Identify the disk with `lsblk`.
10. Mount it at `/data`.
11. Add its UUID to `/etc/fstab`.
12. Confirm it mounts after reboot.

Example inside the guest, after identifying the correct device:

```bash
mkdir -p /data
blkid
```

Add an `/etc/fstab` entry using the actual UUID:

```text
UUID=<actual-data-disk-uuid> /data ext4 defaults,noatime 0 2
```

Then:

```bash
mount -a
df -h /data
```

Do not assume a device name such as `/dev/sdb` without checking `lsblk`.

## No RAID

Do not copy the OCI command:

```text
mdadm --create /dev/md0 ...
```

The Linode plan exposes virtual local disks from the plan's included SSD
allocation, not eight independent OCI NVMe devices.

## Data directories

Create:

```bash
mkdir -p /data/openebs
mkdir -p /data/containerd
mkdir -p /data/kubelet
mkdir -p /data/etcd
mkdir -p /data/logs/containers
mkdir -p /data/logs/pods
```

Before installing Kubernetes, move or link the existing locations:

```text
/var/openebs         -> /data/openebs
/var/lib/containerd  -> /data/containerd
/var/lib/kubelet     -> /data/kubelet
/var/lib/etcd        -> /data/etcd       # master only
/var/log/containers  -> /data/logs/containers
/var/log/pods        -> /data/logs/pods
```

Create the links before the target services have meaningful data.

The plan-local SSD is persistent across reboots but remains tied to its Linode.
Deleting or rebuilding a database Linode destroys that local member's disk.
Patroni replication and off-node backups are therefore still required.

---

# 13. Common operating-system preparation

Apply the current `devstats-helm` common-node installation procedure to every
node, with the following Akamai substitutions.

Keep:

- containerd;
- runc;
- crictl;
- kubelet;
- kubeadm;
- kubectl;
- Helm;
- `nfs-common`;
- `overlay`;
- `br_netfilter`;
- IP forwarding;
- systemd cgroups;
- swap disabled;
- Kubernetes scale sysctls;
- `/data` locations;
- `maxPods: 1024`;
- Flannel `/22` node PodCIDRs.

Remove:

- OCI CLI installation.
- OCI VNIC commands.
- OCI source/destination-check changes.
- OCI NSG commands.
- OCI NLB scripts.
- OCI OCIDs.
- OCI availability-domain discovery.
- OCI image-discovery scripts.
- `mdadm` and NVMe RAID setup.

Use the currently pinned versions from the repository at deployment time rather
than copying old version numbers from a previous provider installation.

Ensure that Kubernetes uses each node's VPC address as its node address. After
joining, this command must show `10.60.0.x` internal addresses:

```bash
kubectl get nodes -o wide
```

---

# 14. Kubernetes cluster creation

## One master

This deployment intentionally has one Kubernetes control-plane node.

Master selection:

```text
If compute nodes exist:
    devstats-compute-01

If no compute nodes exist:
    devstats-test-db-01
```

The master remains a normal worker and runs application pods.

This reproduces the current OCI control-plane model.

The consequences are accepted:

- a master failure temporarily removes Kubernetes API and scheduling;
- already-running pods and Patroni continue to operate;
- control-plane restoration requires recovery or rebuild of the master;
- etcd and `/etc/kubernetes` backups are mandatory.

## kubeadm initialization

Use the master's VPC IP, not its public IP.

Example for a compute-pool master:

```bash
MASTER_IP=10.60.0.31

kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="10.244.0.0/16" \
  --service-cidr="10.96.0.0/12"
```

Example for the six-node profile:

```bash
MASTER_IP=10.60.0.21
```

Install kubeconfig:

```bash
mkdir -p "${HOME}/.kube"
cp /etc/kubernetes/admin.conf "${HOME}/.kube/config"
chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
```

Install Flannel using the version currently approved in the repository.

Remove the master scheduling taint:

```bash
kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule-
```

## Worker joins

Generate a join command on the master:

```bash
kubeadm token create --print-join-command
```

Run the generated command on every worker.

The join endpoint must be the master VPC address.

Do not use the public IP for node-to-control-plane communication.

## No Kubernetes API NodeBalancer

Do not create a NodeBalancer for TCP 6443.

Administration should initially occur by SSH to the master and running
`kubectl` there.

Remote administration can later use an SSH tunnel or a separately secured API
endpoint.

---

# 15. High pod-count configuration

Retain the current DevStats high-density configuration.

## Pod and service networks

```text
Pod CIDR:      10.244.0.0/16
Service CIDR:  10.96.0.0/12
Per-node CIDR: /22
```

## Flannel

Configure:

```json
{
  "Network": "10.244.0.0/16",
  "SubnetLen": 22,
  "Backend": {
    "Type": "vxlan"
  }
}
```

## kubelet

On every node, configure:

```yaml
maxPods: 1024
```

## controller manager

On the master, verify:

```text
--allocate-node-cidrs=true
--cluster-cidr=10.244.0.0/16
--node-cidr-mask-size-ipv4=22
```

## Scale sysctls

Apply the current repository settings, including:

```text
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384
fs.inotify.max_user_instances=4096
fs.inotify.max_user_watches=1048576
net.netfilter.nf_conntrack_max=2621440
net.core.somaxconn=4096
```

Do not proceed until every node reports:

- pod capacity `1024`;
- a `/22` PodCIDR.

Check:

```bash
kubectl get nodes \
  -o custom-columns=NAME:.metadata.name,CAP:.status.capacity.pods,PODCIDR:.spec.podCIDR
```

---

# 16. Node labels and workload placement

Label every node as a general DevStats application node:

```bash
kubectl label node <node> node=devstats-app
```

Label production nodes:

```bash
kubectl label node devstats-prod-db-01 devstats.cncf.io/pool=prod-db
kubectl label node devstats-prod-db-02 devstats.cncf.io/pool=prod-db
kubectl label node devstats-prod-db-03 devstats.cncf.io/pool=prod-db
```

In the four-node production profile:

```bash
kubectl label node devstats-prod-db-04 devstats.cncf.io/pool=prod-db
```

Label test nodes:

```bash
kubectl label node devstats-test-db-01 devstats.cncf.io/pool=test-db
kubectl label node devstats-test-db-02 devstats.cncf.io/pool=test-db
kubectl label node devstats-test-db-03 devstats.cncf.io/pool=test-db
```

Label compute nodes when present:

```bash
kubectl label node devstats-compute-01 devstats.cncf.io/pool=compute
kubectl label node devstats-compute-02 devstats.cncf.io/pool=compute
kubectl label node devstats-compute-03 devstats.cncf.io/pool=compute
```

Do not taint the pools.

Scheduling policy:

- Production Patroni is hard-pinned to `prod-db`.
- Test Patroni is hard-pinned to `test-db`.
- Existing Patroni hostname anti-affinity remains enabled.
- All other DevStats pods may use every node.
- Heavy non-database jobs should prefer compute nodes when compute nodes exist.
- Disk-heavy project PVCs should prefer compute or test nodes when production
  storage headroom is limited.
- CPU-only and memory-only workloads may run on production nodes when sufficient
  resources remain.

---

# 17. OpenEBS and shared storage

## Local RWO storage

Install OpenEBS using the repository's current supported chart/version.

Ensure:

```text
/var/openebs -> /data/openebs
```

Continue using local OpenEBS storage for:

- production PostgreSQL PVCs;
- test PostgreSQL PVCs;
- per-project git-clone PVCs;
- other ReadWriteOnce DevStats PVCs.

Do not add OpenEBS replicated storage beneath Patroni.

Patroni/PostgreSQL already replicates each complete database across its members.
Adding another replicated storage layer would duplicate writes, capacity, and
failure handling.

## RWX storage

Retain the existing dynamic NFS pattern for:

- DevStats backups;
- shared Grafana data;
- static files;
- reports.

The NFS server's backing PVC is still local to one Kubernetes node.

Preferred placement:

```text
When compute nodes exist:
    place the NFS backing volume on a compute node.

In the six-node profile:
    place it on the test node with the most remaining disk.
```

The current `2Ti` backup PVC may not fit safely in the six-node profile if the
test database consumes most of a 5 TB node. Set the RWX volume size from actual
remaining capacity and reduce local retention when necessary.

Long-term backups should eventually be copied to Akamai Object Storage or
another off-cluster destination.

---

# 18. ingress-nginx placement

Retain two namespace-scoped ingress-nginx installations and the current fixed
NodePorts.

## Production

```text
HTTP NodePort:   30080
HTTPS NodePort:  30443
Ingress class:   nginx-prod
Namespace:       devstats-prod
```

## Test

```text
HTTP NodePort:   31080
HTTPS NodePort:  31443
Ingress class:   nginx-test
Namespace:       devstats-test
```

Use DaemonSets with:

```text
externalTrafficPolicy=Local
```

The NodeBalancer backends must therefore be nodes that actually run the
corresponding ingress pod.

## Ingress node placement with compute nodes

When three compute nodes exist:

```text
Production ingress:
    devstats-compute-01
    devstats-compute-02
    devstats-compute-03

Test ingress:
    devstats-test-db-01
    devstats-test-db-02
    devstats-test-db-03
```

Example labels:

```bash
kubectl label node devstats-compute-01 ingress=prod
kubectl label node devstats-compute-02 ingress=prod
kubectl label node devstats-compute-03 ingress=prod

kubectl label node devstats-test-db-01 ingress=test
kubectl label node devstats-test-db-02 ingress=test
kubectl label node devstats-test-db-03 ingress=test
```

## Ingress placement in the six-node profile

```text
Production ingress:
    devstats-prod-db-01
    devstats-prod-db-02
    devstats-prod-db-03

Test ingress:
    devstats-test-db-01
    devstats-test-db-02
    devstats-test-db-03
```

---

# 19. Akamai NodeBalancers

Create two NodeBalancers manually.

Do not install MetalLB and do not initially install Linode Cloud Controller
Manager.

## Production NodeBalancer

```text
Name:     devstats-prod-web
Region:   same region as all nodes
VPC:      devstats-vpc
Subnet:   devstats-nodes
```

Configurations:

```text
Frontend TCP 80  -> backend TCP 30080
Frontend TCP 443 -> backend TCP 30443
```

Use TCP active health checks.

Backends are the VPC addresses of production ingress nodes.

With compute nodes:

```text
10.60.0.31
10.60.0.32
10.60.0.33
```

In the six-node profile:

```text
10.60.0.11
10.60.0.12
10.60.0.13
```

## Test NodeBalancer

```text
Name:     devstats-test-web
Region:   same region as all nodes
VPC:      devstats-vpc
Subnet:   devstats-nodes
```

Configurations:

```text
Frontend TCP 80  -> backend TCP 31080
Frontend TCP 443 -> backend TCP 31443
```

Backends:

```text
10.60.0.21
10.60.0.22
10.60.0.23
```

## TLS

Use TCP pass-through.

Do not terminate TLS at the NodeBalancer.

Continue terminating TLS in ingress-nginx with cert-manager. Port 80 must remain
available for HTTP-01 certificate challenges.

## DNS

At cutover:

```text
production domains -> production NodeBalancer public IP
test domains       -> test NodeBalancer public IP
```

Do not point public DevStats DNS records directly at individual Linode public
addresses.

---

# 20. Required `devstats-helm` changes

Create Akamai-specific values files:

```text
akamai/values-prod.yaml
akamai/values-test.yaml
akamai/inventory.md
akamai/README.md
```

## Production node selector

```yaml
appNodeSelector:
  node: devstats-app

dbNodeSelector:
  "devstats.cncf.io/pool": prod-db
```

## Test node selector

```yaml
appNodeSelector:
  node: devstats-app

dbNodeSelector:
  "devstats.cncf.io/pool": test-db
```

## Patroni member counts

Maximum profile:

```yaml
# Production
postgresNodes: 4

# Test
postgresNodes: 3
```

All-256 and minimum profiles:

```yaml
# Production
postgresNodes: 3

# Test
postgresNodes: 3
```

## Storage

The current value such as:

```yaml
postgresStorageSize: 23000Gi
```

must be replaced.

Set production and test storage sizes independently from the final database
measurements.

Planning ceilings:

```text
G7 512 GB node:
    approximately 6000Gi PVC maximum before detailed validation

G7 256 GB node:
    approximately 4000Gi PVC maximum before detailed validation
```

These are planning ceilings, not automatic final values.

Account for all filesystem users, not only PGDATA:

- PostgreSQL;
- WAL;
- containerd;
- kubelet;
- logs;
- OpenEBS;
- project git PVCs;
- NFS data;
- temporary files.

## PostgreSQL resources

The current values such as:

```yaml
limitsPostgresCPU: 160000m
limitsPostgresMemory: 1Ti
postgresSharedBuffers: 500GB
postgresWorkMem: 8GB
```

cannot be used on the new plans.

Suggested initial bounds for benchmarking:

### Production on G7 512 GB

```text
PostgreSQL memory limit: no more than approximately 448Gi
shared_buffers starting point: approximately 128GB
global work_mem: use MB, not multiple GB
CPU limit: no more than available allocatable CPU, or omit the CPU limit
```

### Production on G7 256 GB

```text
PostgreSQL memory limit: no more than approximately 224Gi
shared_buffers starting point: approximately 64GB
global work_mem: use MB, not multiple GB
CPU limit: no more than available allocatable CPU, or omit the CPU limit
```

### Test on G7 256 GB

```text
PostgreSQL memory limit: approximately 128–160Gi or less
shared_buffers starting point: approximately 32–64GB
global work_mem: use MB
lower worker and parallelism settings than production
```

The final values must be selected from PostgreSQL benchmarks and actual
concurrency.

## Large jobs

Review provisioning and reinitialization jobs requesting:

```text
256Gi
512Gi
640Gi
1Ti
```

A pod cannot combine memory from multiple nodes.

In the all-256 profiles, a single pod must remain below the allocatable memory
of one 256 GB node.

Oversized jobs must be:

- assigned realistic requests and limits;
- split into project groups;
- executed sequentially;
- or redesigned to use less resident memory.

---

# 21. Installation sequence

## Phase A — account and capacity

1. Obtain LF/CNCF confirmation of available Akamai credits.
2. Ask Akamai to confirm one US core region with the required capacity.
3. Ask whether four G7 Dedicated 512 GB instances are simultaneously available.
4. Ask whether replacement capacity can be retained.
5. Confirm G7 256 GB capacity for three to six instances.
6. Confirm Placement Groups in that region.
7. Confirm VPC and NodeBalancer availability.
8. Confirm Ubuntu 26.04 LTS image availability.
9. Confirm credits apply to:
   - compute;
   - NodeBalancers;
   - transfer;
   - Object Storage if used;
   - support.

## Phase B — cloud foundation

1. Select one region.
2. Create `devstats-vpc`.
3. Create subnet `devstats-nodes`, `10.60.0.0/24`.
4. Create strict production Placement Group.
5. Create strict test Placement Group.
6. Create strict compute Placement Group if compute nodes exist.
7. Prepare Ubuntu 26.04 image if the native image is unavailable.
8. Create one or two pilot Linodes.
9. Benchmark pilot storage and VPC network.
10. Create the remaining approved nodes.

## Phase C — node preparation

For every node:

1. Verify Ubuntu 26.04.
2. Configure the included local storage.
3. Mount the data disk at `/data`.
4. Disable swap.
5. Configure containerd.
6. Configure Kubernetes packages.
7. Configure kernel modules and sysctls.
8. Configure `/etc/hosts`.
9. Configure the node to use its VPC address.
10. Verify public outbound access.
11. Verify VPC connectivity to every other node.

## Phase D — Kubernetes

1. Initialize the single master using its VPC address.
2. Install Flannel.
3. Join all workers through the master VPC address.
4. Remove the master taint.
5. Configure `/22` node PodCIDRs.
6. Configure `maxPods: 1024`.
7. Apply scale sysctls.
8. Label all nodes.
9. Verify cross-node Pod networking.
10. Back up:
    - `/etc/kubernetes`;
    - `/var/lib/etcd`;
    - administrator kubeconfig.

## Phase E — storage and ingress

1. Install OpenEBS.
2. Make `openebs-hostpath` the intended local storage class.
3. Install the NFS provisioner.
4. Create `devstats-prod`.
5. Create `devstats-test`.
6. Create `prod`, `test`, and `shared` kubeconfig contexts.
7. Install test ingress-nginx.
8. Install production ingress-nginx.
9. Create the two NodeBalancers.
10. Test NodeBalancer-to-NodePort connectivity before installing DevStats.

## Phase F — test DevStats

1. Apply test secrets.
2. Create the test shared/backups PVC.
3. Create test project PVCs.
4. Deploy the three-member test Patroni cluster.
5. Apply reduced test PostgreSQL settings.
6. Verify every test Patroni member is on a different test node.
7. Restore or provision the test databases.
8. Test Patroni switchover.
9. Test complete loss and rebuild of one test replica.
10. Install test static handlers.
11. Install test ingress.
12. Install test API.
13. Install test Grafanas and Services.
14. Install test jobs with CronJobs initially suspended.
15. Run a representative provisioning workload.
16. Verify storage growth and memory use.
17. Test backup and restore.

## Phase G — production DevStats

1. Apply production secrets.
2. Create the production shared/backups PVC.
3. Create production project PVCs.
4. Deploy the production Patroni cluster:
   - four members on the maximum profile;
   - three members on the all-256/minimum profiles.
5. Verify every member is on a different production node.
6. Apply production PostgreSQL settings.
7. Restore or synchronize production data.
8. Wait until all replicas are fully caught up.
9. Perform a controlled Patroni switchover.
10. Test loss and rebuild of one replica.
11. Install production static handlers.
12. Install production ingress.
13. Install production API.
14. Install production Grafanas and Services.
15. Install production jobs with CronJobs initially suspended.
16. Execute representative provisioning and reinitialization jobs.
17. Verify backup creation and restore.

## Phase H — cutover

1. Reduce DNS TTLs.
2. Suspend OCI production CronJobs.
3. Complete final database synchronization.
4. Point test DNS at the test NodeBalancer.
5. Validate test certificates and applications.
6. Point production DNS at the production NodeBalancer.
7. Validate production certificates.
8. Enable Akamai production CronJobs.
9. Monitor:
   - Patroni state;
   - PostgreSQL replication lag;
   - filesystem capacity;
   - WAL growth;
   - memory pressure;
   - container restarts;
   - NodeBalancer health;
   - ingress errors.
10. Retain OCI during the production soak.
11. Create an Akamai-side backup.
12. Restore that backup into a temporary database or replacement replica.
13. Decommission OCI only after the restore test and soak period pass.

---

# 22. Validation gates

## Akamai infrastructure

- All nodes are in exactly one region.
- All nodes are in `devstats-vpc`.
- All nodes use subnet `devstats-nodes`.
- Production Placement Group is compliant.
- Test Placement Group is compliant.
- Compute Placement Group is compliant when used.
- Every Patroni member is on a different physical host within its group.
- Akamai confirms replacement capacity.

## Operating system

- Every node reports Ubuntu 26.04 LTS.
- No node uses disk encryption.
- No node has swap enabled.
- `/data` mounts after reboot.
- The expected included SSD capacity is visible.
- No OCI `mdadm` configuration remains.

## Network

- Every node can reach every other node over `10.60.0.0/24`.
- `kubectl get nodes -o wide` shows VPC internal addresses.
- PostgreSQL replication uses VPC addresses.
- NodeBalancer backends use VPC addresses.
- `iperf3` results are acceptable.
- Packet loss is zero or operationally negligible.
- VPC latency is comparable to or acceptable relative to OCI.

## Kubernetes

- One control-plane node is Ready.
- All workers are Ready.
- The control-plane node is schedulable.
- All nodes report pod capacity 1024.
- All nodes receive `/22` PodCIDRs.
- CoreDNS works.
- Flannel cross-node networking works.
- OpenEBS local PVC provisioning works.
- NFS RWX mounting works from multiple nodes.

## Patroni

- Production has three or four healthy members.
- Test has three healthy members.
- Every member uses a distinct Kubernetes node.
- Production members use only production nodes.
- Test members use only test nodes.
- Leader election succeeds.
- Controlled switchover succeeds.
- A stopped primary is replaced by a new primary.
- A complete replica rebuild succeeds.
- WAL does not grow without bounds.
- Storage remains below the agreed thresholds.

## DevStats

- Grafanas connect through the read-only PostgreSQL service.
- Write workloads connect through the Patroni primary service.
- Provisioning jobs complete.
- Hourly jobs complete.
- Affiliations jobs complete.
- API works.
- Static pages work.
- Ingress hostname routing works.
- cert-manager HTTP-01 validation works.
- Production and test certificates are valid.
- Backup creation succeeds.
- Backup restore succeeds.

---

# 23. Akamai support and credit request

Send Akamai/LF/CNCF the following requirement.

## Minimum

```text
6 × G7 Dedicated 256 GB
3 production Patroni nodes
3 test Patroni nodes
one US core region
one VPC
two strict Patroni anti-affinity Placement Groups
Ubuntu 26.04 LTS
two NodeBalancers
```

Resources:

```text
336 dedicated vCPUs
1,536 GB RAM
30 TB local SSD
```

## Preferred all-256 fallback

```text
9 × G7 Dedicated 256 GB
3 production Patroni nodes
3 test Patroni nodes
3 compute nodes
one US core region
one VPC
three strict anti-affinity Placement Groups
Ubuntu 26.04 LTS
two NodeBalancers
```

Resources:

```text
504 dedicated vCPUs
2,304 GB RAM
45 TB local SSD
```

## Maximum

```text
4 × G7 Dedicated 512 GB for production Patroni
3 × G7 Dedicated 256 GB for test Patroni
3 × G7 Dedicated 256 GB for compute
one US core region
one VPC
three strict anti-affinity Placement Groups
Ubuntu 26.04 LTS
two NodeBalancers
```

Resources:

```text
592 dedicated vCPUs
3,584 GB RAM
58.8 TB local SSD
```

Ask Akamai to answer:

1. Which US core region can supply each profile?
2. Are four G7 512 GB instances simultaneously available?
3. Can they be placed in one strict anti-affinity Placement Group?
4. Can replacement G7 512 GB capacity be committed?
5. Can all nodes remain inside one physical facility and one low-latency fabric?
6. Is Ubuntu 26.04 LTS available as a native image?
7. What credits are available?
8. Are the credits one-time or recurring?
9. When do the credits expire?
10. Which services consume the credits?
11. Are NodeBalancers and transfer included?
12. Are there account-level instance, CPU, and VPC quotas?
13. What is the expected local SSD performance for the G7 plans?
14. Is the full advertised storage allocatable among local Linode disks?
15. Are there any lifecycle or availability concerns for G7 512 GB?

---

# 24. Final selection logic

Use the maximum profile when all of these are true:

```text
four G7 512 GB nodes are available
credits cover the profile
production needs more than a safe G7 256 capacity
pilot G7 512 storage performance passes
```

Use the nine-node all-256 profile when:

```text
G7 512 GB is unavailable
production safely fits on G7 256
credits cover nine G7 256 nodes
```

Use the six-node minimum only when:

```text
production safely fits on G7 256
test safely fits on G7 256
non-database local storage fits in the residual capacity
no pure compute nodes are approved
performance testing is acceptable
```

Do not proceed with any profile until the post-shrink production and test sizes
are known.

The final go/no-go values are:

```text
current production database bytes
current test database bytes
production WAL growth during failure/rebuild
test WAL growth during failure/rebuild
aggregate project git-PVC usage
shared NFS usage
containerd and log usage
required free-space margin
```

The chosen profile must fit those values on each individual database node, not
only in the aggregate cluster capacity.
