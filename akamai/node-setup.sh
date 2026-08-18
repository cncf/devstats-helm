#!/bin/bash
# DevStats common node preparation for Akamai Linode (Ubuntu 26.04 LTS).
# Direct adaptation of README.md "Shared steps for all nodes" with OCI/mdadm parts removed:
#   - /data on the plan-local "data" disk (created by resize-node-disks.sh, attached as /dev/sdc)
#   - /etc/hosts for all VPC addresses incl. compute-03 (+ devstats-master alias)
#   - containerd + runc + crictl, SystemdCgroup
#   - kubelet/kubeadm/kubectl from pkgs.k8s.io ${K8S_STREAM}, held
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
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.3.4}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.36.0}"
DATA_DEV="${DATA_DEV:-/dev/sdc}"

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

echo "=== [2] base packages ==="
chmod -x /etc/update-motd.d/* 2>/dev/null || true
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl gnupg gpg nfs-common net-tools \
  iptables-persistent jq mc btop iperf3 fio

echo "=== [3] /data on the plan-local data disk (${DATA_DEV}) ==="
if ! mountpoint -q /data; then
  [ -b "${DATA_DEV}" ] || { echo "${DATA_DEV} missing - run resize-node-disks.sh for this node first"; exit 1; }
  mkdir -p /data
  # resize-node-disks.sh already created an ext4 filesystem on the disk
  UUID="$(blkid -s UUID -o value "${DATA_DEV}")"
  [ -n "${UUID}" ] || { mkfs.ext4 -L data "${DATA_DEV}"; UUID="$(blkid -s UUID -o value "${DATA_DEV}")"; }
  grep -q "${UUID}" /etc/fstab || echo "UUID=${UUID} /data ext4 defaults,noatime,x-systemd.before=local-fs.target,x-systemd.requires=local-fs-pre.target 0 2" >> /etc/fstab
  systemctl daemon-reload
  mount -a
fi
# reclaim ext4's default 5% root reserve (~242 GiB on a 4,850 GiB data disk) - keep 1%
tune2fs -m 1 "${DATA_DEV}" >/dev/null || true
df -h /data

echo "=== [4] data directories + symlinks (openebs/containerd/kubelet/etcd/logs) ==="
mkdir -p /data/openebs /data/containerd /data/kubelet /data/etcd /data/logs/containers /data/logs/pods
chown -R root:root /data && chmod 755 /data
[ -e /var/openebs ]        || ln -s /data/openebs /var/openebs
[ -e /var/lib/containerd ] || ln -s /data/containerd /var/lib/containerd
[ -e /var/lib/kubelet ]    || ln -s /data/kubelet /var/lib/kubelet
[ -e /var/lib/etcd ]       || ln -s /data/etcd /var/lib/etcd
[ -e /var/log/pods ]       || ln -s /data/logs/pods /var/log/pods
[ -e /var/log/containers ] || ln -s /data/logs/containers /var/log/containers

echo "=== [5] swap off (permanent) ==="
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

echo "=== [6] kernel modules + sysctls ==="
cat > /etc/modules-load.d/containerd.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
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

echo "=== [7] containerd ${CONTAINERD_VERSION} + runc + crictl ${CRICTL_VERSION} ==="
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

echo "=== [8] kubelet/kubeadm/kubectl (${K8S_STREAM}) ==="
mkdir -p -m 755 /etc/apt/keyrings
if [ ! -f "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg" ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/Release.key" | gpg --dearmor -o "/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-${K8S_STREAM}.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/ /" > "/etc/apt/sources.list.d/kubernetes-${K8S_STREAM/v/}.list"
fi
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "=== [9] helm (latest) ==="
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
helm version || true

echo
echo "Node prepared. Versions:"
containerd --version; crictl --version; kubeadm version -o short; kubectl version --client 2>/dev/null | head -1
echo
echo "Next:"
echo "  - on devstats-compute-01 only:  kubeadm init --apiserver-advertise-address=10.60.0.31 --pod-network-cidr=10.244.0.0/16"
echo "  - on the others:                kubeadm join 10.60.0.31:6443 ... (from 'kubeadm token create --print-join-command')"
echo "  - then flannel /22 + maxPods 1024 + labels (plan sections 5.3-5.4)"
