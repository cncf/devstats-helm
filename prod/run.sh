#!/bin/bash
./switch_context.sh prod || exit 1
./current_context.sh || exit 1
cat devstats-helm/secrets/*.secret || exit 1
helm install --dry-run --debug --generate-name ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1 || exit 1
helm install devstats-prod-secrets ./devstats-helm --set skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1 || exit 1
helm install devstats-prod-pvcs ./devstats-helm --set skipSecrets=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1 || exit 1
helm install devstats-prod-patroni ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1 || exit 1
helm install devstats-prod-statics ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,indexStaticsFrom=1 || exit 1
helm install devstats-prod-ingress ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,indexDomainsFrom=1,ingressClass=nginx-prod,sslEnv=prod || exit 1
helm install devstats-prod-bootstrap ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1 || exit 1
helm install devstats-prod-crons ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,indexCronsFrom=44,indexCronsTo=49 || exit 1
helm install devstats-prod-grafanas ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipPostgres=1,skipIngress=1,skipStatic=1,indexGrafanasFrom=44,indexGrafanasTo=49,indexServicesFrom=44,indexServicesTo=49 || exit 1
helm install devstats-prod-backups ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1 || exit 1
helm install devstats-prod-backups ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,backupsCron='0 3 * * *',backupsTestServer='',backupsProdServer='1' || exit 1
helm list || exit 1
