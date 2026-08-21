#!/bin/bash
# Applies Linode-sized Patroni/PostgreSQL parameters via the Patroni REST API (/config PATCH).
#
# Baseline = LIVE OCI config captured 2026-08-18 via `patronictl show-config` (verified):
#   prod (6 members, 2TiB nodes, limit 1Ti): shared_buffers 500GB, work_mem 8GB,
#     effective_cache_size 256GB, mppw_gather 28, max_worker/parallel 32,
#     temp_file_limit 200GB, wal_keep_size 100GB, max_wal_size 128GB
#   test (6 members, same nodes, limit 1Ti): DCS shared_buffers 250GB (runtime 500GB -
#   never restart-applied on OCI), work_mem 4GB,
#     effective_cache_size 128GB, mppw_gather 28, max_worker/parallel 16
#
# Scaled here for the Linode targets (only memory/CPU-bound params shrink; disk-bound
# params kept at live values because the 6000Gi/3600Gi PVCs afford them):
#   prod: 3 x G7 Dedicated 512 GB (64 vCPU), pod limit 400Gi/56 CPU  - ENV=prod
#   test: 2 x G7 Dedicated 256 GB (56 vCPU), pod limit 160Gi/40 CPU  - ENV=test
# See devstats-linodes-migration.md section 14. Starting points - tune after observing.
#
# Usage:
#   ENV=prod ./akamai/patroni-tune.sh
#   ENV=test ./akamai/patroni-tune.sh
# Then restart members to apply pending-restart parameters:
#   k exec -itn devstats-<ENV> devstats-postgres-0 -c devstats-postgres -- patronictl restart devstats-postgres
set -euo pipefail

# Pick up TOPOLOGY (PROD_DB_NODE_GB) automatically - self-source the env file.
AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${AKAMAI_DIR}/linode-env.sh"

ENV="${ENV:-}"
case "${ENV}" in
  prod) NS="devstats-prod"
        # live OCI -> G7-512: sb 500->128GB (25% node RAM), wm 8->2GB, mppwg 28->16;
        # ecs 256GB, temp 200GB, wal_keep 100GB, max_wal 128GB = unchanged from live.
        # TOPOLOGY=8x256/7x256 (PROD_DB_NODE_GB=256): sb 64GB, ecs 128GB, wm 1GB, temp 100GB.
        # MEASURED prod reality (2026-08-21): 245 DBs, 1793 GB total (allprj 521 GB, gha
        # 214 GB) -> autovacuum far more aggressive than live (1 worker @ cost_limit 100
        # cannot keep up with 245 DBs), maintenance_work_mem 4GB, checkpoint_timeout 15min.
        if [ "${PROD_DB_NODE_GB:-512}" = "256" ]; then
          SB="64GB"; ECS="128GB"; WM="1GB"; TEMP="100GB"
        else
          SB="128GB"; ECS="256GB"; WM="2GB"; TEMP="200GB"
        fi
        PARAMS='{
          "loop_wait": 15, "ttl": 60, "retry_timeout": 60,
          "primary_start_timeout": 600, "maximum_lag_on_failover": 53687091200,
          "postgresql": { "use_pg_rewind": true, "use_slots": true, "parameters": {
            "shared_buffers": "'"${SB}"'",
            "max_connections": 1024,
            "max_worker_processes": 32,
            "max_parallel_workers": 32,
            "max_parallel_workers_per_gather": 16,
            "work_mem": "'"${WM}"'",
            "wal_buffers": "1GB",
            "temp_file_limit": "'"${TEMP}"'",
            "wal_keep_size": "100GB",
            "max_wal_senders": 10,
            "max_replication_slots": 10,
            "maintenance_work_mem": "4GB",
            "idle_in_transaction_session_timeout": "30min",
            "wal_level": "replica",
            "wal_log_hints": "on",
            "hot_standby": "on",
            "hot_standby_feedback": "on",
            "max_wal_size": "128GB",
            "min_wal_size": "4GB",
            "checkpoint_completion_target": 0.9,
            "checkpoint_timeout": "15min",
            "default_statistics_target": 1000,
            "effective_cache_size": "'"${ECS}"'",
            "effective_io_concurrency": 8,
            "random_page_cost": 1.1,
            "autovacuum_max_workers": 4,
            "autovacuum_naptime": "30s",
            "autovacuum_vacuum_cost_limit": 1000,
            "autovacuum_vacuum_threshold": 150,
            "autovacuum_vacuum_scale_factor": 0.05,
            "autovacuum_analyze_threshold": 100,
            "autovacuum_analyze_scale_factor": 0.02,
            "password_encryption": "scram-sha-256"
          } } }' ;;
  test) NS="devstats-test"
        # live OCI -> G7-256, downsized to MEASURED test reality (2026-08-21): only 16
        # DBs, 170 GB total, biggest cii 85 GB, ~34 conns -> sb 32GB, ecs 64GB, wm 512MB,
        # workers 16/8/4, temp 50GB, wal_keep 50GB, max_wal 32GB - way below prod
        PARAMS='{
          "loop_wait": 15, "ttl": 60, "retry_timeout": 60,
          "primary_start_timeout": 600, "maximum_lag_on_failover": 53687091200,
          "postgresql": { "use_pg_rewind": true, "use_slots": true, "parameters": {
            "shared_buffers": "32GB",
            "max_connections": 1024,
            "max_worker_processes": 16,
            "max_parallel_workers": 8,
            "max_parallel_workers_per_gather": 4,
            "work_mem": "512MB",
            "wal_buffers": "1GB",
            "temp_file_limit": "50GB",
            "wal_keep_size": "50GB",
            "max_wal_senders": 10,
            "max_replication_slots": 10,
            "maintenance_work_mem": "1GB",
            "idle_in_transaction_session_timeout": "30min",
            "wal_level": "replica",
            "wal_log_hints": "on",
            "hot_standby": "on",
            "hot_standby_feedback": "on",
            "max_wal_size": "32GB",
            "min_wal_size": "2GB",
            "checkpoint_completion_target": 0.9,
            "default_statistics_target": 1000,
            "effective_cache_size": "64GB",
            "effective_io_concurrency": 8,
            "random_page_cost": 1.1,
            "autovacuum_max_workers": 1,
            "autovacuum_naptime": "120s",
            "autovacuum_vacuum_cost_limit": 200,
            "autovacuum_vacuum_threshold": 150,
            "autovacuum_vacuum_scale_factor": 0.1,
            "autovacuum_analyze_threshold": 100,
            "autovacuum_analyze_scale_factor": 0.05,
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
