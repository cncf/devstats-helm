# Prod namespace deployments

- First switch context to prod: `./switch_context.sh prod`.
- Second confirm that the current context is prod: `./current_context.sh`.
- Confirm that you have prod secrets defined and that they have no end-line: `cat devstats-helm/secrets/*.secret` - should return one big line of all secret values concatenated.
- Do noting: `helm install --dry-run --debug --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Deploy secrets: `helm install devstats-prod-secrets ./devstats-helm --set skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Deploy git storage PVs: `helm install devstats-prod-pvcs ./devstats-helm --set skipSecrets=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Deploy 4-node patroni HA database: `helm install devstats-prod-patroni ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1`.
- Deploy static page handlers (default and for prod, cdf and graphql domains): `helm install devstats-prod-statics ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,indexStaticsFrom=1`.
- Deploy prod domain ingress: `helm install devstats-prod-ingress ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,indexDomainsFrom=1,ingressClass=nginx-prod`.
- Deploy/bootstrap logs database: `helm install devstats-prod-bootstrap ./devstats-helm --set skipSecrets=1,skipPVs=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Do some manual provisioning work on GraphQL only deployment: `helm install prod-temp-work ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,indexProvisionsFrom=44,indexProvisionsTo=49,provisionCommand=sleep,provisionCommandArgs={360000s}`.
- Shell into manual work pods: `../devstats-k8s-lf/util/pod_shell.sh devstats-provision-expressgraphql`.
- Create hourly sync cron jobs (only for GraphQL): `helm install devstats-prod-crons ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,indexCronsFrom=44,indexCronsTo=49`.
- Create Grafana services for GraphQL projects: `helm install devstats-prod-grafanas ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipPostgres=1,skipIngress=1,skipStatic=1,indexGrafanasFrom=44,indexGrafanasTo=49,indexServicesFrom=44,indexServicesTo=49`.
- Shell into bootstraping pod: `helm install --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,ingressClass=nginx-prod,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={36000s}`.
- Shell into manual work pods: `../devstats-k8s-lf/util/pod_shell.sh debug`. Then: `kubectl delete po debug`
- You can run all those commands via: `./prod/run.sh`.
