#!/bin/bash
# Applies DevStats node labels on the new Akamai cluster (plan section 1.1).
#   node=devstats-app            - compute nodes + test-db nodes (app/backup/git-clone
#                                  workloads). PROD-db nodes must NOT carry it: every chart
#                                  pod that writes to openebs-hostpath (provisions, hourly
#                                  syncs, grafanas, bootstrap, affs-sync, backups) schedules
#                                  via appNodeSelector/backupsNodeSelector=node:devstats-app,
#                                  and hostpath PVCs bind (WaitForFirstConsumer) to the
#                                  node of the first consumer - keeping PROD-db-node disks
#                                  reserved for Patroni data only (test DBs are small, so
#                                  test-db nodes have room for apps too).
#   node2=devstats-db-prod       - prod Patroni pool (3 nodes: G7-512 mixed / G7-256 otherwise)
#   node2=devstats-db-test       - test Patroni pool (2 x G7-256)
#   ingress=prod|test            - ingress-nginx DaemonSet + NodeBalancer backends
# Run from any node with kubectl admin access (context: any).
set -euo pipefail

APP_NODES="devstats-compute-01 devstats-compute-02"
# TOPOLOGY=8x256 adds a third pure-compute node
if kubectl get node devstats-compute-03 >/dev/null 2>&1; then
  APP_NODES="${APP_NODES} devstats-compute-03"
fi
# test DBs are small - the two test-db nodes carry apps too (prod-db nodes NEVER):
APP_NODES="${APP_NODES} devstats-test-db-01 devstats-test-db-02"

for node in ${APP_NODES}; do
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
