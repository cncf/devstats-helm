# Manual backups

Create backups on test to restore on prod:
- Create shell/debugging pod: `helm install devstats-prod-debug ./devstats-helm --set namespace='devstats-prod',skipSecrets=1,skipPVs=1,skipBackupsPV=1,skipVacuum=1,skipBackups=1,skipProvisions=1,skipCrons=1,skipAffiliations=1,skipGrafanas=1,skipServices=1,skipPostgres=1,skipIngress=1,skipStatic=1,skipAPI=1,skipNamespaces=1,bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},useBootstrapResourcesLimits='',bootstrapMountBackups=1`.
- Shell into manual work pod: `../devstats-k8s-lf/util/pod_shell.sh debug`.
- Current backups are in `/root` for example: `gha.dump`, `gha.tar.xz`.
- Check age: `ls -l /root/*.dump /root/*.tar.xz | grep 2022` - check which ones are from 2022.
- Backup new project(s): `NOBACKUP='' NOAGE=1 GIANT=wait ONLY='backstage tremor porter openyurt openservicemesh' ./devstats-helm/backups.sh`.
- Once done, delete manual work pod: `helm delete devstats-prod-debug`.
