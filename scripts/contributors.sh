#!/bin/bash
helm install devstats-test-debug ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipNamespaces=1,skipPostgres=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={36000s} || exit 1
sleep 30 
echo "Run ./util_sh/update_contributors.sh inside the pod shell now"
../devstats-k8s-lf/util/pod_shell.sh debug || exit 2
kubectl cp debug:*.csv . || exit 3
#helm delete devstats-test-debug || exit 4
mv contrib.zip ~ || exit 5
echo 'OK'
