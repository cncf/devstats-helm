# How to add a new org or repo and backfill the data

- Add data from a new projects org that was added recently (Meshery example): `helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',provisionImage='lukaszgryglicki/devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=124,indexProvisionsTo=125,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,provisionCommand=sleep,provisionCommandArgs={360000s},nCPUs=16`.
- Figure out when to start backfilling data for the new org: `` ./util_sh/org_name_changes_bigquery.sh prometheus-community ``.
- Then shell into that pod: `../devstats-k8s-lf/util/pod_shell.sh devstats-provision-meshery`.
- Inside the pod run something like `GHA2DB_PROJECT=meshery PG_DB=meshery GHA2DB_LOCAL=1 gha2db 2021-07-01 0 today now meshery 1>log.1 2>log.2 &`.
- You can leave the pod, shell again and check progress via: `` tail -f ./log.? `` or grepping for events found: `` tail -f log.1 | grep -E 'events [1-9]' ``.
- When this finishes: `helm delete devstats-prod-debug` then you need to reinit meshery TSDB and merge meshery DB into allprj.

