# devstats-helm

DevStats deployment on Oracle Cloud Ubuntu 24.04 LTS bare metal Kubernetes using Helm.

This is deployed:
- [CNCF prod](https://devstats.cncf.io).

# Shared steps for all nodes (master and workers)

- As root: `sudo bash`:

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
net.ipv4.ip_forward = 1
EOF
sysctl --system
curl -fsSL -o /tmp/containerd.tgz https://github.com/containerd/containerd/releases/download/v2.1.4/containerd-2.1.4-linux-amd64.tar.gz
tar -C /usr/local -xzvf /tmp/containerd.tgz
curl -fsSL -o /tmp/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
mv /tmp/containerd.service /etc/systemd/system/containerd.service
systemctl daemon-reload
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
curl -fsSL -o /tmp/crictl-v1.34.0-linux-amd64.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.34.0/crictl-v1.34.0-linux-amd64.tar.gz
tar -C /usr/local/bin -xzf /tmp/crictl-v1.34.0-linux-amd64.tar.gz crictl
rm /tmp/containerd.tgz /tmp/crictl-v1.34.0-linux-amd64.tar.gz
crictl --version
tee /etc/crictl.yaml >/dev/null <<'YAML'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
YAML
crictl info >/dev/null && echo "crictl wired to containerd"
```

# Steps for Kubernetes master node

```
```

# Steps for Kubernetes worker nodes

```
```
