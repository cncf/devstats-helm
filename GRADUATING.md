# Changing projects state (moving to incubation, graduating etc)

1. Go to `cncf/devstats-docker-images`:

- Update status in `*/projects.yaml`.
- Add `graduated_date` or similar (`incubating_date`, `archived_date`).
- Graduation/Incubation dates are [here](https://docs.google.com/spreadsheets/d/10-rSBsSMQZD6nCLBkyKfeU4kdffB4bOSV0NnZqF5bBk/edit#gid=1632287387).


2. Go to `cncf/devstats`:

- Follow instructions from `cncf/devstats`:`GRADUATING.md`.


3. Go to `cncf/devstats-docker-images`:

- Consider upgrading Grafana: `vim ./images/Dockerfile.grafana`.
- Run `DOCKER_USER=... SKIP_PATRONI=1 ./images/build_images.sh` to build a new images.
- Eventually run `DOCKER_USER=... ./images/remove_images.sh` to remove image(s) locally (new image is pushed to the Docker Hub).


4. Go to `cncf/devstats-helm`:

While on the `devstats-test` namespace: `git pull`, then:

- Recreate static pages handler: `../devstats-k8s-lf/util/delete_objects.sh po devstats-static-test`.
- If graduation/incubation in the past - generate annotations for this project: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/annotations.sh',indexProvisionsFrom=X,indexProvisionsTo=Y,provisionPodName=anno`
- Run vars regenerate on all projects: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/vars.sh',provisionPodName=vars`.
- Recreate Grafanas: `rm ~/recreate.log && ITER=1 ./delete_objects.sh po devstats-grafana- &>> ~/recreate.log &`, `clear && tail -f ~/recreate.log`.
- Reinit TSDB data may be needed: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='./devstats-helm/reinit.sh',projectsOverride='+cncf\,+opencontainers\,+istio\,+zephyr\,+linux\,+rkt\,+sam\,+azf\,+riff\,+fn\,+openwhisk\,+openfaas\,+cii\,+prestodb\,+godotengine\,+opentracing',indexProvisionsFrom=X,indexProvisionsTo=Y,nCPUs=8`.
- You can regenerate Health dashboard too: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=38,indexProvisionsTo=39`.
- Delete intermediate helm installs - those with auto generated name like `devstats-helm-1565240123`: `helm delete devstats-helm-1565240123`.

While on the `devstats-prod` namespace: `git pull`, then:

- Recreate static pages handler: `../devstats-k8s-lf/util/delete_objects.sh po devstats-static-prod`.
- If graduation/incubation in the past - generate annotations for this project: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/annotations.sh',indexProvisionsFrom=X,indexProvisionsTo=Y,provisionPodName=anno`.
- Run vars regenerate on all projects: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/vars.sh',provisionPodName=vars`.
- Wait for it to finish: `clear && k get po -w | grep vars`.
- Recreate Grafanas: `rm ~/recreate.log && ITER=1 ./delete_objects.sh po devstats-grafana- &>> ~/recreate.log &`, `clear && tail -f ~/recreate.log`.
- Reinit TSDB data may be needed: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='./devstats-helm/reinit.sh',indexProvisionsFrom=X,indexProvisionsTo=Y,nCPUs=8`.
- You can regenerate Health dashboards too: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=38,indexProvisionsTo=39`.
- Delete intermediate helm installs - those with auto generated name like `devstats-helm-1565240123`: `helm delete devstats-helm-1565240123`.


5. Update `LF-Engineering/lfx-redshift-migration`:
- Update the `sql/sp/sp_sync_project.sql` file to specify maturity level of the new projects added, or update existing project maturity level.
