#!/bin/bash
if [ -z "$1" ]
then
  echo "please provide release name as a 1st arg"
  exit 1
fi
if [ -z "$2" ]
then
  echo "please provide index from as a 2nd arg"
  exit 2
fi
if [ -z "$3" ]
then
  echo "please provide index to as a 3rd arg"
  exit 3
fi
helm install "$1" ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=$2,indexProvisionsTo=$3,indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3,indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=51,indexAffiliationsTo=100,^CipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=2,skipAddAll=1,allowMetricFail=1
