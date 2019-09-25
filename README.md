# devstats-helm
DevStats deployment on bare metal Kubernetes using Helm.

This is deployed:
- [CNCF test](https://teststats.cncf.io) (this also includes CDF, GraphQL test instance, for example [GraphQL All](https://graphql.teststats.cncf.io) and [CDF All](https://allcdf.teststats.cncf.io)).
- [CNCF prod](https://devstats.cncf.io).
- [CDF prod](https://devstats.cd.foundation).
- [GraphQL prod](https://devstats.graphql.org).


# Installing Kubernetes on bare metal

- Setup 4 packet.net servers, give them hostnames: master, node-0, node-1, node-2.
- Install Ubuntu 18.04 LTS on all of them, then update apt `apt update`, `apt upgrade`.
- Turn swap off on all of them `swapoff -a`.
- Reference: [installing kubeadm](https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/).
- `sudo apt install docker.io`, then `kubeadm config images pull` on all nodes.
- `systemctl enable docker.service` to enable docker.
- Follow: [this](https://kubernetes.io/docs/setup/production-environment/container-runtimes/#docker) to set `systemd` as `cgroup` driver.
- `kubeadm init --pod-network-cidr=10.244.0.0/16` on master.
- Choose networking from [here](https://kubernetes.io/docs/concepts/cluster-administration/addons/).
- `kubeadm join ...` as returned by `kubeadm init` on all nodes (excluding master).
- `sysctl net.bridge.bridge-nf-call-iptables=1`.
- Flannel example: `kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/62e44c867a2846fefb68bd5f178daf4da3095ccb/Documentation/kube-flannel.yml`.
- Calico example `wget https://docs.projectcalico.org/v3.9/manifests/calico.yaml`, then `vim calico.yaml` (replace `192.168.0.0/16` CIDR with `10.244.0.0/16`) then `k apply -f calico.yaml`.
- `kubectl get pods --all-namespaces`.
- `kubectl taint nodes --all node-role.kubernetes.io/master-`.
- `kubectl get nodes`.
- Your should now label nodes for `db` and `app` (you can mark all of them `app` and `db` if youd want to allow all types of pods running on all nodes).
- `kubectl label nodes <node-name> <label-key>=<label-value>`.


# Install Helm

- `wget https://get.helm.sh/helm-v3.0.0-alpha.1-linux-amd64.tar.gz`.
- `tar zxfv helm-v3.0.0-alpha.1-linux-amd64.tar.gz`.
- `mv linux-amd64/helm /usr/local/bin`.
- `rm -rf linux-amd64/ helm-v3.0.0-alpha.1-linux-amd64.tar.gz`.
- `helm init`.
- `Note that helm v3 no longer needs tiller`.


# Setup per-node local storage

- Install OpenEBS: `kubectl apply -f https://openebs.github.io/charts/openebs-operator-0.9.0.yaml`.
- Make its local-storage driver the default storage class: `kubectl patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`.
- Make sure that `/var/openebs` directory on all nodes is placed on the physical volume you want to use for local storage. You can have a huge NVMe disk mounted on `/disk` for instance. In this case `mv /var/openebs /disk/openebs; ln -s /disk/openebs /var/openebs`.
- You will also need a shared storage for backups (ReadWriteMany access mode - backup pods are writing, static pages are reading).
- Install nfs-utils on all your nodes: `apt install -y nfs-common`.
- Install NFS provisioner that will use OpenEBS local storage while on `default` namespace: `helm install local-storage-nfs stable/nfs-server-provisioner --set=persistence.enabled=true,persistence.storageClass=openebs-hostpath,persistence.size=2Ti,storageClass.name=nfs-openebs-localstorage`


# Optional cStor OpenEBS storage

This is optional. You can setup a cStor OpenEBS storage (handles disk stripping/mirroring, replicas etc.)

- List your disks by calling `k get disks`. Then copy `cp openebs/cstor-pool-config.yaml.example openebs/cstor-pool-config.yaml` and add your disks there. Them `kubectl apply -f openebs/cstor-pool-config.yaml`. You will have a new StoragePoolClaim: `cstor-pool1`.
- Create storage class for newly createid cStor pool: `k apply -f openebs/cstor-storageclass.yaml`. You will have a new storage class: `openebs-disk-cstor`.


# Adding new projects

See `ADDING_NEW_PROJECTS.md` for informations about how to add more projects.


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

- Switch to `test` context via: `./switch_context.sh test`.
- First you need `nginx-ingress`: `helm install nginx-ingress-test stable/nginx-ingress --set controller.ingressClass=nginx-test`.
- Switch to `prod` context via: `./switch_context.sh prod`.
- Install `nginx-ingress`: `helm install nginx-ingress-prod stable/nginx-ingress --set controller.ingressClass=nginx-prod`.
- Switch to `shared` context via: `./switch_context.sh shared`.
- Install MetalLB (load balancer): `kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.7.3/manifests/metallb.yaml`.
- Configure MetalLB IP addresses (use two IPs from your cluster nodes and/or master): `https://metallb.universe.tf/configuration/`. Use `metallb/config.yaml.example` as an example, replace X.Y.Z.V with one of your nodes static IP.
- Note External-IP fields from `kubectl --namespace devstats-test get services -o wide -w nginx-ingress-test-controller` and `kubectl --namespace devstats-prod get services -o wide -w nginx-ingress-prod-controller`.


# SSL

You need to have domain name pointing to your MetalLB IP before proceeding.

Install SSL certificates using Let's encrypt and auto renewal using `cert-manager`: `SSL.md`.


# DevStats deployment

See either `test/README.md` or `prod/README.md`.


# Tweak patroni

You should tweak deployed patroni instances:

- Manually login to a deployed patroni instance (on test and prod namespaces): `cncf/devstats-k8s-lf`:`util/pod_shell.sh devstats-postrges-0`.
- Apply the "final one" config from `scripts/patroni_rest_api.sh` script.


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
- `helm install --dry-run --debug --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1,runTests=1,ingressClass=nginx-test`.

You can restrict ranges of projects provisioned and/or range of cron jobs to create via:
- `--set indexPVsFrom=5,indexPVsTo=9,indexProvisionsFrom=5,indexProvisionsTo=9,indexCronsFrom=5,indexCronsTo=9,indexAffiliationsFrom=5,indexAffiliationsTo=9,indexGrafanasFrom=5,indexGrafanasTo=9,indexServicesFrom=5,indexServicesTo=9,indexIngressesFrom=5,indexIngressesTo=9,indexDomainsFrom=0,indexDomainsTo=2,indexStaticsFrom=0,indexStaticsTo=2`.

You can overwrite the number of CPUs autodetected in each pod, setting this to 1 will make each pod single-threaded
- `--set nCPUs=1`.

You can deploy reports pod (it waits forever) so you can bash into it and generate DevStats reports: `--set reportsPod=1`. See `test/README.md` for details, search for `reportsPod`.

Please note variables commented out in `./devstats-helm/values.yaml`. You can either uncomment them or pass their values via `--set variable=name`.

Resource types used: secret, pv, pvc, po, cronjob, deployment, svc

To debug provisioning use:
- `helm install --debug --dry-run --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1,ingressClass=nginx-test,indexProvisionsFrom=0,indexProvisionsTo=1,provisionPodName=debug,provisionCommand=sleep,provisionCommandArgs={36000s}`.
- `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipNamespaces=1,skipPostgres=1,ingressClass=nginx-test,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={36000s}`
- Bash into it: `github.com/cncf/devstats-k8s-lf`: `./util/pod_shell.sh devstats-provision-cncf`.
- Then for example: `PG_USER=gha_admin db.sh psql cncf`, followed: `select dt, proj, prog, msg from gha_logs where proj = 'cncf' order by dt desc limit 40;`.
- Finally delete pod: `kubectl delete pod devstats-provision-cncf`.


# Architecture

DevStats data sources:

- GHA ([GitHub Archives](https://www.gharchive.org)) this is the main data source, it uses GitHub API in real-time and saves all events from every hour into big compressed files containing all events from that hour (JSON array).
- GitHub API (we're only using this to track issues/PRs hourly to make sure we're not missing wvents - GHA sometimes misses some events).
- git - we're storing closes for all GitHub repositories from all projects - that allows file-level granularity commits analysis.

Storage:

- All data from datasources are stored in HA Postgres database (patroni).
- Git repository clones are stored in per-pod persistent volumes (type node local storage). Each project has its own persisntent volume claim to store its git data.
- All volumes used for database or git storage use `ReadWriteOnce` and are private to their corresponding pods.
- We are using OpenEBS to dynamically provision persistent volumes using local-storage.
- For ReadWriteMany (RWX) access we're using OpenEBS local-storgae (which provides ReadWriteOnce) and nfs-server-provisioner which allows multiple write access (this is used for backups and exposing Grafana DBs).
- You can also use OpenEBS cStor for storage (optional and not used - this gives redundance at the storage level instead of depending Kubernetes statefulset for redundancy).

Database:

- We are using HA patroni postgres 11 database consisting of 4 nodes. Each node has its own persistent volume claim (local node storage) that stores database data. This gives 4x redundancy.
- Docker limits each pod's shared memory to 64MB, so all patroni pods are mounting special volume (type: memory) under /dev/shm, that way each pod has unlimited SHM memory (actually limited by RAM accessible to pod).
- Patroni image runs as postgres user so we're using security context filesystem group 999 (postgres) when mounting PVC for patroni pod to make that volume writable for patroni pod.
- Patroni supports automatic master election (it uses RBAC's and manipulates service endpoints to make that transparent for app pods).
- Patroni is providing continuous replication within those 4 nodes.
- We are using pod anti-affinity to make sure each patroni pod is running on a different node.
- Write performance is limited by single node power, read performance is up to 4x (3 read replicas and master).
- We're using time-series like approach when generating final data displayed on dashboards (custom time-series implementation at top of postgres database).
- We're using cron job to backups GitHub API events data for all projects daily (only GitHub API data is backed up because GHA and git data can be regenerated from scratch without any dataloss).

Cluster:

- We are using bare metal cluster running `v1.14.2` Kubernetes that is set up manually as descibed in this document.
- Currently we're using 4 packet.net servers (type `m2.xlarge.x86`) in `SJC1` zone (US West coast).
- We are using Helm for deploying entire DevStats project.

UI:

- We are using Grafana 6.2.2, all dashboards, users and datasources are automatically provisioned from JSONs and template files.
- We're using read-only connection to HA patroni database to take advantage of read-replicas and 4x faster read connections.
- Grafana is running on plain HTTP and port 3000, ingress controller is responsible for SSL/HTTPS layer.
- We're using liveness and readiness probles for Grafana instances to allow detecting unhealhty instances and auto-replace by Kubernetes in such cases.
- We're using rolling updates when adding new dashboards to ensure no downtime, we are keeping 2 replicas for Grafanas all time.

DNS:

- We're using CNCF registered wildcard domain pointing to our MetalLB load balancer with nginx-ingress controller.

SSL/HTTPS:

- We're using `cert-manager` to automatically obtain and renewal Let's Encrypt certificates for our domain.
- CRD objects are responsible for generating and updating SSL certs and keeping them in auto-generated kubernetes secrets used by our ingress.

Ingress:

- We're using `nginx-ingress` to provide HTTPS and to disable plain HTTP access.
- Ingress holds SSL certificate data in annotations (this is managed by `cert-manager`).
- Based on the request hostname `prometheus.teststats.cncf.io` or `envoy.devstats.cncf.io` we're redirecting trafic to a specific Grafana service (running on port 80 inside the cluster).
- Each Grafana has internal (only inside the cluster) service from port 3000 to port 80.

Deployment:

- Helm chart allows very specific deployments, you can specify which obejcts should be created and also for which projects.
- For example you can create only Grafana service for Prometheus, or only provision CNCF with a non-standar command etc.

Resource configuration:

- All pods have resource (memory and CPU) limits and requests defined.
- We are using node selector to decide where pods should run (we use `app` pods for Grafanas and Devstats pods and `db` for patroni pods)
- DevStats pods are either provisioning pods (running once when initializing data) or hourly-sync pods (spawned from cronjobs for all projects every hour).

Secrets:

- Postgres connection parameters, Grafana credentials, GitHub oauth tokes are all stored in `*.secret` files (they're gitignored and not checked into the repo). Each such file has `*.secret.example` counterpart as a hint for user to create the actual `*.secret` file.

Docker images:

- We're using docker as our container engine, all images are defined in `github.com/cncf/devstats-docker-images` and pushed to the docker hub under `lukaszgryglicki` username.
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

- Bootstrap pod - it is responsible for creating logs database (shared by all devstats pods instances), users (admin, team, readonly), database permissions etc. It waits for patroni HA DB to become ready before doing its job. It doesn't mount aby volumes. Patroni credentials come from secret.
- Grafana pods - each project has its own Grafana deployment. Grafana pods are not using persistent volumes. They use read-only patroni connection to take advantage of HA (read replicas). Grafana credentials come from secret.
- Hourly sync cronjobs - each project has its own cron job that runs every hour (on different minute). It uses postgres and github credentials from secret files. It mounts per-project persistent volume to keep git clones stored there. It ensures that no provisioning is running for that project before syncing data. Next cron job can only start when previous finished.
- Ingress - single instance but containing variable number of configurations (one hostname per one project). It adds https and direct trafic to a proper grafana service instance. `cert-manager` updates its annotations when SSL cert is renewed.
- Postgres endpoint - endpoint for PostgreSQL master service. On deploy, this does nothing; once spun up, the master pod will direct it to itself.
- Postgres rolebinding - Postgres RBAC role binding.
- Postgres role - Postgres RBAC role. Required for the deployed postgres pods to have control over configmaps, endpoint and services required to control leader election and failover.
- Postgres statefulset - main patroni objcet - creates 4 nodes, uses security group to allow mounting its volume as a postgres user. Creates 4 nodes (1 becomes master, 3 read-replicas). Each node has its own per-node local storage (which is replicated from master). Uses SHM memory hack to allow docker containers use full RAM for SHM. gets postgres credentials from secret file. each node exposes postgres port and a special `patroni` REST API port 8008. Holds full patroni configuration.
- Postgres service account - needed to manage Postgres RBAC.
- Postgres service config - placeholder service to keep the leader election endpoint from getting deleted during initial deployment. Not useful for connecting to anything: `postgres-service-config`.
- Postgres service read-only - service for load-balanced, read-only connections to the pool of PostgreSQL instances: `postgres-service-ro`.
- Postgres service - service for read/write connections, that is connections to the master node: `postgres-service` - this remains constant while underlying endpoint will direct to the current patroni master node.
- Provisioning pods - each project initailly starts provisioning pod that generates all its data. They set special flag on their DB so cronjobs will not interfere their work. It waits for patroni to become ready and for bootstrap to be complete (shared logs DB, users, permissions etc.). It uses full devstats image to do provisioning, each project has its own persistent volume that holds git clones data. GitHub and Postgres credentials come from secrets. If cron job is running this won't start (this is to avoid interfering cronjob with a non-standar provision call executed later, for example updating company affiliations etc.)
- Persistent Volumes - each project has its own persistent volume for git repo clones storage, this is used only by provisioning pods and cron jobs.
- Secrets - holds GitHub OAuth token(s) (DevStats can use >1 token and switch between them when approaching API limits), Postgres credentials and connection parameters, Grafana credentials.
- Grafana services - each project has its own grafana service. It maps from Grafana port 3000 into 80. They're endpoint for Ingress depending on project (distinguised by hostname).
- Backups - cron job that runs daily (at 3 AM or 4 AM test/prod) - it backups all GitHub API data into a RWX volume (OpenEBS + local-storage + NFS) - this is also mounted by Grafana services (to expose each Grafana's SQLite DB) and static content pod (to display links to GH API data backups for all projects).
- Static content pods - one for default backend showing list of foundations (domains) handled by DevStats, and one for every domain served (to display given domain's projects and DB backups): teststats.cncf.io, devstats.cncf.io, devstats.cd.foundation, devstats.graphql.org.
- Reports pod - this is a pod doing nothing and waiting forever, you can shell ito it and create DevStats reports from it. It has backups PV mounted RW, so you can put output files there, it is mounted into shared nginx directory, so those reports can be downloaded from the outside world.
