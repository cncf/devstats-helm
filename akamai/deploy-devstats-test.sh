#!/bin/bash
# DevStats TEST deployment sequence on the Akamai cluster.
# Wraps the README.md test Helm commands with Linode sizing overrides (plan section 14.2):
#   postgresNodes=2 on 2 x G7-256 (node2=devstats-db-test), PVC 3600Gi, right-sized resources.
# The test namespace serves ONLY: azf cii cncf fn godotengine linux opencontainers openfaas
# openwhisk riff sam zephyr (indexes [49,51) [53,55) [59,65) [67,68) [97,98)).
# Run phases IN ORDER from the repo root (context: test - ./switch_context.sh test):
#   ./akamai/deploy-devstats-test.sh secrets
#   ./akamai/deploy-devstats-test.sh backups-pv
#   ./akamai/deploy-devstats-test.sh pvcs        # then delete Pending non-test PVCs (see below)
#   ./akamai/deploy-devstats-test.sh patroni     # then: ENV=test ./akamai/patroni-tune.sh + patronictl restart
#   ./akamai/deploy-devstats-test.sh statics
#   ./akamai/deploy-devstats-test.sh ingress
#   ./akamai/deploy-devstats-test.sh bootstrap   # then grafana shared-data tar (README)
#   -> per-project restores: ./scripts/deploy_backup_to_test.sh <proj> <i> <i+1>  - NOT here
#   ./akamai/deploy-devstats-test.sh debug
#   ./akamai/deploy-devstats-test.sh affs-import # daily shared-affiliations import cronjob
#   ./akamai/deploy-devstats-test.sh api
#   ./akamai/deploy-devstats-test.sh backups     # installed SUSPENDED (test backups disabled; opt: monthly 45 2 28 * *)
set -euo pipefail

PHASE="${1:-}"
NS="devstats-test"
CHART="./devstats-helm"
TEST_PROJECTS='+azf\,+cii\,+cncf\,+fn\,+godotengine\,+linux\,+opencontainers\,+openfaas\,+openwhisk\,+riff\,+sam\,+zephyr'

# Pick up TOPOLOGY-dependent sizing automatically - self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AKAMAI_DIR}/linode-env.sh"

TEST_POSTGRES_NODES="${TEST_POSTGRES_NODES:-2}"
TEST_POSTGRES_STORAGE="${TEST_POSTGRES_STORAGE:-3600Gi}"
TEST_PG_REQ_CPU="${TEST_PG_REQ_CPU:-8000m}";  TEST_PG_LIM_CPU="${TEST_PG_LIM_CPU:-40000m}"
TEST_PG_REQ_MEM="${TEST_PG_REQ_MEM:-48Gi}";   TEST_PG_LIM_MEM="${TEST_PG_LIM_MEM:-160Gi}"

CTX="$(kubectl config current-context)"
if [ "${CTX}" != "test" ]; then
  echo "current context is '${CTX}', expected 'test' (./switch_context.sh test)"; exit 1
fi

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
    helm install devstats-test-secrets "${CHART}" --set "$(skips_except Secrets)"
    ;;
  backups-pv)
    helm install devstats-test-backups-pv "${CHART}" --set "$(skips_except BackupsPV)"
    ;;
  pvcs)
    helm install devstats-test-pvcs "${CHART}" --set "$(skips_except PVs),projectsOverride=${TEST_PROJECTS}"
    echo "Cleanup non-test PVCs after initialization:"
    echo "  kubectl -n ${NS} get pvc | grep Pending    # then kubectl -n ${NS} delete pvc <name> for non-test projects"
    ;;
  patroni)
    helm install devstats-test-patroni "${CHART}" --set "$(skips_except Postgres),postgresNodes=${TEST_POSTGRES_NODES},postgresStorageSize=${TEST_POSTGRES_STORAGE},dbNodeSelector.node2=devstats-db-test,requestsPostgresCPU=${TEST_PG_REQ_CPU},requestsPostgresMemory=${TEST_PG_REQ_MEM},limitsPostgresCPU=${TEST_PG_LIM_CPU},limitsPostgresMemory=${TEST_PG_LIM_MEM}"
    echo "Watch: kubectl -n ${NS} get po -o wide -w | grep postgres"
    echo "Then:  kubectl exec -itn ${NS} devstats-postgres-0 -- patronictl list   # leader + 1 replica"
    echo "Then:  ENV=test ./akamai/patroni-tune.sh"
    ;;
  statics)
    helm install devstats-test-statics "${CHART}" --set "$(skips_except Static),projectsOverride=${TEST_PROJECTS},indexStaticsFrom=0,indexStaticsTo=1"
    ;;
  ingress)
    helm install devstats-test-ingress "${CHART}" --set "$(skips_except Ingress),indexDomainsFrom=0,indexDomainsTo=1,projectsOverride=${TEST_PROJECTS},ingressClass=nginx-test,sslEnv=test"
    ;;
  bootstrap)
    helm install devstats-test-bootstrap "${CHART}" --set "$(skips_except Bootstrap),projectsOverride=${TEST_PROJECTS}"
    echo "Watch: kubectl -n ${NS} logs -f devstats-provision-bootstrap ; then kubectl -n ${NS} delete po devstats-provision-bootstrap"
    ;;
  debug)
    helm install devstats-test-debug "${CHART}" --set "$(skips_except Bootstrap),bootstrapPodName=debug,bootstrapCommand=sleep,bootstrapCommandArgs={360000s},bootstrapMountBackups=1"
    echo "Shell:  kubectl exec -itn ${NS} debug -- bash"
    echo "Inside: ONLY='azf cii cncf fn godotengine linux opencontainers openfaas openwhisk riff sam zephyr' \\"
    echo "        RESTORE_FROM='https://teststats.cncf.io' NOBACKUP='' ./devstats-helm/restore_artificial_all.sh"
    echo "After:  helm delete devstats-test-debug"
    ;;
  affs-import)
    # Live-verified release devstats-test-affs-import (helm get values 2026-08-18):
    # enables the daily devstats-affiliations-import cronjob (import_affs_shared.sh, 10 1 * * *)
    helm install devstats-test-affs-import "${CHART}" --set "$(skips_except),skipAffiliationsImport=,affiliationsDB=affiliations,prodServer=,testServer=1,backupsCronProd=45 2 16\,28 * *"
    ;;
  api)
    helm install devstats-test-api "${CHART}" --set "$(skips_except API),projectsOverride=${TEST_PROJECTS}"
    ;;
  backups)
    helm install devstats-test-backups "${CHART}" --set "$(skips_except Backups)"
    # Test is deliberately tiny (12 projects, no gha/allprj) - backups are near-worthless there.
    # SIMPLEST: keep the cronjob suspended forever (restore source is prod + git).
    kubectl -n "${NS}" patch cj devstats-backups -p '{"spec":{"suspend":true}}' || true
    echo "devstats-backups (test) installed and SUSPENDED (decision: test backups disabled)."
    echo "If you ever want monthly instead: kubectl -n ${NS} edit cj devstats-backups"
    echo "  -> schedule: '45 2 28 * *' and spec.suspend: false"
    ;;
  *)
    echo "usage: $0 secrets|backups-pv|pvcs|patroni|statics|ingress|bootstrap|debug|affs-import|api|backups"
    exit 1
    ;;
esac
