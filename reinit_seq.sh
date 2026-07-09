#!/bin/bash
# Usage: [NS=devstats-prod] [FROM=<n>] [TO=<m>] [NCPUS=8] [MAXRUN='calc_metric:72h:102'] [TSDBDROP=1] [GHAAPISKIP=''] [SKIPGETREPOS=''] [SKIPECFRGRESET=''] [EXTRA=',key=val,...'] ./reinit_seq.sh
# Example: FROM=1 TO=38 NCPUS=6 nohup ./reinit_seq.sh 1>reinit.log 2>reinit.err < /dev/null &
# ${VAR-1}    # use 1 only if VAR is unset
# ${VAR:-1}   # use 1 if VAR is unset OR empty
exec 9< "$0"
if ! flock -n 9
then
  echo "another reinit_seq.sh instance is already running, exiting"
  exit 1
fi
NS="${NS:-devstats-prod}"
FROM="${FROM:-0}"
NCPUS="${NCPUS:-8}"
MAXRUN="${MAXRUN:-calc_metric:72h:102}"
TSDBDROP="${TSDBDROP:-}"
GHAAPISKIP="${GHAAPISKIP-1}"
SKIPGETREPOS="${SKIPGETREPOS-1}"
SKIPECFRGRESET="${SKIPECFRGRESET-1}"
if [ -z "$TO" ]
then
  TO=$(grep -c '^- proj: ' ./devstats-helm/values.yaml)
fi
rel=''
trap 'echo; echo "interrupted, cleaning up"; [ -n "$rel" ] && helm -n "$NS" uninstall "$rel" > /dev/null 2>&1; exit 1' INT TERM
echo "TSDB reinit: projects [$FROM, $TO), nCPUs: $NCPUS, maxRunDuration: $MAXRUN, tsdbDrop: '$TSDBDROP', namespace: $NS"
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
  rel="reinit-$i"
  helm -n "$NS" uninstall "$rel" > /dev/null 2>&1
  helm -n "$NS" install "$rel" ./devstats-helm --set namespace="$NS",skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionPodName='reinit',indexProvisionsFrom=$i,indexProvisionsTo=$((i+1)),provisionCommand='./devstats-helm/reinit.sh',allowMetricFail=1,nCPUs="$NCPUS",maxRunDuration="$MAXRUN",tsdbDrop="$TSDBDROP",ghaAPISkip="$GHAAPISKIP",giantProv='',skipECFRGReset="$SKIPECFRGRESET",skipGetRepos="$SKIPGETREPOS""$EXTRA" > /dev/null || exit 2
  pod="reinit-$proj"
  ok=''
  for ((j=0; j<24; j++))
  do
    kubectl -n "$NS" get po "$pod" > /dev/null 2>&1 && ok=1 && break
    sleep 5
  done
  if [ -z "$ok" ]
  then
    echo "index $i ($proj): pod $pod not created, aborting"
    kubectl -n "$NS" get pods | grep reinit || true
    helm -n "$NS" uninstall "$rel" > /dev/null 2>&1 || true
    exit 3
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
    echo "index $i ($proj): pod $pod phase '$phase' (did not succeed), aborting - last log lines:"
    kubectl -n "$NS" logs "$pod" --tail=100 2>/dev/null | sed 's/^/  /'
    kubectl -n "$NS" describe pod "$pod" 2>/dev/null | tail -80 | sed 's/^/  /'
    helm -n "$NS" uninstall "$rel" > /dev/null 2>&1 || true
    exit 3
  fi
  kubectl -n "$NS" logs "$pod" --tail=3 2>/dev/null | sed 's/^/  /'
  helm -n "$NS" uninstall "$rel" > /dev/null 2>&1 || echo "index $i ($proj): helm uninstall $rel failed (ignored)"
  rel=''
done
echo 'OK'
