#!/bin/bash
./switch_context.sh prod || exit 1
./current_context.sh || exit 1
cat devstats-helm/secrets/*.secret || exit 1
helm install --dry-run --debug --generate-name ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1 || exit 1
helm install devstats-namespaces ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1
helm install devstats-prod-secrets ./devstats-helm --set namespace='devstats-prod',skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1 || exit 1
helm install devstats-prod-pvcs ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1 || exit 1
helm install devstats-prod-patroni ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipNamespaces=1 || exit 1
helm install devstats-prod-statics ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipNamespaces=1,indexStaticsFrom=1 || exit 1
helm install devstats-prod-ingress ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipStatic=1,skipNamespaces=1,indexDomainsFrom=1,ingressClass=nginx-prod,sslEnv=prod || exit 1
helm install devstats-prod-bootstrap ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1 || exit 1
helm install devstats-prod-crons ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1,syncImage='lukaszgryglicki/devstats-minimal-prod',indexCronsTo=49,indexAffiliationsTo=49 || exit 1
helm install devstats-prod-grafanas ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1,indexGrafanasTo=49,indexServicesTo=49 || exit 1
helm install devstats-prod-backups-pv ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1 || exit 1
helm install devstats-prod-backups ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1,backupsCron='45 2 * * *',backupsTestServer='',backupsProdServer='1' || exit 1
helm install devstats-prod-vacuum ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipBackups=1,skipBootstrap=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipNamespaces=1 || exit 1
helm list || exit 1
