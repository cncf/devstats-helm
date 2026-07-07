#!/bin/bash
# Sequential deep orphan-commits restore: one provision pod per project (git clones are on
# per-project PVCs), waits for each pod to finish before starting the next.
# Usage: [NS=devstats-prod] [RANGE='9 months'] [FROM=0] [TO=<n>] ./orphan_restore_seq.sh
NS="${NS:-devstats-prod}"
RANGE="${RANGE:-9 months}"
FROM="${FROM:-0}"
if [ -z "$TO" ]
then
  TO=$(grep -c 'proj:' ./devstats-helm/values.yaml)
fi
echo "orphan commits restore: projects [$FROM, $TO), range: $RANGE, namespace: $NS"
for ((i=FROM; i<TO; i++))
do
  rel="orphan-restore-$i"
  helm install "$rel" ./devstats-helm --set namespace="$NS",skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipBootstrap=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,testServer='',prodServer='1',provisionImage='lukaszgryglicki/devstats-prod',provisionPodName='orphan-restore',indexProvisionsFrom=$i,indexProvisionsTo=$((i+1)),provisionCommand='devstats-helm/repos.sh',ghapiOrphanCommitsRange="$RANGE",maxRunDuration='get_repos:72h:102' > /dev/null || exit 2
  pod=''
  for ((j=0; j<24; j++))
  do
    pod=$(kubectl -n "$NS" get po --no-headers 2>/dev/null | awk '/^orphan-restore-/{print $1; exit}')
    [ -n "$pod" ] && break
    sleep 5
  done
  if [ -z "$pod" ]
  then
    echo "index $i: no pod created (archived project?), skipping"
    helm uninstall "$rel" > /dev/null || exit 3
    continue
  fi
  echo "index $i: waiting for $pod"
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout=72h > /dev/null || echo "index $i: $pod did not succeed, check: kubectl -n $NS logs $pod"
  kubectl -n "$NS" logs "$pod" --tail=3 2>/dev/null | sed 's/^/  /'
  helm uninstall "$rel" > /dev/null || exit 4
done
echo 'OK'
