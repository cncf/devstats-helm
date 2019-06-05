#!/bin/bash
# DRYRUN=1 (only display what would be done)

ns=$1
if [ -z "$1" ]
then
  ns=default
fi

i=0
while true
do
  i=$((i+1))
  if [ "$i" = "1" ]
  then
    # CNCF cleanup
    export KUBECONFIG='/root/.kube/config_cncf'
  fi
  pods=""
  for data in `kubectl get po -l name=devstats -o=jsonpath='{range .items[*]}{.metadata.name}{";"}{.status.phase}{"\n"}{end}' -n $ns`
  do
    IFS=';'
    arr=($data)
    unset IFS
    pod=${arr[0]}
    sts=${arr[1]}
    base=${pod:0:8}
    #echo "$data -> $pod $sts $base"
    if ( [ "$sts" = "Succeeded" ] && [ "$base" = "devstats" ] )
    then
      pods="${pods} ${pod}"
    fi
  done
  if [ ! -z "$pods" ]
  then
    if [ -z "$DRYRUN" ]
    then
      echo "Deleting pods: ${pods}"
      kubectl delete pod ${pods} -n $ns
    else
      echo "Would delete pods: ${pods}"
    fi
  fi
  if [ "$i" = "3" ]
  then
    break
  fi
done
