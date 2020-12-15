#!/bin/bash
# Login to any patroni node devstats-patroni-N: ./devstats-k8s-lf/util/pod_shell.sh devstats-postgres-N
curl -s localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"shared_buffers": "64MB", "max_parallel_workers_per_gather": "0"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "28", "max_connections": "300", "max_wal_size": "16GB", "effective_cache_size": "192GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "wal_buffers": "16MB", "default_statistics_target": "500", "effective_io_concurrency": "200", "work_mem": "8MB", "max_wal_size": "8GB", "max_worker_processes": "56", "max_parallel_workers": "56"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "80GB", "max_connections": "200", "max_parallel_workers_per_gather": "12", "max_worker_processes": "56", "max_parallel_workers": "56", "work_mem": "2GB", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "60min", "wal_buffers": "128MB", "synchronous_commit": "off"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"k": "v"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"use_slots": true, "parameters": {"hot_standby": "on", "wal_log_hints": "on", "wal_keep_segments": "10", "wal_level": "hot_standby", "max_wal_senders": "5", "max_replication_slots": "5"}}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "15", "retry_timeout": "60", "ttl": "60", "master_start_timeout": "60", "maximum_lag_on_failover": "5368709120"}' http://localhost:8008/config | jq .
# From master node only
PG_USER=postgres psql -c 'select application_name, replay_lag, sync_state from pg_stat_replication'
# \watch 2
patronictl list
patronictl show-config
patronictl restart devstats-postgres
patronictl query --password -d devstats -c 'select dt, proj, prog, msg from gha_logs order by dt desc limit 50'
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "12", "max_connections": "1024", "max_wal_size": "16GB", "effective_cache_size": "192GB", "work_mem": "2GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "wal_buffers": "128MB", "max_worker_processes": "56", "max_parallel_workers": "56", "temp_file_limit": "50GB", "hot_standby": "on", "wal_log_hints": "on", "wal_keep_segments": "10", "wal_level": "hot_standby", "max_wal_senders": "5", "max_replication_slots": "5"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
# Final one (tweaked by Josh)
curl -s -XPATCH -d '{"loop_wait": "15", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "28", "max_connections": "1024", "min_wal_size": "1GB", "max_wal_size": "16GB", "effective_cache_size": "192GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "default_statistics_target": 1000, "effective_io_concurrency": 8, "random_page_cost": 1.1, "wal_buffers": "128MB", "max_worker_processes": "56", "max_parallel_workers": "56", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "30min", "hot_standby": "on", "wal_log_hints": "on", "wal_keep_segments": "10", "wal_level": "hot_standby", "max_wal_senders": "5", "max_replication_slots": "5"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
