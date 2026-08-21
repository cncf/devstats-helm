#!/bin/bash
# Applies the DCS-ONLY Patroni/PostgreSQL parameters via the Patroni REST API (/config PATCH).
#
# IMPORTANT - why this script is small: the devstats patroni image renders the
# PATRONI_POSTGRES_* pod envs (helm values, see TEST_PG_TUNE/PROD_PG_TUNE in the deploy
# scripts) into the LOCAL /home/postgres/patroni.yml, and local postgresql.parameters
# OVERRIDE the DCS for every regular parameter. So ALL sizing (shared_buffers, work_mem,
# effective_cache_size, temp_file_limit, autovacuum, ...) MUST be passed as helm values at
# install time - PATCHing them into the DCS is silently ignored at runtime.
# The DCS is authoritative ONLY for the Patroni-controlled params (max_connections,
# max_worker_processes, max_wal_senders, max_replication_slots, wal_level, wal_log_hints,
# hot_standby, wal_keep_size - Patroni defaults it to 128MB and ignores the local file)
# plus anything the local file does not define (password_encryption, checkpoint_timeout).
# Also: Patroni enforces loop_wait + 2*retry_timeout <= ttl, otherwise it SILENTLY runs
# with loop_wait=1s (K8s API hammering) - hence retry_timeout 20 (15 + 2*20 = 55 <= 60).
#
# Usage:
#   ENV=prod ./akamai/patroni-tune.sh
#   ENV=test ./akamai/patroni-tune.sh
# Then restart members to apply pending-restart parameters (max_connections etc.):
#   k exec -itn devstats-<ENV> devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
# Then VERIFY RUNTIME on every member (show-config is NOT enough - it prints the DCS):
#   k exec -n devstats-<ENV> devstats-postgres-N -c devstats-postgres -- psql -U postgres -tAc 'show shared_buffers; show max_connections; show wal_keep_size'
set -euo pipefail

# Pick up TOPOLOGY (PROD_DB_NODE_GB) automatically - self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [ -f "${AKAMAI_DIR}/linode-env.sh.secret" ]; then
  source "${AKAMAI_DIR}/linode-env.sh.secret"
else
  source "${AKAMAI_DIR}/linode-env.sh"
fi

ENV="${ENV:-}"
case "${ENV}" in
  prod) NS="devstats-prod"
        PARAMS='{
          "loop_wait": 15, "ttl": 60, "retry_timeout": 20,
          "primary_start_timeout": 600, "maximum_lag_on_failover": 53687091200,
          "postgresql": { "use_pg_rewind": true, "use_slots": true, "parameters": {
            "max_connections": 1024,
            "max_worker_processes": 32,
            "max_wal_senders": 10,
            "max_replication_slots": 10,
            "wal_level": "replica",
            "wal_log_hints": "on",
            "hot_standby": "on",
            "wal_keep_size": "100GB",
            "checkpoint_timeout": "15min",
            "password_encryption": "scram-sha-256"
          } } }' ;;
  test) NS="devstats-test"
        PARAMS='{
          "loop_wait": 15, "ttl": 60, "retry_timeout": 20,
          "primary_start_timeout": 600, "maximum_lag_on_failover": 53687091200,
          "postgresql": { "use_pg_rewind": true, "use_slots": true, "parameters": {
            "max_connections": 1024,
            "max_worker_processes": 16,
            "max_wal_senders": 10,
            "max_replication_slots": 10,
            "wal_level": "replica",
            "wal_log_hints": "on",
            "hot_standby": "on",
            "wal_keep_size": "50GB",
            "password_encryption": "scram-sha-256"
          } } }' ;;
  *) echo "usage: ENV=prod|test $0"; exit 1 ;;
esac

echo "Patching Patroni /config in namespace ${NS}..."
# PATCH against the local member REST API - Patroni persists it to the (Kubernetes) DCS,
# so any running member works; no leader-IP discovery needed.
kubectl exec -n "${NS}" devstats-postgres-0 -c devstats-postgres -- \
  curl -s -X PATCH -H 'Content-Type: application/json' -d "${PARAMS}" http://localhost:8008/config | jq . || \
kubectl exec -n "${NS}" devstats-postgres-0 -c devstats-postgres -- \
  curl -s -X PATCH -H 'Content-Type: application/json' -d "${PARAMS}" http://localhost:8008/config

echo
echo "Review + apply:"
echo "  kubectl exec -itn ${NS} devstats-postgres-0 -c devstats-postgres -- patronictl show-config"
echo "  kubectl exec -itn ${NS} devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres"
echo "  kubectl exec -itn ${NS} devstats-postgres-0 -c devstats-postgres -- patronictl list"
