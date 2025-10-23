# devstats-helm

DevStats deployment on Oracle Cloud Ubuntu 24.04 LTS bare metal Kubernetes using Helm.

This is deployed:
- [CNCF prod](https://devstats.cncf.io).

# Shared steps for all nodes (master and workers)

- As root: `sudo bash`:
- Add `/etc/hosts` entries for all servers on all instances (do this 4 times):
```
10.0.0.x devstats-master
10.0.0.y devstats-node-0
10.0.0.z devstats-node-1
10.0.0.v devstats-node-2

x.y.z.v omaster
x.y.z.v onode0
x.y.z.v onode1
x.y.z.v onode2
```
- Then proceed:
```
passwd
passwd ubuntu
apt update -y && apt upgrade -y
apt install mdadm mc btop -y
mdadm --create /dev/md0 --level=10 --raid-devices=8 /dev/nvme[0-7]n1
mkfs.ext4 -L data /dev/md0
mkdir /data                         
mount /dev/md0 /data
bash -c 'mdadm --detail --scan >> /etc/mdadm/mdadm.conf'                                                           
update-initramfs -u
UUID=$(blkid -s UUID -o value /dev/md0)
echo "UUID=$UUID /data ext4 defaults,noatime,x-systemd.before=local-fs.target,x-systemd.requires=local-fs-pre.target 0 2" | tee -a /etc/fstab
umount /data
mount -a
systemctl daemon-reload
mkdir -p /data/{containerd,kubelet,etcd,logs/{containers,pods}}
chown -R root:root /data
chmod 755 /data
ln -s /data/containerd /var/lib/containerd
ln -s /data/kubelet /var/lib/kubelet
ln -s /data/logs/pods /var/log/pods
ln -s /data/logs/containers /var/log/containers
ln -s /data/etcd /var/lib/etcd
apt install -y apt-transport-https ca-certificates curl gnupg nfs-common net-tools
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab
cat <<'EOF' | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat <<'EOF' | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.ip_forward = 1
EOF
sysctl --system
iptables -P FORWARD ACCEPT
iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
iptables-save | tee /etc/iptables/rules.v4 >/dev/null
curl -fsSL -o /tmp/containerd.tgz https://github.com/containerd/containerd/releases/download/v2.1.4/containerd-2.1.4-linux-amd64.tar.gz
tar -C /usr/local -xzvf /tmp/containerd.tgz
rm /tmp/containerd.tgz
apt-get install -y runc
curl -fsSL -o /tmp/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
mv /tmp/containerd.service /etc/systemd/system/containerd.service
systemctl daemon-reload
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
curl -fsSL -o /tmp/crictl-v1.34.0-linux-amd64.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.34.0/crictl-v1.34.0-linux-amd64.tar.gz
tar -C /usr/local/bin -xzf /tmp/crictl-v1.34.0-linux-amd64.tar.gz crictl
rm /tmp/crictl-v1.34.0-linux-amd64.tar.gz
crictl --version
tee /etc/crictl.yaml >/dev/null <<'YAML'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
YAML
crictl info >/dev/null && echo "crictl wired to containerd"
apt-get update && apt-get install -y apt-transport-https ca-certificates curl gpg
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-1-34.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-1-34.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | tee /etc/apt/sources.list.d/kubernetes-1-34.list
apt-get update
apt-get install -y kubelet=1.34.1-1.1 kubeadm=1.34.1-1.1 kubectl=1.34.1-1.1
apt-mark hold kubelet kubeadm kubectl
```

# Now on the master node

```
MASTER_IP="$(hostname -I | awk '{print $1}')"
cat <<EOF | tee kubeadm.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.1
networking:
  podSubnet: "172.20.0.0/16"
EOF
kubeadm init --config kubeadm.yaml --skip-phases=addon/kube-proxy
alias k=kubectl
echo 'alias k=kubectl' >> ~/.profile
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
k get no
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
k taint nodes devstats-master node-role.kubernetes.io/control-plane:NoSchedule-
```

# As non-root user on master node

- Exacute:
```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
alias k=kubectl
echo 'alias k=kubectl' >> ~/.profile
```

# Steps for Kubernetes worker nodes - as root

- Copy `/etc/kubernetes/admin.conf` from master to `~/.kube/config` on each worker node for both `root` and `ubuntu` and do other configuarion:
```
alias k=kubectl
echo 'alias k=kubectl' >> ~/.profile
mkdir /root/.kube ~ubuntu/.kube
vim /root/.kube/config ~ubuntu/.kube/config
chown -R ubuntu ~ubuntu/.kube/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```


