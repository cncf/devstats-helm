#!/bin/bash
if [ -z "$1" ]
then
  echo "$0: please provide the project name as a 1st arg"
  exit 1
fi
if [ -z "$2" ]
then
  echo "$0: please provide index from as a 2nd arg"
  exit 2
fi
if [ -z "$3" ]
then
  echo "$0: please provide index to as a 3rd arg"
  exit 3
fi
echo helm install "devstats-prod-${1}" ./devstats-helm --set "namespace='devstats-prod',skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexPVsFrom=$2,indexPVsTo=$3,indexProvisionsFrom=$2,indexProvisionsTo=$3,indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3,indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=$2,indexAffiliationsTo=$3,provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/restore.sh',restoreFrom='https://devstats.cncf.io/backups/',testServer='',prodServer='1'"
helm install "devstats-prod-${1}" ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,indexPVsFrom=$2,indexPVsTo=$3,indexProvisionsFrom=$2,indexProvisionsTo=$3,indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3,indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=$2,indexAffiliationsTo=$3,provisionImage='lukaszgryglicki/devstats-prod',provisionCommand='devstats-helm/restore.sh',restoreFrom='https://devstats.cncf.io/backups/',testServer='',prodServer='1'
echo "clear; k logs -f devstats-provision-${1}"
