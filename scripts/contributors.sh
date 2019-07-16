#!/bin/bash
helm install devstats-test-debug ./devstats-helm --set skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipGrafanas=1,skipServices=1,skipIngress=1,skipStatic=1,skipNamespaces=1,skipPostgres=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={36000s} || exit 1
sleep 30 
echo "Run NOZIP=1 ./util_sh/update_contributors.sh inside the pod shell now"
../devstats-k8s-lf/util/pod_shell.sh debug || exit 2
kubectl cp debug:contributing_actors.csv contributing_actors.csv
kubectl cp debug:contributing_actors_data.csv contributing_actors_data.csv
kubectl cp debug:contributors_and_emails.csv contributors_and_emails.csv
kubectl cp debug:k8s_contributors_and_emails.csv k8s_contributors_and_emails.csv
kubectl cp debug:k8s_yearly_contributors_with_50.csv k8s_yearly_contributors_with_50.csv
kubectl cp debug:top_50_k8s_yearly_contributors.csv top_50_k8s_yearly_contributors.csv
helm delete devstats-test-debug
zip -9 ~/contrib.zip contributors_and_emails.csv contributing_actors.csv contributing_actors_data.csv k8s_contributors_and_emails.csv top_50_k8s_yearly_contributors.csv k8s_yearly_contributors_with_50.csv
mv contrib.zip ~
rm contributors_and_emails.csv contributing_actors.csv contributing_actors_data.csv k8s_contributors_and_emails.csv top_50_k8s_yearly_contributors.csv k8s_yearly_contributors_with_50.csv
echo 'OK'
