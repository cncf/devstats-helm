#!/bin/bash
# Installs BOTH ingress-nginx controllers exactly as on OCI (README.md "nginx-ingress" section):
#   nginx-ingress-test: class nginx-test, ns devstats-test, NodePorts 31080/31443, nodes ingress=test
#   nginx-ingress-prod: class nginx-prod, ns devstats-prod, NodePorts 30080/30443, nodes ingress=prod
# DaemonSet + NodePort + externalTrafficPolicy=Local (NodeBalancer backends must be the labeled nodes).
# Requires: label-nodes.sh already applied; contexts test/prod configured (README "Contexts").
# After this run: ULIMIT_N=65535 ./k8s/update_ingress_limits.sh
set -euo pipefail

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

COMMON_SETS=(
  --set defaultBackend.enabled=false
  --set controller.config.disable-ipv6="true"
  --set controller.config.worker-rlimit-nofile="65535"
  --set controller.startupProbe.httpGet.path=/healthz
  --set controller.startupProbe.httpGet.port=10254
  --set controller.startupProbe.failureThreshold=18
  --set controller.startupProbe.periodSeconds=5
  --set controller.livenessProbe.initialDelaySeconds=30
  --set controller.livenessProbe.periodSeconds=20
  --set controller.livenessProbe.timeoutSeconds=5
  --set controller.livenessProbe.successThreshold=1
  --set controller.livenessProbe.failureThreshold=5
  --set controller.readinessProbe.initialDelaySeconds=15
  --set controller.readinessProbe.periodSeconds=20
  --set controller.readinessProbe.timeoutSeconds=5
  --set controller.readinessProbe.successThreshold=1
  --set controller.readinessProbe.failureThreshold=5
  --set controller.service.type=NodePort
  --set controller.kind=DaemonSet
  --set controller.service.externalTrafficPolicy=Local
)

echo "=== ingress-nginx TEST (nginx-test, 31080/31443) ==="
kubectl config use-context test
helm upgrade --install nginx-ingress-test ingress-nginx/ingress-nginx \
  --namespace devstats-test --create-namespace \
  --set controller.ingressClassResource.name=nginx-test \
  --set controller.ingressClass=nginx-test \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-test \
  --set controller.nodeSelector.ingress=test \
  --set controller.service.nodePorts.http=31080 \
  --set controller.service.nodePorts.https=31443 \
  "${COMMON_SETS[@]}"

echo "=== ingress-nginx PROD (nginx-prod, 30080/30443) ==="
kubectl config use-context prod
helm upgrade --install nginx-ingress-prod ingress-nginx/ingress-nginx \
  --namespace devstats-prod --create-namespace \
  --set controller.ingressClassResource.name=nginx-prod \
  --set controller.ingressClass=nginx-prod \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-prod \
  --set controller.nodeSelector.ingress=prod \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  "${COMMON_SETS[@]}"

echo
kubectl -n devstats-test get po -o wide -l app.kubernetes.io/name=ingress-nginx
kubectl -n devstats-prod get po -o wide -l app.kubernetes.io/name=ingress-nginx
echo
echo "Now run: ULIMIT_N=65535 ./k8s/update_ingress_limits.sh"
