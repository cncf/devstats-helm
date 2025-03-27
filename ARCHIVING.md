# Changing projects state (moving to incubation, graduating etc)

1. Go to `cncf/devstats-docker-images`:

- Update status to `Archived` in `devstats-helm/projects.yaml`.
- Add `archived_date`.
- Refer to [this](https://docs.google.com/spreadsheets/d/10-rSBsSMQZD6nCLBkyKfeU4kdffB4bOSV0NnZqF5bBk/edit#gid=1632287387) and/or issues on [cncf/toc](https://github.com/cncf/toc) repo.


2. Go to `cncf/devstats`:

- Follow instructions from `cncf/devstats`:`ARCHIVING.md`.
- Update shared Grafana data.
- Delete project configuration form `all:` (current tracing in `devstats`:`projects.yaml`, `devstats-docker-images`:`devstats-helm/projects.yaml`).
- Consider updating `all/psql.sh` and `scripts/all/repo_groups.sql` - we currently don't remove archived projects from those files.


3. Go to `cncf/devstats-docker-images`:

- Consider upgrading Grafana: `vim ./images/Dockerfile.grafana`.
- Run `DOCKER_USER=... SKIP_PATRONI=1 ./images/build_images.sh` to build a new images.
- Eventually run `DOCKER_USER=... ./images/remove_images.sh` to remove image(s) locally (new image is pushed to the Docker Hub).


4. Go to `cncf/devstats-helm`:

While on the `devstats-prod` namespace: `git pull`, then:

- Recreate static pages handler: `../devstats-k8s-lf/util/delete_objects.sh po devstats-static-prod`.
- Recreate ingress with a new hostname: `helm delete devstats-prod-ingress`, `helm install devstats-prod-ingress ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexDomainsFrom=1,skipAliases=1,ingressClass=nginx-prod,sslEnv=prod`.
- Run vars regenerate on all projects: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/vars.sh',provisionPodName=vars`.
- Wait for it to finish: `clear && k get po -w | grep vars`.
- Recreate Grafanas: `rm ~/recreate.log && ITER=1 ./delete_objects.sh po devstats-grafana- &>> ~/recreate.log &`, `clear && tail -f ~/recreate.log`.
- Regenerate Health dashboards: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=38,indexProvisionsTo=39`.
- Delete intermediate helm installs - those with auto generated name like `devstats-helm-1565240123`: `helm delete devstats-helm-1565240123`.
- Delete cronjobs: `k delete cj -n devstats-prod devstats-proj devstats-affiliations-proj`.
- Delete deployment: `k delete deployment devstats-grafana-proj`.
- Delete service: `k delete service devstats-service-proj`.
- Delete projects database: `k exec -itn devstats-prod devstats-postgres-3 -- psql`, `drop database proj`.
- Delete PVC: `k delete pvc devstats-pvc-proj`.


5. Go to `cncf/velocity` (optional, we usually keep archived projects configuration):

- Update `reports/cncf_projects_config.csv`.
- Update `BigQuery/velocity_lf.sql BigQuery/velocity_cncf.sql`.



