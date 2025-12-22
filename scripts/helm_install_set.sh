#!/bin/bash
if [ -z "$1" ]
then
  echo "please provide release name as a 1st arg: devstats-prod-xyz"
  exit 1
fi
if [ -z "$2" ]
then
  echo "please provide index from as a 2nd arg: 0"
  exit 2
fi
if [ -z "$3" ]
then
  echo "please provide index to as a 3rd arg: 255"
  exit 3
fi
if [ -z "$4" ]
then
  echo "please provide number of CPUs as a 4th arg: 8"
  exit 4
fi
if [ -z "$5" ]
then
  echo "please provide memory limit in GiB as a 5th arg: 512"
  exit 5
fi
helm install "$1" ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,indexProvisionsFrom=$2,indexProvisionsTo=$3,indexCronsFrom=$2,indexCronsTo=$3,indexGrafanasFrom=$2,indexGrafanasTo=$3,indexServicesFrom=$2,indexServicesTo=$3,indexAffiliationsFrom=$2,indexAffiliationsTo=$3,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',skipECFRGReset=1,nCPUs=$4,skipAddAll=1,allowMetricFail=1,limitsProvisionsMemory="${5}Gi"
