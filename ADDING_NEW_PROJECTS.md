# Adding new projects

1. Go to `cncf/devstats-docker-images`:
- Add project entry to `example/projects.yaml` file. Find projects orgs, repos, select start date, eventually add test coverage for complex regular expression in `cncf/devstatscode`:`regexp_test.go`.
- To identify repo and/or org name changes, date ranges for entrire projest use `cncf/devstats`:`util_sh/(repo|org)_name_changes_bigquery.sh org|org/repo`.
- You may need to update `cncf/devstats`:`util_sql/(org_repo)_name_changes_bigquery.sql` to include newest months.
- For other Helm deployments (like LF or GraphQL) update `k8s/projects.yaml` or `gql/projects.yaml` or `devstats-helm/projects.yaml` file instead of `example/projects.yaml`.
- Update `./images/build_images.sh` (add project's directory).
- Update `./k8s/all_*.txt` or `./example/all_*.txt` or `./gql/all_*.txt` or `./devstats-helm/projects.yaml` (lists of projects to process).
- Update `images/Dockerfile.full.prod` and `images/Dockerfile.full.test` files.


2. Go to `cncf/devstats`:

- Do not commit changes until all is ready, or commit with `[no deploy]` in the commit message.
- Copy setup scripts and then adjust them: `cp -R oldproject/ projectname/`, `vim projectname/*`. Most them can be shared for all projects in `./shared/`, usually only `psql.sh` is project specific.
- Copy `metrics/oldproject` to `metrics/projectname`. Update `./metrics/projectname/vars.yaml` file.
- `cp -Rv scripts/oldproject/ scripts/projectname`, `vim scripts/projectname/*`. Usually it is only `repo_groups.sql` and in simple cases it can fallback to `scripts/shared/repo_groups.sql`, you can skip copy then.
- `cp -Rv grafana/oldproject/ grafana/projectname/` and then update files. Usually `%s/oldproject/newproject/g|w|next` and `%s/Old Project/New Project/g|w|next`.
- `cp -Rv grafana/dashboards/oldproject/ grafana/dashboards/projectname/` and then update files.  Use `devel/mass_replace.sh` script, it contains some examples in the comments.
- Something like this: `` MODE=ss0 FROM='"oldproject"' TO='"newproject"' FILES=`find ./grafana/dashboards/newproject -type f -iname '*.json'` ./devel/mass_replace.sh ``.
- When adding new dashboard to all projects, you can add to single project (for example "cncf") and then populate to all others via something like:
- `` for f in `cat ../devstats-docker-images/k8s/all_test_projects.txt`; do cp grafana/dashboards/oldproject/new-contributors-table.json grafana/dashboards/$f/; done ``, then: `FROM_PROJ=oldproject ./util_sh/replace_proj_name_tag.sh new-contributors-table.json`.
- When adding new dashboard to projects that use dashboards folders (like Kubernetes) update `cncf/devstats:grafana/proj/custom_sqlite.sql` file.


3. Go to `cncf/devstats-docker-images`:

- Run `DOCKER_USER=... ./images/build_images.sh` to build a new image.
- Eventually run `DOCKER_USER=... ./images/remove_images.sh` to remove image locally (new image is pushed to the Docker hub).


4. Go to `cncf/devstats-helm-example`:

- Update `README.md` - add new project.
- Update `github.com/cncf/devstats-helm-example/devstats-helm-example/values.yaml` (add project).
- Now: N - index of the new project added to `github.com/cncf/devstats-helm-example/devstats-helm-example/values.yaml`. M=N+1. Inside `github.com/cncf/devstats-helm-example`:
- Run `helm install ./devstats-helm-example --set skipSecrets=1,skipBootstrap=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,indexProvisionsFrom=N,indexProvisionsTo=M,indexPVsFrom=N,indexPVsTo=M` to create provisioning pods.
- Run `helm install ./devstats-helm-example --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,indexCronsFrom=N,indexCronsTo=M` to create cronjobs (they will wait for provisioning to finish).
- Run `helm install ./devstats-helm-example --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipPostgres=1,skipIngress=1,indexGrafanasFrom=N,indexGrafanasTo=M,indexServicesFrom=N,indexServicesTo=M` to create grafana deployments and services. Grafanas will be usable when full provisioning is completed.
- You can do 3 last steps in one step instead: `helm install ./devstats-helm-example --set skipSecrets=1,skipBootstrap=1,skipPostgres=1,skipIngress=1,indexProvisionsFrom=N,indexProvisionsTo=M,indexCronsFrom=N,indexCronsTo=M,indexGrafanasFrom=N,indexGrafanasTo=M,indexServicesFrom=N,indexServicesTo=M,indexPVsFrom=N,indexPVsTo=M`.
- Recreate ingress with a new hostname: `kubectl delete ingress devstats-ingress`, `helm install ./devstats-helm-example --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1`.
- Eventually do something very similar for `cncf/devstats-helm-graphql` or `cncf/devstats-helm-lf`.

