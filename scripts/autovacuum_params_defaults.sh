kubectl exec -itn devstats-prod devstats-postgres-0 -- patronictl list
kubectl exec -itn devstats-prod devstats-postgres-N -- bash
# Default parameters
curl -s -XPATCH -d '{"postgresql": {"parameters": {"autovacuum_analyze_scale_factor":"0.1","autovacuum_analyze_threshold":"50","autovacuum_max_workers":"3","autovacuum_naptime":"60s","autovacuum_vacuum_cost_limit":"-1","autovacuum_vacuum_scale_factor":"0.2","autovacuum_vacuum_threshold":"50"}}}' http://localhost:8008/config | jq .
# Parameters to reduce autovacuum pressure
curl -s -XPATCH -d '{"postgresql": {"parameters": {"autovacuum_analyze_scale_factor":"0.2","autovacuum_analyze_threshold":"100","autovacuum_max_workers":"1","autovacuum_naptime":"120s","autovacuum_vacuum_cost_limit":"100","autovacuum_vacuum_scale_factor":"0.25","autovacuum_vacuum_threshold":"150"}}}' http://localhost:8008/config | jq .
# Agressive autovacuum params
curl -s -XPATCH -d '{"postgresql": {"parameters": {"autovacuum_analyze_scale_factor":"0.005","autovacuum_analyze_threshold":"50","autovacuum_max_workers":"10","autovacuum_naptime":"10s","autovacuum_vacuum_cost_limit":"5000","autovacuum_vacuum_scale_factor":"0.01","autovacuum_vacuum_threshold":"50"}}}' http://localhost:8008/config | jq .
curl -s -XPATCH -d '{"postgresql": {"parameters": {"autovacuum_analyze_scale_factor":"0.2","autovacuum_analyze_threshold":"100","autovacuum_max_workers":"1","autovacuum_naptime":"120s","autovacuum_vacuum_cost_limit":"100","autovacuum_vacuum_scale_factor":"0.25","autovacuum_vacuum_threshold":"150"}}}' http://localhost:8008/config | jq .
kubectl exec -itn devstats-prod devstats-postgres-N -- patronictl restart --force devstats-postgres
kubectl exec -itn devstats-prod devstats-postgres-N -- patronictl show-config
