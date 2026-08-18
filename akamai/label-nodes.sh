#!/bin/bash
# Applies DevStats node labels on the new Akamai cluster (plan section 1.1).
#   node=devstats-app            - every node (app/backup workloads)
#   node2=devstats-db-prod       - prod Patroni pool (3 x G7-512)
#   node2=devstats-db-test       - test Patroni pool (2 x G7-256)
#   ingress=prod|test            - ingress-nginx DaemonSet + NodeBalancer backends
# Run from any node with kubectl admin access (context: any).
set -euo pipefail

ALL_NODES="devstats-prod-db-01 devstats-prod-db-02 devstats-prod-db-03 devstats-test-db-01 devstats-test-db-02 devstats-compute-01 devstats-compute-02"
# TOPOLOGY=8x256 adds a third pure-compute node (app workloads only, no extra labels)
if kubectl get node devstats-compute-03 >/dev/null 2>&1; then
  ALL_NODES="${ALL_NODES} devstats-compute-03"
fi

for node in ${ALL_NODES}; do
  kubectl label node "${node}" node=devstats-app --overwrite
done

for node in devstats-prod-db-01 devstats-prod-db-02 devstats-prod-db-03; do
  kubectl label node "${node}" node2=devstats-db-prod --overwrite
done

for node in devstats-test-db-01 devstats-test-db-02; do
  kubectl label node "${node}" node2=devstats-db-test --overwrite
done

# prod ingress: master/compute-01 + 2 prod-db nodes; test ingress: compute-02 + 2 test-db nodes.
# These MUST match the NodeBalancer backends (externalTrafficPolicy=Local).
kubectl label node devstats-compute-01 ingress=prod --overwrite
kubectl label node devstats-prod-db-02 ingress=prod --overwrite
kubectl label node devstats-prod-db-03 ingress=prod --overwrite
kubectl label node devstats-compute-02 ingress=test --overwrite
kubectl label node devstats-test-db-01 ingress=test --overwrite
kubectl label node devstats-test-db-02 ingress=test --overwrite

kubectl get nodes --show-labels
