# Prod namespace deployments

- First switch namespace to prod: `./switch_namespace.sh prod`.
- Second confirm that the current context is prod: `./current_context.sh`.
- Confirm that you have prod secrets defined and that they have no end-line: `cat devstats-helm/secrets/*.secret` - should return one big line of all secret values concatenated.
- Do noting: `helm install --dry-run --debug --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Deploy secrets: `helm install devstats-prod-secrets ./devstats-helm --set skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Deploy git storage PVs: `helm install devstats-test-pvcs ./devstats-helm --set skipSecrets=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Deploy 4-node patroni HA database: `helm install devstats-test-patroni ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1`.
- Deploy static page handlers (default and for test domain): `helm install devstats-test-statics ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,indexStaticsFrom=0,indexStaticsTo=1`.
- Deploy test domain ingress: `helm install devstats-test-ingress ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,indexDomainsFrom=0,indexDomainsTo=1`.
- Deploy/bootstrap logs database: `helm install devstats-test-bootstrap ./devstats-helm --set skipSecrets=1,skipPVs=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
