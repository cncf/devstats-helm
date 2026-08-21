#!/bin/bash
# DevStats common node preparation for Akamai Linode (Ubuntu 26.04 LTS).
# Direct adaptation of README.md "Shared steps for all nodes" with OCI/mdadm parts removed:
#   - /data = btrfs + zstd on the raw "data" disk (created by resize-node-disks.sh, attached as /dev/sdc)
#   - /etc/hosts for all VPC addresses incl. compute-03 (+ devstats-master alias)
#   - containerd + runc + crictl, SystemdCgroup
#   - kubelet/kubeadm/kubectl from pkgs.k8s.io ${K8S_STREAM}, pinned to exact ${K8S_PATCH}, held
#   - swap off, bridge/netfilter modules, forwarding, scale sysctls
#   - helm, nfs-common, QoL packages
# Run as root on EVERY node:
#   scp akamai/linode-env.sh akamai/node-setup.sh root@<node>:/root/ && ssh root@<node> 'cd /root && ./node-setup.sh'
# Then, ONLY on devstats-compute-01, run the kubeadm init block from devstats-linodes-migration.md section 5.2.
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "run as root"; exit 1; }

# shellcheck disable=SC1091
[ -f ./linode-env.sh ] && source ./linode-env.sh
K8S_STREAM="${K8S_STREAM:-v1.36}"
K8S_PATCH="${K8S_PATCH:-1.36.3}"
HELM_VERSION="${HELM_VERSION:-v4.2.4}"
HELM_SHA256="${HELM_SHA256:-c306b46f719b0a4da32d0f78ee21bf90ce8d602f15b22ab753f0674d1670a7f3}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.3.4}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.36.0}"
DATA_DEV="${DATA_DEV:-/dev/sdc}"
export DEBIAN_FRONTEND=noninteractive

echo "=== [0] sanity: Ubuntu 26.04 ==="
grep -q 'VERSION_ID="26.04"' /etc/os-release || { echo "WARNING: not Ubuntu 26.04 LTS:"; grep PRETTY /etc/os-release; }

echo "=== [1] /etc/hosts (all VPC addresses + master alias; compute-03 only exists in TOPOLOGY=8x256, harmless otherwise) ==="
if ! grep -q 'devstats-prod-db-01' /etc/hosts; then
cat >> /etc/hosts <<'EOF'

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
EOF
fi

echo "=== [2] hostname from VPC IP (image boots as 'localhost'; kubelet uses hostname as node name) ==="
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

echo "=== [3] /data = btrfs + transparent zstd on the raw data disk (${DATA_DEV}) ==="
command -v mkfs.btrfs >/dev/null || apt-get install -y btrfs-progs  # preinstalled on 26.04
if ! mountpoint -q /data; then
  [ -b "${DATA_DEV}" ] || { echo "${DATA_DEV} missing - run resize-node-disks.sh for this node first"; exit 1; }
  mkdir -p /data
  # resize-node-disks.sh creates the disk as RAW (Linode can't create btrfs) - format it here.
  # DUP metadata: two copies of fs metadata - survives single-sector corruption.
  [ "$(blkid -s TYPE -o value "${DATA_DEV}")" = "btrfs" ] || mkfs.btrfs -f -L data -m dup -d single "${DATA_DEV}"
  UUID="$(blkid -s UUID -o value "${DATA_DEV}")"
  OPTS="compress-force=zstd:3,noatime,discard=async"
  OPTS+=",x-systemd.before=local-fs.target,x-systemd.requires=local-fs-pre.target"
  grep -q "${UUID}" /etc/fstab || echo "UUID=${UUID} /data btrfs ${OPTS} 0 0" >> /etc/fstab
  systemctl daemon-reload
  mount -a
fi
findmnt -no FSTYPE,OPTIONS /data | grep -q 'btrfs.*zstd' || { echo "/data is not btrfs+zstd"; exit 1; }
# monthly scrub re-verifies every checksum on cold data too (idle io class; 1st, 04:30)
echo '30 4 1 * * root /usr/bin/btrfs scrub start -c 3 /data >/dev/null 2>&1' > /etc/cron.d/btrfs-scrub-data
df -h /data

echo "=== [4] SUBVOLUMES (snapshot/rollback units) + symlinks (openebs/containerd/kubelet/etcd/logs) ==="
for sv in openebs containerd kubelet etcd logs; do
  [ -d "/data/${sv}" ] || btrfs subvolume create "/data/${sv}"
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

echo "=== [5] swap off (permanent) ==="
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

echo "=== [6] base packages ==="
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

echo "=== [7] kernel modules + sysctls ==="
# nf_conntrack must be loaded NOW or the net.netfilter.nf_conntrack_max sysctl silently
# does not exist yet (the module would only autoload once kube-proxy adds NAT rules)
cat > /etc/modules-load.d/containerd.conf <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF
modprobe overlay
modprobe br_netfilter
modprobe nf_conntrack
cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.ip_forward = 1
EOF
cat > /etc/sysctl.d/99-k8s-scale.conf <<'EOF'
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384
fs.inotify.max_user_instances=4096
fs.inotify.max_user_watches=1048576
net.netfilter.nf_conntrack_max=2621440
net.core.somaxconn=4096
EOF
sysctl --system >/dev/null
iptables -P FORWARD ACCEPT
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4

echo "=== [8] containerd ${CONTAINERD_VERSION} + runc + crictl ${CRICTL_VERSION} ==="
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
  # enable systemd cgroups (README manual edit, automated here)
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || \
    sed -i "s/\[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options\]/&\n            SystemdCgroup = true/" /etc/containerd/config.toml
fi
systemctl enable --now containerd
if ! command -v crictl >/dev/null; then
  curl -fsSL -o /tmp/crictl.tgz "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  tar -C /usr/local/bin -xzf /tmp/crictl.tgz crictl && rm /tmp/crictl.tgz
fi
cat > /etc/crictl.yaml <<'YAML'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
YAML
crictl info >/dev/null && echo "crictl wired to containerd"

echo "=== [9] kubelet/kubeadm/kubectl (${K8S_STREAM} stream, pinned to exactly ${K8S_PATCH}) ==="
mkdir -p -m 755 /etc/apt/keyrings
if [ ! -f "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg" ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/Release.key" | gpg --dearmor -o "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/ /" > "/etc/apt/sources.list.d/kubernetes-${K8S_STREAM/v/}.list"
fi
apt-get update
# deterministic install: resolve the exact Debian package version for K8S_PATCH and fail
# loudly if it is missing - never let "whatever is newest today" onto a node
K8S_PACKAGE_VERSION="$(
  apt-cache madison kubeadm |
    awk -v prefix="${K8S_PATCH}-" 'index($3, prefix) == 1 { print $3; exit }'
)"
if [ -z "${K8S_PACKAGE_VERSION}" ]; then
  echo "Kubernetes package ${K8S_PATCH} not found in the ${K8S_STREAM} apt stream:"
  apt-cache madison kubeadm || true
  exit 1
fi
echo "resolved apt package version: ${K8S_PACKAGE_VERSION}"
apt-get install -y --allow-change-held-packages \
  kubelet="${K8S_PACKAGE_VERSION}" kubeadm="${K8S_PACKAGE_VERSION}" kubectl="${K8S_PACKAGE_VERSION}"
apt-mark hold kubelet kubeadm kubectl
# verify all three report exactly v${K8S_PATCH}
KUBEADM_V="$(kubeadm version -o short)"
KUBECTL_V="$(kubectl version --client 2>/dev/null | awk '/Client Version/{print $NF; exit}')"
KUBELET_V="$(kubelet --version | awk '{print $2}')"
for v in "kubeadm:${KUBEADM_V}" "kubectl:${KUBECTL_V}" "kubelet:${KUBELET_V}"; do
  case "${v}" in
    *":v${K8S_PATCH}") echo "${v} OK" ;;
    *) echo "VERSION MISMATCH: ${v}, expected v${K8S_PATCH}"; exit 1 ;;
  esac
done

echo "=== [10] helm ${HELM_VERSION} (pinned, sha256-verified) ==="
if [ "$(helm version --template '{{.Version}}' 2>/dev/null || true)" != "${HELM_VERSION}" ]; then
  curl -fsSL -o /tmp/helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  if [ -n "${HELM_SHA256}" ]; then
    echo "${HELM_SHA256}  /tmp/helm.tgz" | sha256sum -c - || { echo "helm tarball sha256 mismatch - re-verify HELM_SHA256 in linode-env.sh against get.helm.sh"; exit 1; }
  fi
  tar -C /tmp -xzf /tmp/helm.tgz linux-amd64/helm
  install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
  rm -rf /tmp/helm.tgz /tmp/linux-amd64
fi
helm version || true

echo
echo "Node prepared. Versions:"
containerd --version; crictl --version; kubeadm version -o short; kubectl version --client 2>/dev/null | head -1
echo
echo "Next:"
echo "  - on devstats-compute-01 only:  kubeadm config images pull --kubernetes-version v${K8S_PATCH}"
echo "                                  kubeadm init --kubernetes-version v${K8S_PATCH} --apiserver-advertise-address=10.60.0.31 --pod-network-cidr=10.244.0.0/16"
echo "  - on the others:                kubeadm join 10.60.0.31:6443 ... (from 'kubeadm token create --print-join-command')"
echo "  - then flannel /22 + maxPods 1024 + labels (plan sections 5.3-5.4)"
