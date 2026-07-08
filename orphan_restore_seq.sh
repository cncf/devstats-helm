#!/bin/bash
# Usage: [NS=devstats-prod] [RANGE='9 months'] [FROM=0] [TO=<n>] [NCPUS=<n>] ./orphan_restore_seq.sh
exec 9< "$0"
if ! flock -n 9
then
  echo "another orphan_restore_seq.sh instance is already running, exiting"
  exit 1
fi
NS="${NS:-devstats-prod}"
RANGE="${RANGE:-9 months}"
FROM="${FROM:-0}"
if [ -z "$TO" ]
then
  TO=$(grep -c '^- proj: ' ./devstats-helm/values.yaml)
fi
extra=''
if [ ! -z "$NCPUS" ]
then
  extra=",nCPUs=$NCPUS"
fi
rel=''
trap 'echo; echo "interrupted, cleaning up"; [ -n "$rel" ] && helm -n "$NS" uninstall "$rel" > /dev/null 2>&1; exit 1' INT TERM
echo "orphan commits restore: projects [$FROM, $TO), range: $RANGE, namespace: $NS"
for ((i=FROM; i<TO; i++))
do
  read -r proj db < <(awk -v n=$((i+1)) '/^- proj: /{c++; if(c==n)p=$3} c==n && /^  db: /{print p, $2; exit}' ./devstats-helm/values.yaml)
  if [ -z "$db" ]
  then
    echo "index $i: cannot read project/db from ./devstats-helm/values.yaml, skipping"
    continue
  fi
  present=$(kubectl -n "$NS" exec devstats-postgres-0 -c devstats-postgres -- psql -tAc "select 1 from pg_database where datname = '$db'" 2>/dev/null)
  if [ "$present" != "1" ]
  then
    echo "index $i ($proj): database '$db' does not exist (archived project), skipping"
    continue
  fi
  rel="orphan-restore-$i"
  helm -n "$NS" uninstall "$rel" > /dev/null 2>&1
  helm -n "$NS" install "$rel" ./devstats-helm --set namespace="$NS",skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionPodName='orphan-restore',indexProvisionsFrom=$i,indexProvisionsTo=$((i+1)),provisionCommand='devstats-helm/repos.sh',ghapiOrphanCommitsRange="$RANGE",maxRunDuration='get_repos:72h:102'"$extra" > /dev/null || exit 2
  pod="orphan-restore-$proj"
  ok=''
  for ((j=0; j<24; j++))
  do
    kubectl -n "$NS" get po "$pod" > /dev/null 2>&1 && ok=1 && break
    sleep 5
  done
  if [ -z "$ok" ]
  then
    echo "index $i ($proj): pod $pod not created, skipping"
    helm -n "$NS" uninstall "$rel" > /dev/null 2>&1 || echo "index $i ($proj): helm uninstall $rel failed (ignored)"
    rel=''
    continue
  fi
  echo "index $i ($proj): waiting for $pod"
  phase=''
  for ((j=0; j<25920; j++))
  do
    phase=$(kubectl -n "$NS" get po "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]
    then
      break
    fi
    sleep 10
  done
  if [ "$phase" != "Succeeded" ]
  then
    echo "index $i ($proj): $pod phase '$phase' (did not succeed), check: kubectl -n $NS logs $pod"
  fi
  kubectl -n "$NS" logs "$pod" --tail=3 2>/dev/null | sed 's/^/  /'
  helm -n "$NS" uninstall "$rel" > /dev/null 2>&1 || echo "index $i ($proj): helm uninstall $rel failed (ignored)"
  rel=''
done
echo 'OK'
