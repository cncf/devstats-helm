# Test namespace deployments

- First switch namespace to test: `./swicth_namespace.sh test`.
- Second confirm that the current context is test: `./current_context.sh`.
- Confirm that you have test secreats defined and that they have no end-line: `cat devstats-helm/secrets/*.secret` - should return one big line of all secret values concatenated.
- Do noting: `helm install --dry-run --debug --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
- Deploy secrets: `helm install devstats-test ./devstats-helm --set skipPVs=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1`.
