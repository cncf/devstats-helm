#!/bin/bash
# Login to any patroni node devstats-patroni-N: ./devstats-k8s-lf/util/pod_shell.sh devstats-postgres-N
curl -s localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"shared_buffers": "64MB", "max_parallel_workers_per_gather": "0"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"loop_wait": "30", "postgresql": {"parameters": {"shared_buffers": "96GB", "max_parallel_workers_per_gather": "28", "max_connections": "300", "max_wal_size": "16GB", "effective_cache_size": "192GB", "maintenance_work_mem": "2GB", "checkpoint_completion_target": "0.9", "wal_buffers": "16MB", "default_statistics_target": "500", "effective_io_concurrency": "200", "work_mem": "8MB", "max_wal_size": "8GB", "max_worker_processes": "56", "max_parallel_workers": "56"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
patronictl list
patronictl show-config
patronictl restart devstats-postgres
