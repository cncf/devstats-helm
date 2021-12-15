# devstats-helm

DevStats deployment on Equinix Ubuntu 20.04 LTS bare metal Kubernetes using Helm.

This is deployed:
- [CNCF test](https://teststats.cncf.io) (this also includes CDF, GraphQL test instance, for example [GraphQL All](https://graphql.teststats.cncf.io) and [CDF All](https://allcdf.teststats.cncf.io)).
- [CNCF prod](https://devstats.cncf.io).
- [CDF prod](https://devstats.cd.foundation).
- [GraphQL prod](https://devstats.graphql.org).


# Equinix NVMe disks
- See `NVME.md`.


# Installing Kubernetes on bare metal

- Setup 4 metal.equinix.com servers, give them hostnames: master, node-0, node-1, node-2.
- Install Ubuntu 20.04 LTS on all of them, then update apt `apt update`, `apt upgrade`.
- Enable root login `vim /etc/ssh/sshd_config` add line `PermitRootLogin yes`, change `PasswordAuthentication no` to `PasswordAuthentication yes` then `sudo service sshd restart`.
- Turn swap off on all of them `swapoff -a`.
- Load required kernel modeles: `modprobe br_netfilter`
  - Run:
```
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
```
- `sysctl --system`.
  - Install containerd (this is now a recommended Kubernetes CRI instead of docker).
  - Run:
```
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
```
  - `sudo modprobe overlay; sudo modprobe br_netfilter`.
  - Run:
```
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
```
  - `sudo sysctl --system`.
  - `sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common`.
  - `curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key --keyring /etc/apt/trusted.gpg.d/docker.gpg add -`.
  - `sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"`.
  - `sudo apt-get update && sudo apt-get install -y containerd.io`.
  - `sudo mkdir -p /etc/containerd`.
  - `sudo containerd config default | sudo tee /etc/containerd/config.toml`.
  - `sudo systemctl restart containerd`.
  - `sudo systemctl enable containerd`.
  - Set cgroup driver to systemd.
  - `vim /etc/containerd/config.toml`, search: `/plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options`.
  - Add: `SystemdCgroup = true`, so it looks like:
```
          base_runtime_spec = ""
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
    [plugins."io.containerd.grpc.v1.cri".cni]
```
  - `service containerd restart`.
  - Install kubectl [reference](https://kubernetes.io/docs/tasks/tools/install-kubectl/).
  - `curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"`.
  - `chmod +x ./kubectl; mv ./kubectl /usr/local/bin/kubectl; kubectl version --client; kubectl completion bash`.
  - `vim ~/.bashrc`, uncomment `. /etc/bash_completion` part, relogin, `echo 'source <(kubectl completion bash)' >>~/.bashrc`, `kubectl completion bash >/etc/bash_completion.d/kubectl`.
  - `echo 'alias k=kubectl' >>~/.bashrc; echo 'complete -F __start_kubectl k' >>~/.bashrc`.
  - Install kubeadm [reference](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl) (we will use calico network plugin, no additional setup is needed).
  - `curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -`.
  - Run:
```
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
```
  - `apt-get update && apt-get install -y kubelet kubeadm kubectl`.
  - `apt-mark hold kubelet kubeadm kubectl`
  - `systemctl daemon-reload; systemctl restart kubelet`.
  - Configure the cgroup driver for kubeadm using containerd (change advertiseAddress, `featureGates` and `shutdownGracePeriod*` - not tested yet):
```
cat <<EOF | sudo tee /etc/kubeadm_cgroup_driver.yml
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: X.Y.Z.A1
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
networking:
  podSubnet: '192.168.0.0/16'
featureGates:
  GracefulNodeShutdown: true
  DynamicKubeletConfig: true
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
shutdownGracePeriod: 60s
shutdownGracePeriodCriticalPods: 20s
EOF
```
  - `apt install -y nfs-common net-tools`.
  - Edit `/etc/hosts` add:
```
X.Y.Z.A1 devstats-master
X.Y.Z.A2 devstats-node-0
X.Y.Z.A3 devstats-node-1
X.Y.Z.A4 devstats-node-2
```
  - Initialize the cluster: `kubeadm init --config /etc/kubeadm_cgroup_driver.yml`.
  - Run on master:
```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```
  - Save kubeadm join command output to `join.sh` on master and all nodes, something like then `chmod +x join.sh`:
```
  #!/bin/bash
  kubeadm join 10.13.13.0:1234 --token xxxxxx.yyyyyyyyyyyy --discovery-token-ca-cert-hash sha256:0123456789abcdef0
```
  - Install networking plugin (calico):
  - On master: `wget https://docs.projectcalico.org/manifests/calico.yaml; kubectl apply -f calico.yaml`.
  - Allow scheduling on the master node [reference](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#control-plane-node-isolation):
  - On master: `kubectl taint nodes --all node-role.kubernetes.io/master-`.
  - On master: `kubectl get po -A; kubectl get nodes`. Wait for all pods to be in `Running` state.
  - On all nodes: `./join.sh`.
  - Copy config from master to all nodes:
  - `sftp root@devstats-node-N`:
```
mkdir .kube
lcd .kube
cd .kube
mput config
```
  - `k get node; service kubelet status`.


# Feature gates

- You can enable feature gates on a live system via: `k get cm -n kube-system | grep kubeadm`, then `k -n kube-system edit cm kubeadm-config`:
- Add your `kubeadm` options below the `networking` in `ClusterConfiguration` section, like this:
```
    networking:
      dnsDomain: cluster.local
      podSubnet: 192.168.0.0/16
      serviceSubnet: 10.96.0.0/12
    featureGates:
      GracefulNodeShutdown: true
      DynamicKubeletConfig: true
```
- You can enable specific kubelet features on a live system via: `k get cm -n kube-system | grep kubelet`, then `k -n kube-system edit cm kubelet-config-1.20`:
- Add your `kubelet` options below the `cgroup` driver in `KubeletConfiguration`, like this:
```
    cgroupDriver: systemd
    shutdownGracePeriod: 60s
    shutdownGracePeriodCriticalPods: 20s
    maxPods: 255
```
- Enable feature gates for `kube-apiserver`: `vim /etc/kubernetes/manifests/kube-apiserver.yaml`, add `- --feature-gates=GracefulNodeShutdown=True,DynamicKubeletConfig=True` so it looks like:
```
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --feature-gates=GracefulNodeShutdown=True,DynamicKubeletConfig=True
    image: k8s.gcr.io/kube-apiserver:v1.20.0
```
- Enable feature gates for `kubelet`, run `service kubelet status` - you will see something like `--config=/var/lib/kubelet/config.yaml`:
- `vim /var/lib/kubelet/config.yaml`, put your options there (master and all nodes):
```
shutdownGracePeriod: 60s
shutdownGracePeriodCriticalPods: 20s
```
- `vim /var/lib/kubelet/kubeadm-flags.env` update to something like (master and all nodes) `KUBELET_KUBEADM_ARGS="... --feature-gates=GracefulNodeShutdown=True,DynamicKubeletConfig=True"`.
- Edit node `k get no; k edit node node-name`, add under `spec` section, so it looks like:
```
spec:
  configSource:
    configMap:
      name: kubelet-config-1.20
      namespace: kube-system
      kubeletConfigKey: kubelet
  podCIDR: 192.168.0.0/24
```
- `service kubelet restart`.
- Check if `kubelet` and `kube-apiserver` are using feature gates: `ps aux | grep kube-apiserver | grep feature-gates`, `service kubelet status`.


# DevStats labels

- `for node in devstats-master devstats-node-0 devstats-node-1 devstats-node-2; do k label node $node node=devstats-app; k label node $node node2=devstats-db; done`


# Install Helm

- Install Helm (master & nodes): `wget https://get.helm.sh/helm-v3.4.2-linux-amd64.tar.gz; tar zxvf helm-v3.4.2-linux-amd64.tar.gz; mv linux-amd64/helm /usr/local/bin; rm -rf linux-amd64/ helm-v3.4.2-linux-amd64.tar.gz`.
- Add Helm charts repository (master & nodes): `helm repo add stable https://charts.helm.sh/stable`.
- Add OpenEBS charts repository (master & nodes): `helm repo add openebs https://openebs.github.io/charts`
- Add Ingress NGINX charts repository (master & nodes): `helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx`.
- Apply Helm repos config (master & nodes): `helm repo update`.


# Setup per-node local storage

- Make sure that `/var/openebs` directory on all nodes is placed on the physical volume you want to use for local storage. You can have a huge NVMe disk mounted on `/disk` for instance. In this case `mv /var/openebs /disk/openebs; ln -s /disk/openebs /var/openebs`.
- Install OpenEBS: `k create ns openebs; helm install --namespace openebs openebs openebs/openebs; helm ls -n openebs; kubectl get pods -n openebs`.
- Configure default storage class (need to wait for all OpenEBS pods to be running `k get po -n openebs -w`): `k patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`.
- You will also need a shared storage for backups (ReadWriteMany access mode - backup pods are writing, static pages are reading).
- Install NFS provisioner that will use OpenEBS local storage while on `default` namespace: `helm install local-storage-nfs stable/nfs-server-provisioner --set=persistence.enabled=true,persistence.storageClass=openebs-hostpath,persistence.size=8Ti,storageClass.name=nfs-openebs-localstorage`


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

- Switch to `test` context: `k config use-context test`.
- Install `nginx-ingress`: `helm install --namespace devstats-test nginx-ingress-test ingress-nginx/ingress-nginx --set controller.ingressClass=nginx-test,controller.scope.namespace=devstats-test,defaultBackend.enabled=false,controller.livenessProbe.initialDelaySeconds=15,controller.livenessProbe.periodSeconds=20,controller.livenessProbe.timeoutSeconds=5,controller.livenessProbe.successThreshold=1,controller.livenessProbe.failureThreshold=5,controller.readinessProbe.initialDelaySeconds=15,controller.readinessProbe.periodSeconds=20,controller.readinessProbe.timeoutSeconds=5,controller.readinessProbe.successThreshold=1,controller.readinessProbe.failureThreshold=5`.
- Optional: edit nginx service: `k edit svc -n devstats-test nginx-ingress-test-ingress-nginx-controller` add annotation: `metallb.universe.tf/address-pool: test` and (very optional) spec: `loadBalancerIP: 10.13.13.101`.
- Switch to `prod` context: `k config use-context prod`.
- Install `nginx-ingress`: `helm install --namespace devstats-prod nginx-ingress-prod ingress-nginx/ingress-nginx --set controller.ingressClass=nginx-prod,controller.scope.namespace=devstats-prod,defaultBackend.enabled=false,controller.livenessProbe.initialDelaySeconds=15,controller.livenessProbe.periodSeconds=20,controller.livenessProbe.timeoutSeconds=5,controller.livenessProbe.successThreshold=1,controller.livenessProbe.failureThreshold=5,controller.readinessProbe.initialDelaySeconds=15,controller.readinessProbe.periodSeconds=20,controller.readinessProbe.timeoutSeconds=5,controller.readinessProbe.successThreshold=1,controller.readinessProbe.failureThreshold=5`.
- Optional: edit nginx service: `k edit svc -n devstats-prod nginx-ingress-prod-ingress-nginx-controller` add annotation: `metallb.universe.tf/address-pool: prod` and (very optional) spec `loadBalancerIP: 10.13.13.102`.
- Switch to `shared` context: `k config use-context shared`.
- Install MetalLB [reference](https://metallb.universe.tf/installation/#installation-by-manifest):
- `kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/namespace.yaml`.
- `kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.5/manifests/metallb.yaml`.
- `kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"`.
- Create MetalLB configuration - specify `master` IP for `test` and `node-0` IP for `prod`, create file `metallb-config.yaml` and apply if `k apply -f metallb-config.yaml`:
```
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: prod
      protocol: layer2
      addresses:
      - X.Y.Z.A1/32
    - name: test
      protocol: layer2
      addresses:
      - X.Y.Z.A2/32
```
- More details [here](https://raw.githubusercontent.com/google/metallb/v0.9.5/manifests/example-config.yaml).
- Check if both test and prod load balancers are OK (they should have External-IP values equal to requested in config map: `k -n devstats-test get svc -o wide -w nginx-ingress-test-ingress-nginx-controller; k -n devstats-prod get svc -o wide -w nginx-ingress-prod-ingress-nginx-controller`).


# SSL

You need to have domain name pointing to your MetalLB IP before proceeding.

Install SSL certificates using Let's encrypt and auto renewal using `cert-manager`: `SSL.md`.

In short:

- Please make sure that you have DNS configured and ingress controller working with self-signed certs visible to the outside world on your domain.
- Create cert-manager namespace: `kubectl create namespace cert-manager`.
- Configure/label namespace: `kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true`.
- Install cert manager (includes CRDs): `kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.1.0/cert-manager.yaml`.
- Copy example file to a manifest file to be applied: `cp cert/cert-issuer.yaml.example cert/cert-issuer.yaml`.
- Tweak them - change email value: `vim cert/cert-issuer.yaml`.
- Apply issuers: `kubectl apply -f cert/cert-issuer.yaml`.
- Check it: `kubectl get issuers`.
- Observe `k get challenge -w` wait until ready.


# Golang (optional)

- `wget https://golang.org/dl/go1.15.6.linux-amd64.tar.gz`.
- `tar -C /usr/local -xzf go1.15.6.linux-amd64.tar.gz`.
- `rm go1.15.6.linux-amd64.tar.gz`.
- `echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile`
- Logout, login, run: `go version`.
- `apt install -y git`.
- `go get -u github.com/cncf/devstatscode`.
- `cd go/src/github.com/cncf/`


# DevStats

Test instance:

- Switch to `test` context: `k config use-context test`.
- Clone `devstats-helm` repo: `git clone https://github.com/cncf/devstats-helm`, `cd devstats-helm`.
- For each file in `devstats-helm/secrets/*.secret.example` create corresponding `secrets/*.secret` file. Vim saves with end line added, truncate such files via `truncate -s -1 filename`.
- Deploy DevStats secrets: `helm install devstats-test-secrets ./devstats-helm --set skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Deploy backups PV (ReadWriteMany): `helm install devstats-test-backups-pv ./devstats-helm --set skipSecrets=1,skipPVs=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`
- Deploy 4-node patroni HA database (Postgres 13.X): `helm install devstats-test-patroni ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Shell into the patroni master pod (after all 4 patroni nodes are in `Running` state: `k get po -n devstats-test | grep devstats-postgres-`): `k exec -n devstats-test -it devstats-postgres-0 -- /bin/bash`: 
  - Run: `patronictl list` to see patroni cluster state.
  - Tweak patroni: `curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "80GB", "max_parallel_workers_per_gather": "28", "max_connections": "1024", "min_wal_size": "1GB", "max_wal_size": "16GB", "effective_cache_size": "128GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "default_statistics_target": 1000, "effective_io_concurrency": 8, "random_page_cost": 1.1, "wal_buffers": "128MB", "max_worker_processes": "32", "max_parallel_workers": "32", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "30min", "hot_standby": "on", "hot_standby_feedback": "on", "wal_log_hints": "on", "wal_keep_segments": "10", "wal_keep_size": "4GB", "wal_level": "replica", "max_wal_senders": "5", "max_replication_slots": "5"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .`
  - `patronictl restart --force devstats-postgres`.
  - `patronictl show-config` to confirm config.
- Check patroni logs: `k logs -n devstats-test -f devstats-postgres-N`, N=0,1,2,3.
- Install static pages handlers: `helm install devstats-test-statics ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipAPI=1,skipNamespaces=1,indexStaticsFrom=0,indexStaticsTo=1`.
- Install ingress: `helm install devstats-test-ingress ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexDomainsFrom=0,indexDomainsTo=1,ingressClass=nginx-test,sslEnv=test
- Deploy/bootstrap logs database: `helm install devstats-test-bootstrap ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Delete finished bootstrap pod (when in `Completed` state): `k delete po devstats-provision-bootstrap`.
- Deploy backups cron job: `helm install devstats-test-backups ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Create API service: `helm install devstats-test-api ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1`.
- If you want to use a backup from different server (like during the switchover):
- Create debugging bootstrap pod with backups storage mounted: `helm install devstats-test-debug ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipPostgres=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1`.
- Shell into that pod: `../devstats-k8s-lf/util/pod_shell.sh debug`.
- Backup new project(s): `NOBACKUP='' NOAGE=1 GIANT=wait ONLY='dbname' ./devstats-helm/backups.sh`.
- Exit the pod and delete Helm deployment: `helm delete devstats-test-debug`.
- Restore from the backup (example): `helm install devstats-test-proj ./devstats-helm --set skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexPVsFrom=0,indexPVsTo=1,indexProvisionsFrom=0,indexProvisionsTo=1,indexCronsFrom=0,indexCronsTo=1,indexGrafanasFrom=0,indexGrafanasTo=1,indexServicesFrom=0,indexServicesTo=1,indexAffiliationsFrom=0,indexAffiliationsTo=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skikAddAll=1,provisionCommand='devstats-helm/restore.sh',restoreFrom='https://teststats.cncf.io/backups/'`.
- Then follow: `./scripts/deploy_test.sh`.

Prod instance:

- Switch to `prod` context: `k config use-context prod`.
- Clone `devstats-helm` repo: `git clone https://github.com/cncf/devstats-helm`, `cd devstats-helm`.
- Deploy DevStats secrets: `helm install devstats-prod-secrets ./devstats-helm --set namespace='devstats-prod',skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Deploy backups PV (ReadWriteMany): `helm install devstats-prod-backups-pv ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Deploy 4-node patroni HA database (Postgres 13.X): `helm install devstats-prod-patroni ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Shell into the patroni master pod (after all 4 patroni nodes are in `Running` state: `k get po -n devstats-prod | grep devstats-postgres-`): `k exec -n devstats-prod -it devstats-postgres-0 -- /bin/bash`: 
  - Run: `patronictl list` to see patroni cluster state.
  - Tweak patroni: `curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "80GB", "max_parallel_workers_per_gather": "28", "max_connections": "1024", "min_wal_size": "1GB", "max_wal_size": "16GB", "effective_cache_size": "128GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "default_statistics_target": 1000, "effective_io_concurrency": 8, "random_page_cost": 1.1, "wal_buffers": "128MB", "max_worker_processes": "32", "max_parallel_workers": "32", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "30min", "hot_standby": "on", "hot_standby_feedback": "on", "wal_log_hints": "on", "wal_keep_segments": "10", "wal_keep_size": "4GB", "wal_level": "replica", "max_wal_senders": "5", "max_replication_slots": "5"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .`
  - `patronictl restart --force devstats-postgres`.
  - `patronictl show-config` to confirm config.
- Check patroni logs: `k logs -n devstats-prod -f devstats-postgres-N`, N=0,1,2,3.
- Install static page handlers (default and for prod, cdf and graphql domains): `helm install devstats-prod-statics ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipAPI=1,skipNamespaces=1,indexStaticsFrom=1`.
- Deploy prod domain ingress: `helm install devstats-prod-ingress ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipAliases=1,indexDomainsFrom=1,ingressClass=nginx-prod,sslEnv=prod`.
- Deploy/bootstrap logs database: `helm install devstats-prod-bootstrap ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1`.
- Delete finished bootstrap pod (when in `Completed` state): `k delete po devstats-provision-bootstrap`.
- Deploy backups cron job: `helm install devstats-prod-backups ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,backupsCronProd='45 2 10,24 * *',backupsTestServer='',backupsProdServer='1'`.
- Create API service: `helm install devstats-prod-api ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1,apiImage='lukaszgryglicki/devstats-api-prod'`.
- If you want to use a backup from different server (like during the switchover):
- Create debugging bootstrap pod with backups storage mounted: `helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1`.
- Shell into that pod: `../devstats-k8s-lf/util/pod_shell.sh debug`.
- Backup new project(s): `NOBACKUP='' NOAGE=1 GIANT=wait ONLY='dbname' ./devstats-helm/backups.sh`.
- Exit the pod and delete Helm deployment: `helm delete devstats-prod-debug`.
- Restore from the backup (example): `helm install devstats-prod-proj ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexPVsFrom=0,indexPVsTo=1,indexProvisionsFrom=0,indexProvisionsTo=1,indexCronsFrom=0,indexCronsTo=1,indexGrafanasFrom=0,indexGrafanasTo=1,indexServicesFrom=0,indexServicesTo=1,indexAffiliationsFrom=0,indexAffiliationsTo=1,provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/restore.sh',restoreFrom='https://devstats.cncf.io/backups/',testServer='',prodServer='1'`.
- Then follow: `./scripts/deploy_prod.sh`.


# DevStats deployment examples

See either `test/README.md` or `prod/README.md`.


# Usage

You should set namespace to 'devstats-test' or 'devstats-prod' first: `./switch_context.sh test`.

Please provide secret values for each file in `./secrets/*.secret.example` saving it as `./secrets/*.secret` or specify them from the command line.

Please note that `vim` automatically adds new line to all text files, to remove it run `truncate -s -1` on a saved file.

List of secrets:
- File `secrets/PG_ADMIN_USER.secret` or --set `pgAdminUser=...` setup postgres admin user name.
- File `secrets/PG_HOST.secret` or --set `pgHost=...` setup postgres host name.
- File `secrets/PG_HOST_RO.secret` or --set `pgHostRO=...` setup postgres host name (read-only).
- File `secrets/PG_PASS.secret` or --set `pgPass=...` setup postgres password for the default user (gha_admin).
- File `secrets/PG_PASS_RO.secret` or --set `pgPassRO=...` setup for the read-only user (ro_user).
- File `secrets/PG_PASS_TEAM.secret` or --set `pgPassTeam=...` setup the team user (also read-only) (devstats_team).
- File `secrets/PG_PASS_REP.secret` or --set `pgPassRep=...` setup the replication user.
- File `secrets/PG_PORT.secret` or --set `pgPort=...` setup postgres port.
- File `secrets/GHA2DB_GITHUB_OAUTH.secret` or --set `githubOAuth=...` setup GitHub OAuth token(s) (single value or comma separated list of tokens).
- File `secrets/GF_SECURITY_ADMIN_USER.secret` or --set `grafanaUser=...` setup Grafana admin user name.
- File `secrets/GF_SECURITY_ADMIN_PASSWORD.secret` or --set `grafanaPassword=...` setup Grafana admin user password.

You can select which secret(s) should be skipped via: `--set skipPGSecret=1,skipGitHubSecret=1,skipGrafanaSecret=1`.

You can install only selected templates, see `values.yaml` for detalis (refer to `skipXYZ` variables in comments), example:
- `helm install --dry-run --debug --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,runTests=1,ingressClass=nginx-test`.

You can restrict ranges of projects provisioned and/or range of cron jobs to create via:
- `--set indexPVsFrom=5,indexPVsTo=9,indexProvisionsFrom=5,indexProvisionsTo=9,indexCronsFrom=5,indexCronsTo=9,indexAffiliationsFrom=5,indexAffiliationsTo=9,indexGrafanasFrom=5,indexGrafanasTo=9,indexServicesFrom=5,indexServicesTo=9,indexIngressesFrom=5,indexIngressesTo=9,indexDomainsFrom=0,indexDomainsTo=2,indexStaticsFrom=0,indexStaticsTo=2`.

You can overwrite the number of CPUs autodetected in each pod, setting this to 1 will make each pod single-threaded
- `--set nCPUs=1`.

You can deploy reports pod (it waits forever) so you can bash into it and generate DevStats reports: `--set reportsPod=1`. See `test/README.md` for details, search for `reportsPod`.

Please note variables commented out in `./devstats-helm/values.yaml`. You can either uncomment them or pass their values via `--set variable=name`.

Resource types used: secret, pv, pvc, po, cronjob, deployment, svc

To debug provisioning use:
- `helm install --debug --dry-run --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,ingressClass=nginx-test,indexProvisionsFrom=0,indexProvisionsTo=1,provisionPodName=debug,provisionCommand=sleep,provisionCommandArgs={36000s}`.
- `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipPostgres=1,ingressClass=nginx-test,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={36000s}`
- Bash into it: `github.com/cncf/devstats-k8s-lf`: `./util/pod_shell.sh devstats-provision-cncf`.
- Then for example: `PG_USER=gha_admin db.sh psql cncf`, followed: `select dt, proj, prog, msg from gha_logs where proj = 'cncf' order by dt desc limit 40;`.
- Finally delete pod: `kubectl delete pod devstats-provision-cncf`.


# Architecture

DevStats data sources:

- GHA ([GitHub Archives](https://www.gharchive.org)) this is the main data source, it uses GitHub API in real-time and saves all events from every hour into big compressed files containing all events from that hour (JSON array).
- GitHub API (we're only using this to track issues/PRs hourly to make sure we're not missing events - GHA sometimes misses some events).
- git - we're storing closes for all GitHub repositories from all projects - that allows file-level granularity commits analysis.

Storage:

- All data from datasources are stored in HA Postgres database (patroni -Postgres 13.X).
- Git repository clones are stored in per-pod persistent volumes (type node local storage). Each project has its own persistent volume claim to store its git data.
- All volumes used for database or git storage use `ReadWriteOnce` and are private to their corresponding pods.
- We are using OpenEBS to dynamically provision persistent volumes using local-storage.
- For ReadWriteMany (RWX) access we're using OpenEBS local-storage (which provides ReadWriteOnce) and nfs-server-provisioner which allows multiple write access (this is used for backups and exposing Grafana DBs).
- You can also use OpenEBS cStor for storage (optional and not used - this gives redundance at the storage level instead of depending Kubernetes statefulset for redundancy).

Database:

- We are using HA patroni Postgres 13 database consisting of 4 nodes. Each node has its own persistent volume claim (local node storage) that stores database data. This gives 4x redundancy.
- Docker limits each pod's shared memory to 64MB, so all patroni pods are mounting special volume (type: memory) under /dev/shm, that way each pod has unlimited SHM memory (actually limited by RAM accessible to pod).
- Patroni image runs as postgres user so we're using security context filesystem group 999 (postgres) when mounting PVC for patroni pod to make that volume writable for patroni pod.
- Patroni supports automatic master election (it uses RBAC's and manipulates service endpoints to make that transparent for app pods).
- Patroni is providing continuous replication within those 4 nodes.
- We are using pod anti-affinity to make sure each patroni pod is running on a different node.
- Write performance is limited by single node power, read performance is up to 4x (3 read replicas and master).
- We're using time-series like approach when generating final data displayed on dashboards (custom time-series implementation at top of postgres database).
- We're using cron job to backups GitHub API events data for all projects daily (only GitHub API data is backed up because GHA and git data can be regenerated from scratch without any dataloss).

Cluster:

- We are using bare metal cluster running `v1.20` Kubernetes that is set up manually as described in this document. Kubernetes uses CoreDNS and docker as CRI, docker uses containerd.
- Currently we're using 4 metal.equinix.com servers (type `m2.xlarge.x86`) in `SV15` zone (Silicon Valley).
- We are using Helm 3 for deploying entire DevStats project.

UI:

- We are using Grafana 7.X, all dashboards, users and datasources are automatically provisioned from JSONs and template files.
- We're using read-only connection to HA patroni database to take advantage of read-replicas and 4x faster read connections.
- Grafana is running on plain HTTP and port 3000, ingress controller is responsible for SSL/HTTPS layer.
- We're using liveness and readiness probles for Grafana instances to allow detecting unhealthy instances and auto-replace by Kubernetes in such cases.
- We're using rolling updates when adding new dashboards to ensure no downtime, we are keeping 2 replicas for Grafanas all time.

DNS:

- We're using CNCF registered wildcard domain pointing to our MetalLB load balancer with nginx-ingress controller.

SSL/HTTPS:

- We're using `cert-manager` to automatically obtain and renewal Let's Encrypt certificates for our domain.
- CRD objects are responsible for generating and updating SSL certs and keeping them in auto-generated kubernetes secrets used by our ingress.

Ingress:

- We're using `nginx-ingress` to provide HTTPS and to disable plain HTTP access.
- Ingress holds SSL certificate data in annotations (this is managed by `cert-manager`).
- Based on the request hostname `prometheus.teststats.cncf.io` or `envoy.devstats.cncf.io` we're redirecting traffic to a specific Grafana service (running on port 80 inside the cluster).
- Each Grafana has internal (only inside the cluster) service from port 3000 to port 80.

Deployment:

- Helm chart allows very specific deployments, you can specify which objects should be created and also for which projects.
- For example you can create only Grafana service for Prometheus, or only provision CNCF with a non-standard command etc.

Resource configuration:

- All pods have resource (memory and CPU) limits and requests defined.
- We are using node selector to decide where pods should run (we use `app` pods for Grafanas and Devstats pods and `db` for patroni pods)
- DevStats pods are either provisioning pods (running once when initializing data) or hourly-sync pods (spawned from cronjobs for all projects every hour).

Secrets:

- Postgres connection parameters, Grafana credentials, GitHub oauth tokes are all stored in `*.secret` files (they're gitignored and not checked into the repo). Each such file has `*.secret.example` counterpart as a hint for user to create the actual `*.secret` file.

Docker images:

- We're using docker as our container engine, all images are defined in `github.com/cncf/devstats-docker-images` and pushed to the docker hub under `lukaszgryglicki` username.
- Docker is configured to use containerd.
- `devstats-test`, `devstats-prod` - full devstats images, contining provisioning/bootstrap scripts - used for provisioning each project and initial bootstapping database (different for test and prod deployments).
- `devstats-minimal-test`, `devstats-minimal-prod` - minimal devstats images, used by hourly-sync cron jobs (contains only tools needed to do a hourly sync).
- `devstats-grafana` - Grafana image containing all tools to provision Grafana for a given project (dashboards JSONs, datasource/config templates etc.).
- `devstats-tests` - image containing all DevStats tests (it contains Go 1.12 runtime and postgres 11 database, executes database, series, metrics, regexp and other tests and other checks: format, lint, imports, vet, const, usedexports, errcheck).
- `lukaszgryglicki/devstats-patroni` - patroni for handling database directory permissions on already existing PVs.

CI/CD:

- We are using Travis CI on GitHub push events to devstats repositories.
- Travis uses docker to download `devstats-test` image which has its own Postgres 11 database and Go 1.12 runtime.
- Test image running from docker starts its own Postgres 11 instance and then downloads newest devstats repositories from GitHub and executes all tests.
- After tests are finished, Travis passes results to a webhook that receives tests results, and deploys new devstats version depending on test results and commit message (it can skip deploy if special flags are used in the commit message).
- Currently only bare metal instances are configured to receive Travis tests results and eventually deploy on success.

Kubernetes dashboard

- You can track cluster state using Kubernetes dashboards, see [how to install it](https://github.com/cncf/devstats-kubernetes-dashboard).

Architecture:

- Bootstrap pod - it is responsible for creating logs database (shared by all devstats pods instances), users (admin, team, readonly), database permissions etc. It waits for patroni HA DB to become ready before doing its job. It doesn't mount any volumes. Patroni credentials come from secret.
- Grafana pods - each project has its own Grafana deployment. Grafana pods are not using persistent volumes. They use read-only patroni connection to take advantage of HA (read replicas). Grafana credentials come from secret.
- Hourly sync cronjobs - each project has its own cron job that runs every hour (on different minute). It uses postgres and github credentials from secret files. It mounts per-project persistent volume to keep git clones stored there. It ensures that no provisioning is running for that project before syncing data. Next cron job can only start when previous finished.
- Ingress - single instance but containing variable number of configurations (one hostname per one project). It adds https and direct traffic to a proper grafana service instance. `cert-manager` updates its annotations when SSL cert is renewed.
- Postgres endpoint - endpoint for PostgreSQL master service. On deploy, this does nothing; once spun up, the master pod will direct it to itself.
- Postgres rolebinding - Postgres RBAC role binding.
- Postgres role - Postgres RBAC role. Required for the deployed postgres pods to have control over configmaps, endpoint and services required to control leader election and failover.
- Postgres statefulset - main patroni objcet - creates 4 nodes, uses security group to allow mounting its volume as a postgres user. Creates 4 nodes (1 becomes master, 3 read-replicas). Each node has its own per-node local storage (which is replicated from master). Uses SHM memory hack to allow docker containers use full RAM for SHM. gets postgres credentials from secret file. each node exposes postgres port and a special `patroni` REST API port 8008. Holds full patroni configuration.
- Postgres service account - needed to manage Postgres RBAC.
- Postgres service config - placeholder service to keep the leader election endpoint from getting deleted during initial deployment. Not useful for connecting to anything: `postgres-service-config`.
- Postgres service read-only - service for load-balanced, read-only connections to the pool of PostgreSQL instances: `postgres-service-ro`.
- Postgres service - service for read/write connections, that is connections to the master node: `postgres-service` - this remains constant while underlying endpoint will direct to the current patroni master node.
- Provisioning pods - each project initially starts provisioning pod that generates all its data. They set special flag on their DB so cronjobs will not interfere their work. It waits for patroni to become ready and for bootstrap to be complete (shared logs DB, users, permissions etc.). It uses full devstats image to do provisioning, each project has its own persistent volume that holds git clones data. GitHub and Postgres credentials come from secrets. If cron job is running this won't start (this is to avoid interfering cronjob with a non-standard provision call executed later, for example updating company affiliations etc.)
- Persistent Volumes - each project has its own persistent volume for git repo clones storage, this is used only by provisioning pods and cron jobs.
- Secrets - holds GitHub OAuth token(s) (DevStats can use >1 token and switch between them when approaching API limits), Postgres credentials and connection parameters, Grafana credentials.
- Grafana services - each project has its own grafana service. It maps from Grafana port 3000 into 80. They're endpoint for Ingress depending on project (distinguished by hostname).
- Backups - cron job that runs daily (at 3 AM or 4 AM test/prod) - it backups all GitHub API data into a RWX volume (OpenEBS + local-storage + NFS) - this is also mounted by Grafana services (to expose each Grafana's SQLite DB) and static content pod (to display links to GH API data backups for all projects).
- Static content pods - one for default backend showing list of foundations (domains) handled by DevStats, and one for every domain served (to display given domain's projects and DB backups): teststats.cncf.io, devstats.cncf.io, devstats.cd.foundation, devstats.graphql.org.
- Reports pod - this is a pod doing nothing and waiting forever, you can shell to it and create DevStats reports from it. It has backups PV mounted RW, so you can put output files there, it is mounted into shared nginx directory, so those reports can be downloaded from the outside world.


# Adding new projects

See `ADDING_NEW_PROJECTS.md` for informations about how to add more projects.


# Expired kubectl certificates

If you get `` Unable to connect to the server: x509: certificate has expired or is not yet valid `` error, that means your kubectl certificates have expired.

You can check their expiration date via: `kubeadm certs check-expiration`.

You can renew them via: `kubeadm certs renew all`.

Then you need: `cp ~/.kube/config ~/.kube/config.2021-12-15; cp /etc/kubernetes/kubelet.conf ~/.kube/config; cd ~/.kube/`.

For all nodes: `sftp user@node-name`, then `cd .kube`, `rm config`, `mput config`, `mput config.2021-12-15`.

Restart all nodes one after another.

