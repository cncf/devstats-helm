# devstats-helm

DevStats deployment on Oracle Cloud Ubuntu 24.04 LTS bare metal Kubernetes using Helm.

This is deployed:
- [CNCF prod](https://devstats.cncf.io).

# Shared steps for all nodes (master and workers)
- In Ocacle Cloud web interface your 4 nodes must have the following settings in NSG (network security group) and default security group of subnet:
- Allow all egress to CIDR 0.0.0.0/0 (by all I mean all protocols/all ports).
- Allow all ingress from CIDR: 10.0.0.0/16.
- For each node's VNIC do: `oci network vnic update --vnic-id "ocid1.vnic.[...]" --skip-source-dest-check true`.
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
```
- Now edit `vim /etc/containerd/config.toml` and under `[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]` add `SystemdCgroup = true`.
```
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
kubeadm init --apiserver-advertise-address="${MASTER_IP}" --pod-network-cidr="10.244.0.0/16"
alias k=kubectl
echo 'alias k=kubectl' >> ~/.profile
echo 'alias k=kubectl' >> ~/.bashrc
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
k get no
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/refs/heads/master/Documentation/kube-flannel.yml
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
echo 'alias k=kubectl' >> ~/.bashrc
```

# Steps for Kubernetes worker nodes - as root

- Copy `/etc/kubernetes/admin.conf` from master to `~/.kube/config` on each worker node for both `root` and `ubuntu` and do other configuarion:
```
alias k=kubectl
echo 'alias k=kubectl' >> ~/.profile
echo 'alias k=kubectl' >> ~/.bashrc
mkdir /root/.kube ~ubuntu/.kube
vim /root/.kube/config ~ubuntu/.kube/config
chown -R ubuntu ~ubuntu/.kube/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

# On nodes

- Run kubeadm join command that was generated at the end of master node kubeadm init output.
- Add history stuff: `cp ~/.bash_history ~/.history; vim ~/.bashrc vim ~/.inputrc`:
```
# History stuff
export HISTFILESIZE=
export HISTSIZE=
export HISTFILE=~/.history
export HISTTIMEFORMAT="[%F %T] "
export PROMPT_COMMAND="history -a; history -c; history -r"
export HISTCONTROL=ignoredups:ignorespace:erasedups
```
And:
```
"\e[A": history-search-backward
"\e[B": history-search-forward
```
To raise 1024 pods/node limit (from ~110) do:
- `kubectl -n kube-flannel get cm kube-flannel-cfg -o yaml > kube-flannel-cfg.bak.yaml; vim kube-flannel-cfg.bak.yaml` (this is only needed from any node).
- Add `Subnetlen": 22,`:
```
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "SubnetLen": 22,
      "Backend": { "Type": "vxlan" }
    }
```
- Then: `kubectl -n kube-flannel rollout restart ds/kube-flannel-ds`.
- Edit: `vim /var/lib/kubelet/config.yaml` add `maxPods: 1024`, and then (on all nodes):
```
systemctl daemon-reload
systemctl restart kubelet
```
- On master edit: `/etc/kubernetes/manifests/kube-controller-manager.yaml`, make sure it has:
```
- --allocate-node-cidrs=true
- --cluster-cidr=10.244.0.0/16
- --node-cidr-mask-size-ipv4=22
```
- On all nodes:
```
tee /etc/sysctl.d/99-k8s-scale.conf >/dev/null <<'EOF'
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384
fs.inotify.max_user_instances=4096
fs.inotify.max_user_watches=1048576
net.netfilter.nf_conntrack_max=2621440
net.core.somaxconn=4096
EOF
sudo sysctl --system
```
- On all nodes, master last:
```
#!/bin/bash
NODE="$(hostname)"
echo "node: $NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
systemctl stop kubelet
systemctl stop containerd
ip link del cni0    2>/dev/null || true
ip link del flannel.1 2>/dev/null || true
rm -rf /var/lib/cni/networks/cni0
rm -rf /var/lib/cni/flannel            2>/dev/null || true
rm -f  /run/flannel/subnet.env         2>/dev/null || true
systemctl start containerd
systemctl start kubelet
kubectl -n kube-flannel delete pod -l app=flannel --field-selector spec.nodeName="$NODE"
kubectl uncordon "$NODE"
```
- You can test networking by executing `./k8s/test-networking.sh`.
- On any node:
```
for node in devstats-master devstats-node-0 devstats-node-1 devstats-node-2; do k label node $node node=devstats-app; k label node $node node2=devstats-db; done
```

# Storage
- Run:
```
mkdir /data/openebs && ln -s /data/openebs /var/openebs
kubectl create namespace openebs
helm repo add openebs https://openebs.github.io/charts
helm repo update
helm install openebs openebs/openebs -n openebs
kubectl -n openebs get pods -w
sleep 20
k patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
helm repo add openebs-dynamic-nfs https://openebs-archive.github.io/dynamic-nfs-provisioner/
helm repo update
helm install openebs-nfs openebs-dynamic-nfs/nfs-provisioner --namespace openebs-nfs --create-namespace --set nfsStorageClass.name=nfs-openebs-localstorage --set-string nfsStorageClass.backendStorageClass=openebs-hostpath
```
# DevStats namespaces

- Create DevStats test and prod namespaces: `k create ns devstats-test; k create ns devstats-prod`.


# Contexts

- You need to have at least those 2 contexts in your `~/.kube/config`:
```
- context:
    cluster: kubernetes
    namespace: devstats-prod
    user: kubernetes-admin
  name: prod
- context:
    cluster: kubernetes
    namespace: devstats-test
    user: kubernetes-admin
  name: test
- context:
    cluster: kubernetes
    namespace: default
    user: kubernetes-admin
  name: shared
```

# Domain, DNS and Ingress
XXX: continue


# Used Software

- containerd 2.1.4
- crictl 1.34.0
- runc 1.3.0
- kubernetes 1.34.1
- flannel
- coredns 1.14.1
- helm 3.18.0
- openebs 3.10.0
- openebs-dynamic-nfs 
