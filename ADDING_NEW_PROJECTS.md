# Adding new projects

1. Go to `cncf/devstats-docker-images`:

- Add project entry to `devstats-helm/projects.yaml` file. (also update `all:`) Find projects orgs, repos, select start date, eventually add test coverage for complex regular expression in `cncf/devstatscode`:`regexp_test.go`.
- Graduation/Incubation dates are [here](https://docs.google.com/spreadsheets/d/10-rSBsSMQZD6nCLBkyKfeU4kdffB4bOSV0NnZqF5bBk/edit#gid=1632287387).
- To identify repo and/or org name changes, date ranges for entrire projest use `cncf/devstats`:`util_sh/(repo|org)_name_changes_bigquery.sh org|org/repo`. There is also a more resource-consuming script, example use: `./util_sh/org_name_changes_complex.sh org 'year.201*'`.
- You may need to update `cncf/devstats`:`util_sql/(org|repo)_name_changes_bigquery.sql` to include newest months. Example: `` ./util_sh/org_repos_name_changes_bigquery.sh org-name ``.
- For other Helm deployments (like LF or GraphQL) update `k8s/projects.yaml` or `gql/projects.yaml` or `devstats-helm/projects.yaml` file instead of `example/projects.yaml`.
- Update `./images/build_images.sh` (add project's directory).
- Update `./k8s/all_*.txt` or `./example/all_*.txt` or `./gql/all_*.txt` or `devstats-helm/all_*.txt` or `./devstats-helm/projects.yaml` (lists of projects to process).
- Update `images/Dockerfile.full.prod` and `images/Dockerfile.full.test` files.
- Update `images/Dockerfile.minimal.prod` and `images/Dockerfile.minimal.test` files.
- Eventually all at once via `vim ./images/build_images.sh devstats-helm/all_*.txt images/Dockerfile.full.???? images/Dockerfile.minimal.????`.


2. Go to `cncf/devstats`:

- Do not commit changes until all is ready, or commit with `[no deploy]` in the commit message.
- Update `projects.yaml` file, also update `all:`.
- Copy setup scripts and then adjust them: `cp -R oldproject/ projectname/`, `vim projectname/*`. Most them can be shared for all projects in `./shared/`, usually only `psql.sh` is project specific.
- Update `devel/all_*.txt all/psql.sh grafana/dashboards/all/dashboards.json scripts/all/repo_groups.sql devel/get_icon_type.sh devel/get_icon_source.sh devel/add_single_metric.sh` files.
- Add new project repo REGEXP in `util_data/project_re.txt` and command lines in `util_data/project_cmdline.txt`. `all` means `All CNCF`, everything means `All CNCF` + non-standard test projects.
- Update `all` and `everything` REGEXPs. Run `` ONLY=`cat devel/all_prod_projects.txt` SKIP=all ./util_sh/all_cncf_re.sh > out `` to get `all` value for all CNCF projects.
- Then run `SKIP=all ./util_sh/all_cncf_re.sh > out` to get everything value, replace `all,` with `everything,` and save as `util_data/project_re.txt`.
- Update automatic deploy script: `./devel/deploy_all.sh`.
- Update static index pages `apache/www/index_*`.
- Update `partials/projects.html partials/projects_health.html metrics/all/sync_vars.yaml` (number of projects and partials).
- If normalized project name is not equal to lower project name, you need to update projects health metric to do the mapping, for example `series_name_map: { clouddevelopmentkitforkubernetes: cdk8s }`, see `metrics/*/*.yaml`.
- If upper name is for example `WasmEdge Runtime` then map from `wasmedgeruntime` - target mapping must be normalized DB name, so the entry will be: `wasmedgeruntime: wasmedge`.
- Name in `partials/projects_health.html` must be from normalized repo name, so for example in `shipwrightcncf` DB it must be `shipwright`: `metrics:series:phealthshipwright:loop:1:i:2`.
- Eventually check: `partials/projects_health.html`, `metrics/shared/projects_health.sql`, `metrics/all/health.yaml` files and `sprojects_health`, `sannotations_shared` tables in `allprj` DB.
- In reverse cases (where DB name cannot be the same as normalized project name` - then use `cncf` suffix for DB name, example: `shipwrightcncf` as DB name while full name is `Shipwright`. No mapping is needed then.
- Check `metrics/shared/projects_health.sql` for `suffix_projects`, `strip_projects`, `skip_projects`.
- Copy `metrics/oldproject` to `metrics/projectname`. Update `./metrics/projectname/vars.yaml` file.
- `cp -Rv scripts/oldproject/ scripts/projectname`, `vim scripts/projectname/*`. Usually it is only `repo_groups.sql` and in simple cases it can fallback to `scripts/shared/repo_groups.sql`, you can skip copy then.
- `cp -Rv grafana/oldproject/ grafana/projectname/` and then update files. Usually `%s/oldproject/newproject/g|w|next` and `%s/Old Project/New Project/g|w|next`.
- Try to source from Grafana with most similar project start data: `cp -Rv grafana/dashboards/oldproject/ grafana/dashboards/projectname/` and then update files.  Use `devel/mass_replace.sh` script, it contains some examples in the comments.
- Something like this: `` MODE=ss0 FROM='"oldproject"' TO='"newproject"' FILES=`find ./grafana/dashboards/newproject -type f -iname '*.json'` ./devel/mass_replace.sh ``.
- Update `grafana/dashboards/proj/dashboards.json` for all already existing projects, add new project using `devel/mass_replace.sh` or `devel/replace.sh`.
- For example: `./devel/dashboards_replace_from_to.sh dashboards.json` with `FROM` file containing old links and `TO` file containing new links.
- When adding new dashboard to all projects, you can add to single project (for example "cncf") and then populate to all others via something like:
- `` for f in `cat ../devstats-docker-images/k8s/all_test_projects.txt`; do cp grafana/dashboards/oldproject/new-contributors-table.json grafana/dashboards/$f/; done ``, then: `FROM_PROJ=oldproject ./util_sh/replace_proj_name_tag.sh new-contributors-table.json`.
- When adding new dashboard to projects that use dashboards folders (like Kubernetes) update `cncf/devstats:grafana/proj/custom_sqlite.sql` file.
- To actually deploy on bare metal follow `cncf/devstats:ADDING_NEW_PROJECT.md`.
- If not deploying, then generate grafana artwork `[TEST_SERVER=1|PROD_SERVER=1]`: `./devel/update_artwork.sh`, then `./grafana/create_images.sh` or `./devel/icons_all.sh`.


3. Go to `cncf/devstats-docker-images`:

- Consider upgrading Grafana: `vim ./images/Dockerfile.grafana`.
- Run `DOCKER_USER=... [SKIP_TESTS=1] SKIP_PATRONI=1 ./images/build_images.sh` to build a new images.
- Eventually run `DOCKER_USER=... ./images/remove_images.sh` to remove image(s) locally (new image is pushed to the Docker Hub).


4. Go to `cncf/devstats-helm`:

- Update `prod/README.md` specify new ranges for prod-only and test-only projects (at the bottom of the file).
- Update `devstats-helm/values.yaml` (add project).
- Now: N - index of the new project added to `github.com/cncf/devstats-helm/devstats-helm/values.yaml`. M=N+1. Inside `github.com/cncf/devstats-helm`:
- Consider `forceAddAll=1|tsdb|''` and `skipAddAll=1|''` flags when adding multiple projects, or any project which is disabled or not included in 'All ...'
- Use `forceAddAll=tsdb` to regenerate 'All CNCF' time series data.
- Follow `Update shared Grafana data` from `cncf/devstats:README.md`.

While on the `devstats-test` namespace, `git pull` and then for example if N=55 (index of the new project):

- `git pull`.
- Make sure you use test images, not prod, add `affiliationsImage='lukaszgryglicki/devstats-test',provisionImage='lukaszgryglicki/devstats-test',syncImage='lukaszgryglicki/devstats-minimal-test'`.
- Install new project (excluding static pages and ingress): `helm install devstats-test-projname ./devstats-helm --set skipSecrets=1,indexPVsFrom=55,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=55,indexCronsFrom=55,indexGrafanasFrom=55,indexServicesFrom=55,indexAffiliationsFrom=55,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,projectsOverride='+cncf\,+opencontainers\,+zephyr\,+linux\,+rkt\,+sam\,+azf\,+riff\,+fn\,+openwhisk\,+openfaas\,+cii\,+prestodb\,+godotengine\,+opentracing',skipECFRGReset=1,nCPUs=32,forceAddAll=tsdb`.
- Observe progress: `clear && k logs -f -l type=provision --max-log-requests=N-prj --tail=100`
- Update (optional) `devstats-helm/values.yaml` cronjob schedules using `devstatscode:splitcrons.sh` script: `[MONTHLY=1] [ONLY_ENV=1] [PATCH_ENV='AffSkipTemp,MaxHist,SkipAffsLock,AffsLockDB,NoDurable,DurablePQ,MaxRunDuration,SkipGHAPI,SkipGetRepos'] ./splitcrons devstats-helm/values.yaml new-values.yaml`, typical: `MONTHLY=1 ./splitcrons devstats-helm/values.yaml new-values.yaml; vim devstats-helm/values.yaml new-values.yaml; git add .; git commit -asm "New cron schedules"; git push`.
- Suspend all cronjobs (optional): `[MONTHLY=1] ONLY_SUSPEND=1 SUSPEND_ALL=1 ./splitcrons devstats-helm/values.yaml new-values.yaml`
- Unsuspend all cronjobs (optional - use when all finished): `[MONTHLY=1] ONLY_SUSPEND=1 ./splitcrons devstats-helm/values.yaml new-values.yaml`
- Install only crons (optional): `helm install devstats-test-projname-crons ./devstats-helm --set skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,projectsOverride='+cncf\,+opencontainers\,+zephyr\,+linux\,+rkt\,+sam\,+azf\,+riff\,+fn\,+openwhisk\,+openfaas\,+cii\,+prestodb\,+godotengine\,+opentracing',indexAffiliationsFrom=133,indexCronsFrom=133,indexPVsFrom=133`.
- Or use manual debugging pod to do installation: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=97,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,projectsOverride='+cncf\,+opencontainers\,+zephyr\,+linux\,+rkt\,+sam\,+azf\,+riff\,+fn\,+openwhisk\,+openfaas\,+cii\,+prestodb\,+godotengine\,+opentracing',provisionCommand=sleep,provisionCommandArgs={360000s},skipAddAll=1,useFlagsProv='',skipECFRGReset=1`, call `WAITBOOT=1 ./devstats-helm/deploy_all.sh` inside.
- Recreate static pages handler: `helm delete devstats-test-statics`, `helm install devstats-test-statics ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipAPI=1,skipNamespaces=1,indexStaticsFrom=0,indexStaticsTo=1`.
- Recreate ingress with a new hostname: `helm delete devstats-test-ingress`, `helm install devstats-test-ingress ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexDomainsFrom=0,indexDomainsTo=1,ingressClass=nginx-test,sslEnv=test`.
- If you want to merge multiple new projects (added with `skipAddAll=1`) into `All CNCF` create manual bootstrap debug pod: `helm install devstats-test-debug ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipPostgres=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s}`. Then shell into it: `../devstats-k8s-lf/util/pod_shell.sh debug`, run: `GHA2DB_INPUT_DBS="proj1,proj2,..." GHA2DB_OUTPUT_DB="allprj" merge_dbs && PG_DB="allprj" ./devel/remove_db_dups.sh && exit`. Delete pod: `helm delete devstats-test-debug`.
- Redeploy All CNCF Grafana (new project in health dashboards): `kubectl edit deployment devstats-grafana-all` - change `image:` add or remove `:latest` which will force rolling update without downtime.
- Run vars regenerate on all projects (excluding new one, this is needed to update home dashboard's list of all projects): `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/vars.sh',useFlagsProv='',indexProvisionsTo=55,provisionPodName=devstats-provision-vars`.
- Update All CNCF repo groups definitions: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexProvisionsFrom=38,indexProvisionsTo=39,provisionCommand='./devstats-helm/repo_groups.sh',useRepos=1,skipECFRGReset=1`.
- Eventually update All CNCF tags definitions (will break dashboards for a while): `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexProvisionsFrom=38,indexProvisionsTo=39,provisionCommand='./devstats-helm/tags.sh'`.
- Eventually reinit All CNCF (can skip GH API via adding `ghaAPISkip=1`): `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexProvisionsFrom=38,indexProvisionsTo=39,provisionCommand='./devstats-helm/reinit.sh',ghaAPISkip=1,giantProv=''`.
- In case of provisioning failure you can recreate failed provisioning pod via: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=134,indexProvisionsTo=135,skipCrons=1,skipGrafanas=1,skipServices=1,skipAffiliations=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,projectsOverride='+cncf\,+opencontainers\,+zephyr\,+linux\,+rkt\,+sam\,+azf\,+riff\,+fn\,+openwhisk\,+openfaas\,+cii\,+prestodb\,+godotengine\,+opentracing',skipECFRGReset=1,nCPUs=16,skipAddAll=1,provisionCommand=sleep,provisionCommandArgs={360000s},provisionPodName=fix` and then inside the `k exec -it fix-projname -- bash`, `vi proj-name/psql.sh`, finally run `WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./proj-name/psql.sh`.
- Then: `WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./devel/ro_user_grants.sh "metallb"`, `WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./devel/psql_user_grants.sh "devstats_team" "metallb"`, finally: `WAITBOOT=1 ./devstats-helm/deploy_all.sh`.

Create backups on test to restore on prod:

- Create debugging bootstrap pod with backups storage mounted: `helm install devstats-test-debug ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,skipPostgres=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1`.
- Shell into that pod: `../devstats-k8s-lf/util/pod_shell.sh debug`.
- Backup new project(s): `NOBACKUP='' NOAGE=1 GIANT=wait ONLY='backstage tremor porter openyurt openservicemesh' ./devstats-helm/backups.sh`.
- Exit the pod and delete Helm deployment: `helm delete devstats-test-debug`.
- For prod it would be: `helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1`.

While on the `devstats-prod` namespace, `git pull` and then for example if N=55 (index of the new project):

- `git pull`.
- Install new project (excluding static pages and ingress): `helm install devstats-prod-projname ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,indexPVsFrom=55,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=55,indexCronsFrom=55,indexGrafanasFrom=55,indexServicesFrom=55,indexAffiliationsFrom=55,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=32,forceAddAll=tsdb`.
- Real world example: `helm install devstats-prod-8-new-sandbox-projs-20240712 ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,indexPVsFrom=218,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=218,indexCronsFrom=218,indexGrafanasFrom=218,indexServicesFrom=218,indexAffiliationsFrom=218,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=3,skipAddAll=1`.
- Install only crons (optional): `helm install devstats-prod-projname ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',indexAffiliationsFrom=133,indexCronsFrom=133,indexPVsFrom=133`.
- Suspend all cronjobs (optional): `[MONTHLY=1] ONLY_PROD=1 ONLY_SUSPEND=1 SUSPEND_ALL=1 ./splitcrons devstats-helm/values.yaml new-values.yaml`
- Unsuspend all cronjobs (optional - use when all finished): `[MONTHLY=1] ONLY_PROD=1 ONLY_SUSPEND=1 ./splitcrons devstats-helm/values.yaml new-values.yaml`
- Typical: `` MONTHLY=1 ONLY_PROD=1 ./splitcrons devstats-helm/values.yaml new-values.yaml; vim devstats-helm/values.yaml new-values.yaml; git add .; git commit -asm "New cron schedules"; git push ``.
- You can also deploy prod project(s) using test backup: `helm install devstats-prod-10-projs ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,indexPVsFrom=75,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=75,indexCronsFrom=75,indexGrafanasFrom=75,indexServicesFrom=75,indexAffiliationsFrom=75,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',nCPUs=4,forceAddAll='',provisionCommand='devstats-helm/restore.sh',restoreFrom='https://teststats.cncf.io/backups/'`.
- Example single project from a backup: `helm install devstats-prod-piraeus ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexPVsFrom=106,indexProvisionsFrom=106,indexCronsFrom=106,indexGrafanasFrom=106,indexServicesFrom=106,indexAffiliationsFrom=106,indexPVsTo=107,indexProvisionsTo=107,indexCronsTo=107,indexGrafanasTo=107,indexServicesTo=107,indexAffiliationsTo=107,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',nCPUs=8,skipAddAll=1,provisionCommand='devstats-helm/restore.sh',restoreFrom='https://teststats.cncf.io/backups/'`.
- If you deployed only crons and want to get project from a backup: `helm install devstats-prod-projname-restore ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexProvisionsFrom=52,indexGrafanasFrom=52,indexServicesFrom=52,indexProvisionsTo=53,indexGrafanasTo=53,indexServicesTo=53,testServer='',prodServer='1',nCPUs=8,forceAddAll='',provisionCommand='devstats-helm/restore.sh',restoreFrom='https://teststats.cncf.io/backups/'`.
- If you want to merge multiple new projects (added with `skipAddAll=1`) into `All CNCF` create manual bootstrap debug pod: `helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s}`. Then shell into it: `../devstats-k8s-lf/util/pod_shell.sh debug`, run: `GHA2DB_INPUT_DBS="proj1,proj2,..." GHA2DB_OUTPUT_DB="allprj" merge_dbs && PG_DB="allprj" ./devel/remove_db_dups.sh && exit`. Delete pod: `helm delete devstats-prod-debug`.
- After merging update repo groups definition via: `` k exec -itn devstats-prod devstats-postgres-0 -- psql allprj < ~/cncf/devstats/scripts/all/repo_groups.sql ``.
- If you deployed from the backup, you need to merge it into 'All CNCF' and update its TSDB: `helm install devstats-prod-projname ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=96,skipCrons=1,skipGrafanas=1,skipServices=1,skipAffiliations=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=32,forceAddAll=tsdb`.
- Recreate static pages handler: `helm delete devstats-prod-statics`, `helm install devstats-prod-statics ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipAPI=1,skipNamespaces=1,indexStaticsFrom=1`.
- Recreate ingress with a new hostname: `helm delete devstats-prod-ingress`, `helm install devstats-prod-ingress ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexDomainsFrom=1,skipAliases=1,ingressClass=nginx-prod,sslEnv=prod`.
- Redeploy All CNCF Grafana (new project in health dashboards): `kubectl edit deployment devstats-grafana-all` - change `image:` add or remove `:latest` which will force rolling update without downtime.
- Run vars regenerate on all projects (excluding new one, this is needed to update home dahsboard's list of all projects): `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/vars.sh',useFlagsProv='',indexProvisionsTo=55,provisionPodName=devstats-provision-vars`.
- If you used a DB backup from a `test` you also need to rerun vars on restored DB (it has test-specific varaibles set not the prod ones): `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/vars.sh',useFlagsProv='',indexProvisionsFrom=96,provisionPodName=xyz`.
- Update All CNCF repo groups definitions (not needed if planning to run reinit for All CNCF - which is typical): `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionImage='lukaszgryglicki/devstats-prod',indexProvisionsFrom=38,indexProvisionsTo=39,provisionCommand='./devstats-helm/repo_groups.sh',useRepos=1,skipECFRGReset=1`.
- Eventually update All CNCF tags definitions (will break dashboards for a while, not needed if running reinit): `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionImage='lukaszgryglicki/devstats-prod',indexProvisionsFrom=38,indexProvisionsTo=39,provisionCommand='./devstats-helm/tags.sh'`.
- Eventually reinit All CNCF (recommended): `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionImage='lukaszgryglicki/devstats-prod',indexProvisionsFrom=38,indexProvisionsTo=39,provisionCommand='./devstats-helm/reinit.sh',ghaAPISkip=1,giantProv='',skipRand=1,nCPUs=6`.
- In case of provisioning failure you can recreate failed provisioning pod via: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',provisionImage='lukaszgryglicki/devstats-prod',testServer='',prodServer='1',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipAffiliations=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,projectsOverride='+cncf\,+opencontainers\,+zephyr\,+linux\,+rkt\,+sam\,+azf\,+riff\,+fn\,+openwhisk\,+openfaas\,+cii\,+prestodb\,+godotengine\,+opentracing',skipECFRGReset=1,skipAddAll=1,provisionCommand=sleep,provisionCommandArgs={360000s},provisionPodName=fix,indexProvisionsFrom=P,indexProvisionsTo=P+1,nCPUs=8` and then inside the `k exec -it fix-projname -- bash`, `vi proj-name/psql.sh`, finally run `WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./proj-name/psql.sh`.
- Then: `WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./devel/ro_user_grants.sh "metallb"`, `WAITBOOT=1 ORGNAME="-" PORT="-" ICON="-" GRAFSUFF="-" GA="-" SKIPGRAFANA=1 PDB=1 TSDB=1 GHA2DB_MGETC=y ./devel/psql_user_grants.sh "devstats_team" "metallb"`, finally: `WAITBOOT=1 ./devstats-helm/deploy_all.sh`.
- If you suspended crons while adding new projects & regenerating all then you need to update last parsed date on `allproj` database. Do: `k exec -it -n devstats-prod devstats-postgres-N -- psql allprj` (N - is the paroni `master` number, others are `replicas`), exacute: `delete from gha_parsed where dt > '2022-12-14 10:00:00'; delete from sevents_h where time > '2022-12-14 10:00:00';`.
- To speedup/slowdown any subcommand processing, you can ssh into pod and create `env.env` file with `GHA2DB_NCPUS=8`.

Both test & prod namespaces:

- To have all dashboards recreated you can also kill all Grafana pods via `[ITER=1] ../devstats-k8s-lf/util/delete_objects.sh po devstats-grafana-`, deployments will recreate them with the newest projects lists.
- To recreate them in background and then track progress: `rm ~/recreate.log && ITER=1 ./delete_objects.sh po devstats-grafana- &>> ~/recreate.log &` and then `clear && tail -f ~/recreate.log`.
- Delete intermediate helm installs - those with auto generated name like `devstats-helm-1565240123`: `helm delete devstats-helm-1565240123`.

Regenerate projects health on "summary" projects (follow `cncf/devstats-docker-images`:`devstats-helm/health.sh` instructions):

- If normalized project name is not equal to lower project name, you need to update projects health metric to do the mapping, for example `series_name_map: { clouddevelopmentkitforkubernetes: cdk8s }`, see `metrics/*/*.yaml`.
- You can check this via: `k exec -it devstats-postgres-1 -- psql allprj`, then `select distinct series from sprojects_health where series like '%proj%'`.

Test:

- Generate annotations on the test server: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/annotations.sh',useFlagsProv='',provisionPodName=devstats-provision-anno`
- Run health dashboards regenerate on All CNCF project: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=38,indexProvisionsTo=39,provisionPodName=devstats-provision-health`.
- Run health dashboards regenerate on All GraphQL project: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=48,indexProvisionsTo=49`.
- Run health dashboards regenerate on All CDF project: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=43,indexProvisionsTo=44`.

Prod:

- Generate annotations on the prod server: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/annotations.sh',useFlagsProv='',provisionPodName=devstats-provision-anno`.
- Run health dashboards regenerate on All CNCF project: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=38,indexProvisionsTo=39,provisionPodName=devstats-provision-health`.
- Run health dashboards regenerate on GraphQL project: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=48,indexProvisionsTo=49`.
- Run health dashboards regenerate on All CDF project: `helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/health.sh',indexProvisionsFrom=43,indexProvisionsTo=44`.

If you used `nCPUs=n` flag during adding a new project, update deployed components not to use that flag anymore (especially cronjobs). `k edit cj`, then search for: `GHA2DB_NCPUS\n                value:`.

To generate affiliations task for the next project(s):

- On the `prod` node run: `helm install devstats-prod-reports ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,reportsPod=1,namespace='devstats-prod'`.
- On the `test` node run: `helm install devstats-test-reports ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,reportsPod=1,projectsOverride='+cncf\,+opencontainers\,+zephyr\,+linux\,+rkt\,+sam\,+azf\,+riff\,+fn\,+openwhisk\,+openfaas\,+cii\,+prestodb\,+godotengine\,+opentracing'`.
- Shell into reporting pod: `../devstats-k8s-lf/util/pod_shell.sh devstats-reports` or `k exec -itn devstats-prod devstats-reports -- bash` from a different namespace (like `devstats-test`).
- Generate data: `TASKS='unknown_contributors' ONLY='proj1 proj2 ... projN' ./affs/all_tasks.sh`.
- Delete reporting pod: `helm delete devstats-prod-reports`.
- Go to `cncf/gitdm:src`: `wget https://devstats.cncf.io/backups/keylime_unknown_contributors.csv`
- Check for forbidden SHAs: `./check_shas keylime_unknown_contributors.csv`.
- Generate a task file: `PG_PASS=... ./unknown_committers.rb keylime_unknown_contributors.csv; mv task.csv keylime_task.csv`.
- Merge multiple tasks: `./csv_merge.rb commits task.csv *_task.csv`
- Upload `task.csv` to a Google Sheet.


To import new affiliations do the following:

- Eventually: `` k exec -itn devstats-prod devstats-postgres-2 -- psql devstats -c "delete from gha_computed where metric = 'affs_lock'" ``.
- Eventually: `` k exec -itn devstats-prod devstats-postgres-2 -- psql projname -c "delete from gha_computed where metric = 'affs_lock_projname'" ``.
- Eventually: `` k exec -itn devstats-prod devstats-postgres-2 -- psql projname -c " delete from gha_imported_shas where sha = '<sha>'" ``.
- `k edit cj devstats-affiliations-projname`.
- Add/Control JSON import probability and then reinit affiliations related TSDB data probability:
```
              - name: SKIP_IMP_AFFS
                value: "0"    # or "100" if already imported
              - name: SKIP_UPD_AFFS
                value: "0"
```
- Change `schedule:` to something like current minute = N: `N+1 * * * *`, store previous value to be restored later.
- `k get po -w | grep devstats-affiliations-projectname` and then once started: `k logs -f devstats-affiliations-projname-xxx-yyy`.
- Once process is running `k edit cj devstats-affiliations-projname` - restore previous values.
- Or use manual pod via helm temporary install: `` helm install --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/affs.sh',skipImpAffs=0,skipUpdAffs=0,checkImportedSHA=0,getAffsFiles=0,nCPUs=8,indexProvisionsFrom=N,indexProvisionsTo=N+1 ``.


5. Go to `cncf/devstats-helm-lf` (optional):

- Update `devstats-helm/values.yaml` (add project).
- Now: N - index of the new project added to `github.com/cncf/devstats-helm-lf/devstats-helm/values.yaml`. M=N+1. Inside `github.com/cncf/devstats-helm`:
- If N=63, then: `AWS_PROFILE=... KUBECONFIG=... helm2 install ./devstats-helm --set skipSecrets=1,indexPVsFrom=63,skipBootstrap=1,indexProvisionsFrom=63,indexCronsFrom=63,skipGrafanas=1,skipServices=1,skipNamespace=1 --name devstats-projname`.


6. Go to `cncf/devstats-helm-example` (optional):

- Update `README.md` - add new project.
- Update `github.com/cncf/devstats-helm-example/devstats-helm-example/values.yaml` (add project).
- Now: N - index of the new project added to `github.com/cncf/devstats-helm-example/devstats-helm-example/values.yaml`. M=N+1. Inside `github.com/cncf/devstats-helm-example`:
- Run `helm install ./devstats-helm-example --set skipSecrets=1,skipBootstrap=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,indexProvisionsFrom=N,indexProvisionsTo=M,indexPVsFrom=N,indexPVsTo=M` to create provisioning pods.
- Run `helm install ./devstats-helm-example --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,indexCronsFrom=N,indexCronsTo=M` to create cronjobs (they will wait for provisioning to finish).
- Run `helm install ./devstats-helm-example --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipPostgres=1,skipIngress=1,indexGrafanasFrom=N,indexGrafanasTo=M,indexServicesFrom=N,indexServicesTo=M` to create grafana deployments and services. Grafanas will be usable when full provisioning is completed.
- You can do 3 last steps in one step instead: `helm install ./devstats-helm-example --set skipSecrets=1,skipBootstrap=1,skipPostgres=1,skipIngress=1,indexProvisionsFrom=N,indexProvisionsTo=M,indexCronsFrom=N,indexCronsTo=M,indexGrafanasFrom=N,indexGrafanasTo=M,indexServicesFrom=N,indexServicesTo=M,indexPVsFrom=N,indexPVsTo=M`.
- Recreate ingress with a new hostname: `kubectl delete ingress devstats-ingress`, `helm install ./devstats-helm-example --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1`.
- Eventually do something very similar for `cncf/devstats-helm-graphql` or `cncf/devstats-helm-lf`.


7. Go to `lukaszgryglicki/contributors` (optional):

- Update `contrib_projects.yaml`.
- Eventually update `scripts/contrib/repo_groups.sql`.


8. Go to `cncf/velocity`:

- Update `reports/cncf_projects_config.csv`.
- Update `BigQuery/velocity_lf.sql BigQuery/velocity_cncf.sql`.
- Update `map/hints.csv map/defmaps.csv map/urls.csv map/ranges_sane.csv`.
- All at once: `vim reports/cncf_projects_config.csv BigQuery/velocity_lf.sql BigQuery/velocity_cncf.sql map/hints.csv map/defmaps.csv map/urls.csv map/ranges_sane.csv`.
- When running CNCF/LF/Top30 reports use `FORK_FILE` mode to support skipping forks.


9. You should visit all dashboards and adjust date ranges and for some dashboards automatically selected values.


10. Update affiliations.

- Update `cncf/gitdm` affiliations with [official project maintainers](http://maintainers.cncf.io/).


## Troubleshooting

If you get:
```
Error: Internal error occurred: failed calling webhook "admission-webhook.openebs.io": Post "https://admission-server-svc.openebs.svc:443/validate?timeout=5s": x509: certificate has expired or is not yet valid: current time 2022-01-13T07:57:42Z is after 2021-12-15T12:55:03Z
```
while attempting to create a PVC, then:

- `kubectl delete validatingwebhookconfigurations openebs-validation-webhook-cfg`.
- Eventually (but I found it not needed): `kubectl -n openebs get pods -o name | grep admission-server | xargs kubectl -n`.
- Eventually also secrets (not needed): `k get secret -n openebs admission-server-secret`.

# To tweak Helm release:

- Decode V3 Helm release: `k get secret -n devstats-prod sh.helm.release.v1.devstats-helm-1646314187.v1 -o json | jq -r ".data.release" | base64 -d | base64 -d | gzip -d | jq -rS '.' > release.json`


# Kubernetes certs expired

- Do on `master` node: `kubeadm certs check-expiration`.
- Make a copy of `/etc/kubernetes` and `~/.kube`, `~/.kube/config.20221215` (cert expires then).
- Do `kubeadm certs renew all`, reboot master & all nodes.
- After restart: `vim /etc/kubernetes/admin.conf config` - copy `certificate-authority-data`, `client-certificate-data` and `client-key-data` from `admin.conf` to your `~/.kube/config` (1st file is not changed actually, so last two).
- On each node: `cp ~/.kube/config ~/.kube/config.202X1215 && vim ~/.kube/config`.
- Reference [here](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-certs/).


# Adding multiple projects checklist

- Add each, update cronjobs, report on cncf/toc, static & ingress, vars, merge each, update grafanas dashboards, fetch them, update shared grafana data, recreate all grafanas, generate affiliations task, update login contributions, reinit all CNCF, projects health(s) reports.


# To update running pod's container environment

- Do: `k describe po -n devstats-prod pod-name` - to get which node it runs on.
- On that node: `ps -axu | grep command-name` - to find pod's containers' PID.
- Have the same version of binary compiled with debugging symbols, for example: `go build -o gha2db.g cmd/gha2db/gha2db.go`.
- Attach to it via gdb: `gdb -p pid gha2db.g`.
- Set the env variable: `call (int) setenv("GHA2DB_NCPUS", "6", 1)`.
- Detach & exit: `detach`, `quit`.
