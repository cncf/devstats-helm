#!/bin/bash
# Login to any patroni node devstats-patroni-N: ./devstats-k8s-lf/util/pod_shell.sh devstats-postgres-N
curl -s localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"shared_buffers": "64MB", "max_parallel_workers_per_gather": "0"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "28", "max_connections": "300", "max_wal_size": "16GB", "effective_cache_size": "192GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "wal_buffers": "16MB", "default_statistics_target": "500", "effective_io_concurrency": "200", "work_mem": "8MB", "max_wal_size": "8GB", "max_worker_processes": "56", "max_parallel_workers": "56"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "80GB", "max_connections": "200", "max_parallel_workers_per_gather": "12", "max_worker_processes": "56", "max_parallel_workers": "56", "work_mem": "2GB", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "60min", "wal_buffers": "128MB", "synchronous_commit": "off"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"k": "v"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"use_slots": true, "parameters": {"hot_standby": "on", "hot_standby_feedback": "on", "wal_log_hints": "on", "wal_keep_size": "4GB", "wal_level": "replica", "max_wal_senders": "5", "max_replication_slots": "5"}}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "15", "retry_timeout": "60", "ttl": "60", "master_start_timeout": "60", "maximum_lag_on_failover": "5368709120"}' http://localhost:8008/config | jq .
# Set single parameter (from withing patroni node)
curl -s -XPATCH -d '{"postgresql": {"parameters": {"max_parallel_workers_per_gather": "16"}}}' http://localhost:8008/config | jq .
# From master node only
PG_USER=postgres psql -c 'select application_name, replay_lag, sync_state from pg_stat_replication'
# watch 2
patronictl list
patronictl show-config
patronictl restart devstats-postgres
patronictl query --password -d devstats -c 'select dt, proj, prog, msg from gha_logs order by dt desc limit 50'
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "12", "max_connections": "1024", "max_wal_size": "16GB", "effective_cache_size": "192GB", "work_mem": "2GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "wal_buffers": "128MB", "max_worker_processes": "56", "max_parallel_workers": "56", "temp_file_limit": "50GB", "hot_standby": "on", "hot_standby_feedback": "on", "wal_log_hints": "on", "wal_keep_size": "4GB", "wal_level": "replica", "max_wal_senders": "5", "max_replication_slots": "5"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "28", "max_connections": "1024", "min_wal_size": "1GB", "max_wal_size": "16GB", "effective_cache_size": "192GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "default_statistics_target": 1000, "effective_io_concurrency": 8, "random_page_cost": 1.1, "wal_buffers": "128MB", "max_worker_processes": "56", "max_parallel_workers": "56", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "30min", "hot_standby": "on", "hot_standby_feedback": "on", "wal_log_hints": "on", "wal_keep_size": "4GB", "wal_level": "replica", "max_wal_senders": "5", "max_replication_slots": "5"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
# Final one (tweaked by Josh)
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "80GB", "max_parallel_workers_per_gather": "28", "max_connections": "1024", "min_wal_size": "1GB", "max_wal_size": "16GB", "effective_cache_size": "128GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "default_statistics_target": 1000, "effective_io_concurrency": 8, "random_page_cost": 1.1, "wal_buffers": "128MB", "max_worker_processes": "32", "max_parallel_workers": "32", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "30min", "hot_standby": "on", "hot_standby_feedback": "on", "wal_log_hints": "on", "wal_keep_size": "12GB", "wal_level": "replica", "max_wal_senders": "5", "max_replication_slots": "5"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
# Final manual set for Patroni based on Postgres 18 with HLL:
curl -s -X PATCH \
  -H 'Content-Type: application/json' \
  -d '{
    "loop_wait": 15,
    "ttl": 60,
    "retry_timeout": 60,
    "primary_start_timeout": 600,
    "maximum_lag_on_failover": 53687091200,
    "postgresql": {
      "use_pg_rewind": true,
      "use_slots": true,
      "parameters": {
        "shared_buffers": "500GB",
        "max_connections": 1024,
        "max_worker_processes": 32,
        "max_parallel_workers": 32,
        "max_parallel_workers_per_gather": 28,
        "work_mem": "8GB",
        "wal_buffers": "1GB",
        "temp_file_limit": "200GB",
        "wal_keep_size": "100GB",
        "max_wal_senders": 5,
        "max_replication_slots": 5,
        "maintenance_work_mem": "2GB",
        "idle_in_transaction_session_timeout": "30min",
        "wal_level": "replica",
        "wal_log_hints": "on",
        "hot_standby": "on",
        "hot_standby_feedback": "on",
        "max_wal_size": "128GB",
        "min_wal_size": "4GB",
        "checkpoint_completion_target": 0.9,
        "default_statistics_target": 1000,
        "effective_cache_size": "256GB",
        "effective_io_concurrency": 8,
        "random_page_cost": 1.1,
        "autovacuum_max_workers": 1,
        "autovacuum_naptime": "120s",
        "autovacuum_vacuum_cost_limit": 100,
        "autovacuum_vacuum_threshold": 150,
        "autovacuum_vacuum_scale_factor": 0.25,
        "autovacuum_analyze_threshold": 100,
        "autovacuum_analyze_scale_factor": 0.2
      }
    }
  }' \
  http://10.244.12.15:8008/config | jq .
