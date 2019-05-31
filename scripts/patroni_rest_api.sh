#!/bin/bash
curl -s -XPATCH -d '{"postgresql": {"parameters": {"shared_buffers": "64MB", "max_parallel_workers_per_gather": "0"}, "use_pg_rewind": true}}' http://localhost:8008/config | jq .
