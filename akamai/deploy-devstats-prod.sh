#!/bin/bash
# DevStats PROD deployment sequence on the Akamai cluster.
# Wraps the README.md prod Helm commands with Linode sizing overrides (plan section 14.1):
#   postgresNodes=3 (node2=devstats-db-prod); PVC/resources are topology-aware via
#   akamai/linode-env.sh: 6000Gi on 3 x G7-512 (mixed) or 4500Gi on G7-256 (8x256/7x256).
# Run phases IN ORDER from the repo root on the master (context: prod - ./switch_context.sh prod):
#   ./akamai/deploy-devstats-prod.sh secrets
#   ./akamai/deploy-devstats-prod.sh backups-pv
#   ./akamai/deploy-devstats-prod.sh pvcs
#   ./akamai/deploy-devstats-prod.sh patroni     # then: ENV=prod ./akamai/patroni-tune.sh + patronictl restart
#   ./akamai/deploy-devstats-prod.sh statics
#   ./akamai/deploy-devstats-prod.sh ingress
#   ./akamai/deploy-devstats-prod.sh bootstrap   # then grafana shared-data tar (README)
#   -> per-project restores: scripts/deploy_prod.sh (deploy_backup_to_prod.sh lines) - NOT here
#   ./akamai/deploy-devstats-prod.sh debug       # sleep pod w/ backups PV for restore_artificial_all.sh
#   ./akamai/deploy-devstats-prod.sh affs-import # daily shared-affiliations import cronjob
#   ./akamai/deploy-devstats-prod.sh api
#   ./akamai/deploy-devstats-prod.sh backups     # then k edit cj devstats-backups -> schedule '45 2 10,20 * *'
set -euo pipefail

PHASE="${1:-}"
NS="devstats-prod"
CHART="./devstats-helm"

# Pick up TOPOLOGY-dependent sizing automatically - self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AKAMAI_DIR}/linode-env.sh"

# Linode sizing (set by akamai/linode-env.sh above; export before running to override)
PROD_POSTGRES_NODES="${PROD_POSTGRES_NODES:-3}"
PROD_POSTGRES_STORAGE="${PROD_POSTGRES_STORAGE:-6000Gi}"
PROD_PG_REQ_CPU="${PROD_PG_REQ_CPU:-24000m}"; PROD_PG_LIM_CPU="${PROD_PG_LIM_CPU:-56000m}"
PROD_PG_REQ_MEM="${PROD_PG_REQ_MEM:-96Gi}";   PROD_PG_LIM_MEM="${PROD_PG_LIM_MEM:-400Gi}"

CTX="$(kubectl config current-context)"
if [ "${CTX}" != "prod" ]; then
  echo "current context is '${CTX}', expected 'prod' (./switch_context.sh prod)"; exit 1
fi

# skip-everything-except helper: pass the components to KEEP as args
skips_except () {
  local all="Secrets PVs BackupsPV Vacuum Backups Bootstrap Provisions Crons Affiliations Grafanas Services Postgres Ingress Static API Namespaces"
  local out="" s keep
  for s in ${all}; do
    keep=0
    for k in "$@"; do [ "${s}" = "${k}" ] && keep=1; done
    [ "${keep}" = "0" ] && out="${out},skip${s}=1"
  done
  echo "${out#,}"
}

case "${PHASE}" in
  secrets)
    helm install devstats-prod-secrets "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except Secrets)"
    ;;
  backups-pv)
    helm install devstats-prod-backups-pv "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except BackupsPV)"
    ;;
  pvcs)
    helm install devstats-prod-pvcs "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except PVs)"
    ;;
  patroni)
    helm install devstats-prod-patroni "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except Postgres),postgresNodes=${PROD_POSTGRES_NODES},postgresStorageSize=${PROD_POSTGRES_STORAGE},dbNodeSelector.node2=devstats-db-prod,requestsPostgresCPU=${PROD_PG_REQ_CPU},requestsPostgresMemory=${PROD_PG_REQ_MEM},limitsPostgresCPU=${PROD_PG_LIM_CPU},limitsPostgresMemory=${PROD_PG_LIM_MEM}"
    echo "Watch: kubectl -n ${NS} get po -o wide -w | grep postgres"
    echo "Then:  kubectl exec -itn ${NS} devstats-postgres-0 -- patronictl list"
    echo "Then:  ENV=prod ./akamai/patroni-tune.sh"
    ;;
  statics)
    helm install devstats-prod-statics "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except Static),indexStaticsFrom=1"
    ;;
  ingress)
    helm install devstats-prod-ingress "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except Ingress),skipAliases=1,indexDomainsFrom=1,ingressClass=nginx-prod,sslEnv=prod"
    ;;
  bootstrap)
    helm install devstats-prod-bootstrap "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except Bootstrap)"
    echo "Watch: kubectl -n ${NS} logs -f devstats-provision-bootstrap ; then kubectl -n ${NS} delete po devstats-provision-bootstrap"
    ;;
  debug)
    # New-cluster restore pod (README line 427). The OLD-cluster backup pod additionally
    # sets limitsBackupsCPU=4000m,limitsBackupsMemory=64Gi (README line 425) - run that there.
    helm install devstats-prod-debug "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except Bootstrap),bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1"
    echo "Shell:  ../devstats-k8s-lf/util/pod_shell.sh debug"
    echo "Inside (explicit ONLY - pod defaults to testServer=1, empty/unset ONLY would pick the TEST db list):"
    echo "  ONLY=\"\$(cat ./devstats-helm/all_prod_dbs.txt)\" RESTORE_FROM='https://devstats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"
    echo "After:  helm delete -n devstats-prod devstats-prod-debug"
    ;;
  affs-import)
    # Live-verified release devstats-prod-affs-import (helm get values 2026-08-18):
    # enables the daily devstats-affiliations-import cronjob (import_affs_shared.sh, 10 2 * * *)
    helm install devstats-prod-affs-import "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except),skipAffiliationsImport=,affiliationsDB=affiliations,prodServer=1,testServer="
    ;;
  api)
    helm install devstats-prod-api "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except API),apiImage=lukaszgryglicki/devstats-api-prod"
    ;;
  backups)
    helm install devstats-prod-backups "${CHART}" -n "${NS}" --set "namespace=${NS},$(skips_except Backups),backupsTestServer=,backupsProdServer=1"
    echo "Now: kubectl -n ${NS} edit cj devstats-backups  -> schedule: '45 2 10,20 * *' (and keep suspended until cutover)"
    ;;
  *)
    echo "usage: $0 secrets|backups-pv|pvcs|patroni|statics|ingress|bootstrap|debug|affs-import|api|backups"
    exit 1
    ;;
esac
