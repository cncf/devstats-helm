#!/bin/bash
# Login to any patroni node devstats-patroni-N: ./devstats-k8s-lf/util/pod_shell.sh devstats-postgres-N
curl -s localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"shared_buffers": "64MB", "max_parallel_workers_per_gather": "0"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "30", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "28", "max_connections": "300", "max_wal_size": "16GB", "effective_cache_size": "192GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "wal_buffers": "16MB", "default_statistics_target": "500", "effective_io_concurrency": "200", "work_mem": "8MB", "max_wal_size": "8GB", "max_worker_processes": "56", "max_parallel_workers": "56"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "30", "postgresql": {"parameters": {"shared_buffers": "80GB", "max_connections": "200", "max_parallel_workers_per_gather": "12", "max_worker_processes": "56", "max_parallel_workers": "56", "work_mem": "2GB", "temp_file_limit": "50GB", "idle_in_transaction_session_timeout": "60min", "wal_buffers": "128MB", "synchronous_commit": "off"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"k": "v"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"use_slots": true, "parameters": {"hot_standby": "on", "wal_log_hints": "on", "wal_keep_segments": "10", "wal_level": "hot_standby", "max_wal_senders": "5", "max_replication_slots": "5"}}}' http://localhost:8008/config | jq .
patronictl list
patronictl show-config
patronictl restart devstats-postgres
