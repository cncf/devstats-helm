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
10.0.0.w devstats-node-3
10.0.0.k devstats-node-4

x.y.z.v omaster
x.y.z.v onode0
x.y.z.v onode1
x.y.z.v onode2
x.y.z.v onode3
x.y.z.v onode4
```
- Then proceed:
```
passwd
passwd ubuntu
sudo chmod -x /etc/update-motd.d/*
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
mkdir /data/openebs && ln -s /data/openebs /var/openebs
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
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-1-35.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-1-35.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | tee /etc/apt/sources.list.d/kubernetes-1-35.list
apt-get update
apt-get install -y kubelet=1.35.0-1.1 kubeadm=1.35.0-1.1 kubectl=1.35.0-1.1
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
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
helm version
```

# On nodes

- Run kubeadm join command that was generated at the end of master node kubeadm init output, or get a fresh one via: `` sudo kubeadm token create --print-join-command ``.
- Add history stuff: `cp ~/.bash_history ~/.history; vim ~/.bashrc ~/.inputrc`:
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
for node in devstats-master devstats-node-0 devstats-node-1 devstats-node-2 devstats-node-3 devstats-node-4; do k label node $node node=devstats-app; k label node $node node2=devstats-db; done
```

- Confirm that all nodes have `/22` CIDR and 1024 pods/node: `` kubectl get nodes -o custom-columns=NAME:.metadata.name,CAP:.status.capacity.pods,PODCIDR:.spec.podCIDR `` - do NOT proceed until you see `1024` and `/22`.

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

# nginx-ingress

- niginx-ingress (using NodePort, prod adds 30000 to port number, test adds 31000):
```
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
kubectl label node devstats-master ingress=test
kubectl label node devstats-node-0 ingress=prod
kubectl label node devstats-node-1 ingress=test
kubectl label node devstats-node-2 ingress=prod
kubectl label node devstats-node-3 ingress=test
kubectl label node devstats-node-4 ingress=prod
k get no --show-labels
kubectl config use-context test
helm upgrade --install nginx-ingress-test ingress-nginx/ingress-nginx \
  --namespace devstats-test --create-namespace \
  --set controller.ingressClassResource.name=nginx-test \
  --set controller.ingressClass=nginx-test \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-test \
  --set controller.nodeSelector.ingress=test \
  --set defaultBackend.enabled=false \
  --set controller.config.disable-ipv6="true" \
  --set controller.config.worker-rlimit-nofile="65535" \
  --set controller.startupProbe.httpGet.path=/healthz \
  --set controller.startupProbe.httpGet.port=10254 \
  --set controller.startupProbe.failureThreshold=18 \
  --set controller.startupProbe.periodSeconds=5 \
  --set controller.livenessProbe.initialDelaySeconds=30 \
  --set controller.livenessProbe.periodSeconds=20 \
  --set controller.livenessProbe.timeoutSeconds=5 \
  --set controller.livenessProbe.successThreshold=1 \
  --set controller.livenessProbe.failureThreshold=5 \
  --set controller.readinessProbe.initialDelaySeconds=15 \
  --set controller.readinessProbe.periodSeconds=20 \
  --set controller.readinessProbe.timeoutSeconds=5 \
  --set controller.readinessProbe.successThreshold=1 \
  --set controller.readinessProbe.failureThreshold=5 \
  --set controller.service.type=NodePort \
  --set controller.kind=DaemonSet \
  --set controller.service.nodePorts.http=31080 \
  --set controller.service.nodePorts.https=31443 \
  --set controller.service.externalTrafficPolicy=Local
kubectl config use-context prod
helm upgrade --install nginx-ingress-prod ingress-nginx/ingress-nginx \
  --namespace devstats-prod --create-namespace \
  --set controller.ingressClassResource.name=nginx-prod \
  --set controller.ingressClass=nginx-prod \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-prod \
  --set controller.nodeSelector.ingress=prod \
  --set defaultBackend.enabled=false \
  --set controller.config.disable-ipv6="true" \
  --set controller.config.worker-rlimit-nofile="65535" \
  --set controller.startupProbe.httpGet.path=/healthz \
  --set controller.startupProbe.httpGet.port=10254 \
  --set controller.startupProbe.failureThreshold=18 \
  --set controller.startupProbe.periodSeconds=5 \
  --set controller.livenessProbe.initialDelaySeconds=30 \
  --set controller.livenessProbe.periodSeconds=20 \
  --set controller.livenessProbe.timeoutSeconds=5 \
  --set controller.livenessProbe.successThreshold=1 \
  --set controller.livenessProbe.failureThreshold=5 \
  --set controller.readinessProbe.initialDelaySeconds=15 \
  --set controller.readinessProbe.periodSeconds=20 \
  --set controller.readinessProbe.timeoutSeconds=5 \
  --set controller.readinessProbe.successThreshold=1 \
  --set controller.readinessProbe.failureThreshold=5 \
  --set controller.service.type=NodePort \
  --set controller.kind=DaemonSet \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --set controller.service.externalTrafficPolicy=Local
```

# OCI NLBs
- `` ./oci/oci-create-nlbs.sh ``.
XXX: continue (from continue.secret file).


# DevStats installation

- Copy `devstats-helm` repo onto the master node (or clone and then also copy gitignored `*.secret` files).
- Change directory to that repo and install `prod` namespace secrets: `` helm install devstats-prod-secrets ./devstats-helm --set namespace='devstats-prod',skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Create backups PV (ReadWriteMany): `` helm install devstats-prod-backups-pv ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Deploy git storage PVs: `` helm install devstats-prod-pvcs ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Deploy patroni: `` helm install devstats-prod-patroni ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Get master IP: `` k exec -it devstats-postgres-0 -- patronictl list ``.
- Manually tweak it:
```
curl -s -X PATCH \
  -H 'Content-Type: application/json' \
  -d '{
    "loop_wait": 15,
    "ttl": 60,
    "retry_timeout": 60,
    "primary_start_timeout": 600,
    "maximum_lag_on_failover": 53687091200,
    "postgresql": {
      "use_pg_rewind": true,
      "use_slots": true,
      "parameters": {
        "shared_buffers": "500GB",
        "max_connections": 1024,
        "max_worker_processes": 32,
        "max_parallel_workers": 32,
        "max_parallel_workers_per_gather": 28,
        "work_mem": "8GB",
        "wal_buffers": "1GB",
        "temp_file_limit": "200GB",
        "wal_keep_size": "100GB",
        "max_wal_senders": 10,
        "max_replication_slots": 10,
        "maintenance_work_mem": "2GB",
        "idle_in_transaction_session_timeout": "30min",
        "wal_level": "replica",
        "wal_log_hints": "on",
        "hot_standby": "on",
        "hot_standby_feedback": "on",
        "max_wal_size": "128GB",
        "min_wal_size": "4GB",
        "checkpoint_completion_target": 0.9,
        "default_statistics_target": 1000,
        "effective_cache_size": "256GB",
        "effective_io_concurrency": 8,
        "random_page_cost": 1.1,
        "autovacuum_max_workers": 1,
        "autovacuum_naptime": "120s",
        "autovacuum_vacuum_cost_limit": 100,
        "autovacuum_vacuum_threshold": 150,
        "autovacuum_vacuum_scale_factor": 0.25,
        "autovacuum_analyze_threshold": 100,
        "autovacuum_analyze_scale_factor": 0.2,
        "password_encryption": "scram-sha-256"
      }
    }
  }' \
  http://<leader-ip>:8008/config | jq .
```
- Restart due to those changes: `` patronictl restart devstats-postgres devstats-postgres-0 ``.
- Confirm final configuration and clean state: `` k exec -itn devstats-prod devstats-postgres-0 -- patronictl show-config && k exec -itn devstats-prod devstats-postgres-0 -- patronictl list ``.
- Install static page handlers: `` helm install devstats-prod-statics ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipAPI=1,skipNamespaces=1,indexStaticsFrom=1 ``.
- Install prod ingress (will not work yet until SSL certs and DNS are set): `` helm install devstats-prod-ingress ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipAliases=1,indexDomainsFrom=1,ingressClass=nginx-prod,sslEnv=prod ``.
- Install bootstrap DB: `` helm install devstats-prod-bootstrap ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Make sure it finishes successfully: `` k logs -f devstats-provision-bootstrap ``. Then: `` k delete po devstats-provision-bootstrap ``.
- Follow `Copy grafana shared data` from `cncf/devstats/ADDING_NEW_PROJECT.md`, do from `cncf/devstats` repo:
```
cp ../devstatscode/sqlitedb ../devstatscode/runq ../devstatscode/replacer grafana/ && tar cf devstats-grafana.tar grafana/runq grafana/sqlitedb grafana/replacer grafana/shared grafana/img/*.svg grafana/img/*.png grafana/*/change_title_and_icons.sh grafana/*/custom_sqlite.sql grafana/dashboards/*/*.json
```
- `sftp` it to devstats node: `sftp ubuntu@onodeN`, `mput devstats-grafana.tar`. SSH into that node: `ssh ubuntu@onodeN`, get static pod name: `k get po -n devstats-prod | grep static-prod`.
- Copy new grafana data to that pod: `k cp devstats-grafana.tar -n devstats-prod devstats-static-prod-5779c5dd5d-2prpr:/devstats-grafana.tar`, shell into that pod: `k exec -itn devstats-prod devstats-static-prod-5779c5dd5d-2prpr -- bash`.
- Do all/everything command: `rm -rf /grafana && tar xf /devstats-grafana.tar && rm -rf /usr/share/nginx/html/backups/grafana && mv /grafana /usr/share/nginx/html/backups/grafana && rm /devstats-grafana.tar && chmod -R ugo+rwx /usr/share/nginx/html/backups/grafana/ && echo 'All OK'`.
- Install 1st project (Kuberentes): `` helm install devstats-prod-kubernetes ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsTo=1,indexCronsTo=1,indexGrafanasTo=1,indexServicesTo=1,indexAffiliationsTo=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=64,skipAddAll=1 ``.
- Now at the same time create pod for backups (on the previous cluster): `` helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1,limitsBackupsCPU=4000m,limitsBackupsMemory=64Gi ``.
- Shell into it: `` ../devstats-k8s-lf/util/pod_shell.sh debug ``. Then run: `` FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial.sh gha ``. Or for all: `` ONLY='proj1 .. projN' FASTXZ=1 NOBACKUP='' ./devstats-helm/backup_artificial_all.sh ``.
- Now create restore pod (on the new cluster): `` helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1 ``.
- Shell into it: `` k exec -it debug -- bash ``.
- Restore: `` RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial.sh gha ``. Or for all: `` ONLY='proj1 ... projN' RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh ``.
- Delete debug pod on both cluster: `` helm delete devstats-prod-debug ``.
- In case of provisioning failure you can do: `` helm install --generate-name ./devstats-helm --set namespace='devstats-prod',provisionImage='lukaszgryglicki/devstats-prod',testServer='',prodServer='1',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipAffiliations=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipECFRGReset=1,skipAddAll=1,provisionCommand=sleep,provisionCommandArgs={360000s},provisionPodName=fix,indexProvisionsTo=1,nCPUs=32,limitsProvisionsMemory=640Gi ``.
- And then: `` k exec -it fix-kubernetes -- bash ``. To get the last data that was processed: `` k exec -itn devstats-prod devstats-postgres-0 -- psql gha -c "select type, max(created_at) from gha_events where type ~ '^[A-Z]' group by 1 order by 2 desc limit 1" ``.
- Inside pod: `` vi proj/psql.sh; WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./proj/psql.sh ``.
- Then: `WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./devel/ro_user_grants.sh "proj" && WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./devel/psql_user_grants.sh "devstats_team" "proj" && GHA2DB_ALLOW_METRIC_FAIL=1 WAITBOOT=1 ./devstats-helm/deploy_all.sh ``.
- Alternatively use script: `` ./devstats-helm/fix-after-fail.sh proj `` inside the fix-proj pod.
- If Reinit metrics calculation is needed (allowing metrics to fail): `` helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionImage='lukaszgryglicki/devstats-prod',indexProvisionsFrom=N,indexProvisionsTo=N+1,provisionCommand='./devstats-helm/reinit.sh',provisionPodName=reinit,allowMetricFail=1,maxRunDuration='calc_metric:72h:102',nCPUs=10,limitsProvisionsMemory=640Gi ``.
- If metric debugging is needed - do this from inside the reinit/fix pod: `` clear && GHA2DB_QOUT=1 PG_DB=allprj runq metrics/all/project_countries_commiters.sql {{from}} 2014-01-01 {{to}} 2014-01-02 {{exclude_bots}} "not in ('')" `` or `` clear && GHA2DB_QOUT=1 PG_DB=allprj runq metrics/shared/bus_factor_opt2.sql qr '1 week,,' {{exclude_bots}} "not in ('')" ``.
- Then repeat for other projects, example next ones (multiple at a time), for example: `` helm install devstats-projects-1 ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=1,indexProvisionsTo=38,indexCronsFrom=1,indexCronsTo=38,indexGrafanasFrom=1,indexGrafanasTo=38,indexServicesFrom=1,indexServicesTo=38,indexAffiliationsFrom=1,indexAffiliationsTo=38,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=4,skipAddAll=1,allowMetricFail=1 ``.
- Then track their progress: `` clear && k logs -f -l type=provision --max-log-requests=38 --tail=100  | grep -E 'events [1-9]' ``. And `` k get po | grep provision ``.
- Some projects were archived so they don't need to be provisioned, see: `` cncf/devstas/metrics/all/sync_vars.yaml ``. Example: `` echo 'prometheus fluentd linkerd grpc coredns containerd cni envoy jaeger notary tuf rook vitess nats opa spiffe spire cloudevents telepresence helm harbor etcd tikv cortex buildpacks falco dragonfly virtualkubelet kubeedge crio networkservicemesh opentelemetry' | grep -E 'brigade|smi|openservicemesh|osm|krator|ingraind|fonio|curiefense|krustlet|skooner|k8dash|curve|fabedge|kubedl|superedge|nocalhost|merbridge|devstream|teller|openelb|sealer|cni-genie|servicemeshperformance|xline|pravega|openmetrics|rkt|opentracing|keptn' ``.
- Install `All CNCF` project: `` helm install devstats-prod-allprj ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=38,indexProvisionsTo=39,indexCronsFrom=38,indexCronsTo=39,indexGrafanasFrom=38,indexGrafanasTo=39,indexServicesFrom=38,indexServicesTo=39,indexAffiliationsFrom=38,indexAffiliationsTo=39,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=12,skipAddAll=1,limitsProvisionsMemory=1Ti ``.
- Deploy DevStats API service: `` helm install devstats-prod-api ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1,apiImage='lukaszgryglicki/devstats-api-prod' ``.
- Deploy backups cron job: `` helm install devstats-prod-backups ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,backupsTestServer='',backupsProdServer='1' ``. Then `` k edit cj -n devstats-prod devstats-backups ``, set `schedule:` to `45 2 10,24 * *`.

# Other instances

- Normal prod instances are marked via `` domains: [0, 1, 0, 0] ``.
- Only the following projects should be installed in the test namespace: `` azf cii cncf fn godotengine linux opencontainers openfaas openwhisk riff sam zephyr ``. They are in `` [1, 0, 0, 0] ``. Indexes are: `` [49, 50], [53, 54], [59, 64], [67], [97] ``.
- GraphQL instances, they are on prod and marked as domains: `` [0, 0, 0, 1] ``: `` graphqljs graphiql graphqlspec expressgraphql graphql ``. Indexes are: `` [44, 48] ``.
- CDF instances, they are on prod and marked as domains: `` [0, 0, 1, 0] ``: `` tekton spinnaker jenkinsx jenkins allcdf cdevents ortelius pyrsia screwdrivercd shipwright ``. Indexes are: `` [39, 43], [182, 186] ``.


# DevStats installation in test namespace

- Copy `devstats-helm` repo onto the node0 (or clone and then also copy gitignored `*.secret` files).
- First switch context to test: `./switch_context.sh test`.
- Second confirm that the current context is test: `./current_context.sh`.
- Confirm that you have test secrets defined and that they have no end-line: `cat devstats-helm/secrets/*.secret` - should return one big line of all secret values concatenated.
- Change directory to that repo and install `test` namespace secrets: `` helm install devstats-test-secrets ./devstats-helm --set skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Deploy backups PV (ReadWriteMany): `` helm install devstats-test-backups-pv ./devstats-helm --set skipSecrets=1,skipPVs=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Deploy git storage PVs: `` helm install devstats-test-pvcs ./devstats-helm --set skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Deploy patroni: `` helm install devstats-test-patroni ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``.
- Get master IP: `` k exec -it devstats-postgres-0 -- patronictl list ``.
- Manually tweak it: `` curl -s -X PATCH -H 'Content-Type: application/json' -d '{"loop_wait":15,"ttl":60,"retry_timeout":60,"primary_start_timeout":600,"maximum_lag_on_failover":53687091200,"postgresql":{"use_pg_rewind":true,"use_slots":true,"parameters":{"shared_buffers":"250GB","max_connections":1024,"max_worker_processes":16,"max_parallel_workers":16,"max_parallel_workers_per_gather":28,"work_mem":"4GB","wal_buffers":"1GB","temp_file_limit":"200GB","wal_keep_size":"100GB","max_wal_senders":10,"max_replication_slots":10,"maintenance_work_mem":"2GB","idle_in_transaction_session_timeout":"30min","wal_level":"replica","wal_log_hints":"on","hot_standby":"on","hot_standby_feedback":"on","max_wal_size":"128GB","min_wal_size":"4GB","checkpoint_completion_target":0.9,"default_statistics_target":1000,"effective_cache_size":"128GB","effective_io_concurrency":8,"random_page_cost":1.1,"autovacuum_max_workers":1,"autovacuum_naptime":"120s","autovacuum_vacuum_cost_limit":100,"autovacuum_vacuum_threshold":150,"autovacuum_vacuum_scale_factor":0.25,"autovacuum_analyze_threshold":100,"autovacuum_analyze_scale_factor":0.2,"password_encryption":"scram-sha-256"}}}' http://10.244.8.229:8008/config | jq ``.
- Restart due to those changes: `` k exec -it devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres devstats-postgres-0 ``.
- Deploy static page handlers (default and for test domain): `` helm install devstats-test-statics ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipAPI=1,skipNamespaces=1,projectsOverride='+azf\,+cii\,+cncf\,+fn\,+godotengine\,+linux\,+opencontainers\,+openfaas\,+openwhisk\,+riff\,+sam\,+zephyr',indexStaticsFrom=0,indexStaticsTo=1 ``.
- Deploy test domain ingress: `` helm install devstats-test-ingress ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexDomainsFrom=0,indexDomainsTo=1,projectsOverride='+azf\,+cii\,+cncf\,+fn\,+godotengine\,+linux\,+opencontainers\,+openfaas\,+openwhisk\,+riff\,+sam\,+zephyr',ingressClass=nginx-test,sslEnv=test ``.
- Deploy/bootstrap logs database: `` helm install devstats-test-bootstrap ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,projectsOverride='+azf\,+cii\,+cncf\,+fn\,+godotengine\,+linux\,+opencontainers\,+openfaas\,+openwhisk\,+riff\,+sam\,+zephyr' ``.
- Make sure it finishes successfully: `` k logs -f devstats-provision-bootstrap ``. Then: `` k delete po devstats-provision-bootstrap ``.
- Follow `Copy grafana shared data` from `cncf/devstats/ADDING_NEW_PROJECT.md`, do from `cncf/devstats` repo:
```
cp ../devstatscode/sqlitedb ../devstatscode/runq ../devstatscode/replacer grafana/ && tar cf devstats-grafana.tar grafana/runq grafana/sqlitedb grafana/replacer grafana/shared grafana/img/*.svg grafana/img/*.png grafana/*/change_title_and_icons.sh grafana/*/custom_sqlite.sql grafana/dashboards/*/*.json
```
- `sftp` it to devstats node: `sftp ubuntu@onodeN`, `mput devstats-grafana.tar`. SSH into that node: `ssh ubuntu@onodeN`, get static pod name: `k get po -n devstats-test | grep static-test`.
- Copy new grafana data to that pod: `k cp devstats-grafana.tar -n devstats-test devstats-static-test-5779c5dd5d-2prpr:/devstats-grafana.tar`, shell into that pod: `k exec -itn devstats-test devstats-static-test-5779c5dd5d-2prpr -- bash`.
- Do all/everything command: `rm -rf /grafana && tar xf /devstats-grafana.tar && rm -rf /usr/share/nginx/html/backups/grafana && mv /grafana /usr/share/nginx/html/backups/grafana && rm /devstats-grafana.tar && chmod -R ugo+rwx /usr/share/nginx/html/backups/grafana/ && echo 'All OK'`.
- Install 1st set of test projects: `` ./scripts/helm_install_test_set.sh devstats-test-projects-1 49 51 8 512 ``.
- In case of provisioning failure you can do: `` helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipAffiliations=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipECFRGReset=1,skipAddAll=1,projectsOverride='+azf\,+cii\,+cncf\,+fn\,+godotengine\,+linux\,+opencontainers\,+openfaas\,+openwhisk\,+riff\,+sam\,+zephyr',provisionCommand=sleep,provisionCommandArgs={360000s},provisionPodName=fix,indexProvisionsFrom=49,indexProvisionsTo=51,nCPUs=10,limitsProvisionsMemory=512Gi ``.
- If Reinit metrics calculation is needed (allowing metrics to fail): `` helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,projectsOverride='+azf\,+cii\,+cncf\,+fn\,+godotengine\,+linux\,+opencontainers\,+openfaas\,+openwhisk\,+riff\,+sam\,+zephyr',indexProvisionsFrom=49,indexProvisionsTo=51,provisionCommand='./devstats-helm/reinit.sh',provisionPodName=reinit,allowMetricFail=1,maxRunDuration='calc_metric:72h:102',nCPUs=10,limitsProvisionsMemory=512Gi ``.
- If debug pod is needed: `` helm install devstats-test-debug ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1 ``.
- Shell into it: `` k exec -it debug -- bash ``. Then: `` helm delete devstats-test-debug ``.
- Deploy backups cron job: `` helm install devstats-test-backups ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1 ``. Then `` k edit cj -n devstats-test devstats-backups ``, set `schedule:` to `45 2 16,28 * *`.


# Used Software

- containerd 2.1.4
- crictl 1.34.0
- runc 1.3.0
- kubernetes 1.35.0
- flannel v0.27.4
- coredns 1.14.1
- helm 4.0.4
- openebs 3.10.0
- openebs-dynamic-nfs 0.11.0
- nginx-ingress 4.13.3
- patroni 4.1.0
- postgresql 18.1
- grafana 8.5.27
- nginx 1.29.3
