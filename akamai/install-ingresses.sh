#!/bin/bash
# Installs BOTH ingress-nginx controllers exactly as on OCI (README.md "nginx-ingress" section):
#   nginx-ingress-test: class nginx-test, ns devstats-test, NodePorts 31080/31443, nodes ingress=test
#   nginx-ingress-prod: class nginx-prod, ns devstats-prod, NodePorts 30080/30443, nodes ingress=prod
# DaemonSet + NodePort + externalTrafficPolicy=Local (NodeBalancer backends must be the labeled nodes).
#
# PINNED to the FINAL upstream release: chart ${INGRESS_NGINX_CHART_VERSION} / controller
# ${INGRESS_NGINX_CONTROLLER_VERSION} (project retired 2026-03-24 - no further releases).
# Its certified matrix ends at k8s 1.35; on our pinned k8s 1.36.3 this is a locally-validated
# exception: after this script (and create-nodebalancers.sh) you MUST run and pass
# ./akamai/test-ingresses.sh BEFORE Patroni, restores, or any stateful workload (plan §7.1).
#
# vs the plain OCI install this also (OpenAI Pro review, 2026-08-20):
#   - gives each controller a distinct identity (controllerValue + electionID) so neither
#     can ever claim the other's IngressClass (upstream multi-controller guidance);
#   - selects Ingresses strictly by class name (ingressClassByName, no class-less pickup);
#   - isolates each admission webhook to its own namespace (no cross-validation);
#   - pins controller/webhook images by digest;
#   - verifies resolved chart metadata before installing, installs with --atomic.
#
# Requires: label-nodes.sh already applied; contexts test/prod configured (README "Contexts").
# After this run: ULIMIT_N=65535 ./k8s/update_ingress_limits.sh
set -euo pipefail

AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${AKAMAI_DIR}/linode-env.sh"

CHART_REF="ingress-nginx/ingress-nginx"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

echo "=== chart metadata gate: ${CHART_REF} --version ${INGRESS_NGINX_CHART_VERSION} ==="
METADATA="$(helm show chart "${CHART_REF}" --version "${INGRESS_NGINX_CHART_VERSION}")"
CHART_VERSION="$(awk '$1 == "version:" { print $2; exit }' <<<"${METADATA}")"
APP_VERSION="$(awk '$1 == "appVersion:" { gsub(/"/, "", $2); print $2; exit }' <<<"${METADATA}")"
[ "${CHART_VERSION}" = "${INGRESS_NGINX_CHART_VERSION}" ] || {
  echo "resolved chart version ${CHART_VERSION}; expected ${INGRESS_NGINX_CHART_VERSION}" >&2
  exit 1
}
[ "${APP_VERSION}" = "${INGRESS_NGINX_CONTROLLER_VERSION#v}" ] || {
  echo "chart appVersion ${APP_VERSION}; expected ${INGRESS_NGINX_CONTROLLER_VERSION#v}" >&2
  exit 1
}
echo "chart ${CHART_VERSION} / controller ${APP_VERSION} confirmed"

COMMON_SETS=(
  --version "${INGRESS_NGINX_CHART_VERSION}"
  --atomic
  --set controller.image.tag="${INGRESS_NGINX_CONTROLLER_VERSION}"
  --set defaultBackend.enabled=false
  --set controller.ingressClassByName=true
  --set controller.watchIngressWithoutClass=false
  --set controller.allowSnippetAnnotations=false
  --set controller.enableAnnotationValidations=true
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
# digest pins (from the official v1.15.1 release notes; set to "" in linode-env.sh to disable)
if [ -n "${INGRESS_NGINX_CONTROLLER_DIGEST}" ]; then
  COMMON_SETS+=( --set controller.image.digest="${INGRESS_NGINX_CONTROLLER_DIGEST}" )
fi
if [ -n "${INGRESS_NGINX_WEBHOOK_VERSION}" ]; then
  COMMON_SETS+=( --set controller.admissionWebhooks.patch.image.tag="${INGRESS_NGINX_WEBHOOK_VERSION}" )
fi
if [ -n "${INGRESS_NGINX_WEBHOOK_DIGEST}" ]; then
  COMMON_SETS+=( --set controller.admissionWebhooks.patch.image.digest="${INGRESS_NGINX_WEBHOOK_DIGEST}" )
fi

echo "=== ingress-nginx TEST (nginx-test -> ${TEST_INGRESS_CONTROLLER_VALUE}, 31080/31443) ==="
kubectl config use-context test
helm upgrade --install nginx-ingress-test "${CHART_REF}" \
  --namespace devstats-test --create-namespace \
  --set controller.ingressClassResource.name=nginx-test \
  --set controller.ingressClassResource.controllerValue="${TEST_INGRESS_CONTROLLER_VALUE}" \
  --set controller.ingressClassResource.default=false \
  --set controller.ingressClass=nginx-test \
  --set controller.electionID=nginx-test-leader \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-test \
  --set 'controller.admissionWebhooks.namespaceSelector.matchLabels.kubernetes\.io/metadata\.name=devstats-test' \
  --set controller.nodeSelector.ingress=test \
  --set controller.service.nodePorts.http=31080 \
  --set controller.service.nodePorts.https=31443 \
  "${COMMON_SETS[@]}"

echo "=== ingress-nginx PROD (nginx-prod -> ${PROD_INGRESS_CONTROLLER_VALUE}, 30080/30443) ==="
kubectl config use-context prod
helm upgrade --install nginx-ingress-prod "${CHART_REF}" \
  --namespace devstats-prod --create-namespace \
  --set controller.ingressClassResource.name=nginx-prod \
  --set controller.ingressClassResource.controllerValue="${PROD_INGRESS_CONTROLLER_VALUE}" \
  --set controller.ingressClassResource.default=false \
  --set controller.ingressClass=nginx-prod \
  --set controller.electionID=nginx-prod-leader \
  --set controller.scope.enabled=true \
  --set controller.scope.namespace=devstats-prod \
  --set 'controller.admissionWebhooks.namespaceSelector.matchLabels.kubernetes\.io/metadata\.name=devstats-prod' \
  --set controller.nodeSelector.ingress=prod \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  "${COMMON_SETS[@]}"

echo
echo "=== post-install verification ==="
for pair in "devstats-test nginx-test ${TEST_INGRESS_CONTROLLER_VALUE}" \
            "devstats-prod nginx-prod ${PROD_INGRESS_CONTROLLER_VALUE}"; do
  read -r ns class want_controller <<<"${pair}"
  got_controller="$(kubectl get ingressclass "${class}" -o jsonpath='{.spec.controller}')"
  [ "${got_controller}" = "${want_controller}" ] || {
    echo "IngressClass ${class} controller=${got_controller}; expected ${want_controller}" >&2
    exit 1
  }
  echo "IngressClass ${class} -> ${got_controller} OK"
  echo "images in ${ns}:"
  kubectl -n "${ns}" get ds -l app.kubernetes.io/name=ingress-nginx \
    -o jsonpath='{range .items[*].spec.template.spec.containers[*]}{.image}{"\n"}{end}'
done
helm -n devstats-test list -f nginx-ingress-test
helm -n devstats-prod list -f nginx-ingress-prod
kubectl -n devstats-test get po -o wide -l app.kubernetes.io/name=ingress-nginx
kubectl -n devstats-prod get po -o wide -l app.kubernetes.io/name=ingress-nginx
echo
echo "Now run: ULIMIT_N=65535 ./k8s/update_ingress_limits.sh"
echo "Then the MANDATORY k8s-1.36.3 qualification gate (before ANY stateful workload):"
echo "  ./akamai/test-ingresses.sh                        # NodePort-level"
echo "  REQUIRE_NODEBALANCERS=1 ./akamai/test-ingresses.sh  # after create-nodebalancers.sh + NB IPs in linode-env.sh"
