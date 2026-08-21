#!/bin/bash
# MANDATORY k8s 1.36.3 <-> ingress-nginx v1.15.1 runtime qualification gate (plan §7.1).
#
# ingress-nginx's final certified support matrix ends at Kubernetes 1.35 and the project is
# retired (2026-03-24), so no upstream fix will ever come for a 1.36 incompatibility. This
# script is therefore the compatibility PROOF for our exact cluster (admission webhooks,
# EndpointSlice discovery, NGINX routing, every NodePort backend, and optionally both
# NodeBalancers). Run it AFTER install-ingresses.sh (and create-nodebalancers.sh) and
# BEFORE Patroni, restores, or any stateful workload. If it fails, the cluster holds no
# state yet - investigate, or rebuild with k8s 1.35.7 (in-place downgrade is unsupported).
#
# Usage (from a machine that reaches the node VPC IPs, e.g. devstats-master):
#   ./akamai/test-ingresses.sh                          # NodePort-level gate (all ingress nodes)
#   REQUIRE_NODEBALANCERS=1 ./akamai/test-ingresses.sh  # + NodeBalancer path (PROD_NB_IP/TEST_NB_IP set)
set -uo pipefail

AKAMAI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# secret-bearing env lives as linode-env.sh.secret (repo rule: sensitive files end in .secret)
# shellcheck disable=SC1091
if [ -f "${AKAMAI_DIR}/linode-env.sh.secret" ]; then
  source "${AKAMAI_DIR}/linode-env.sh.secret"
else
  source "${AKAMAI_DIR}/linode-env.sh"
fi

REQUIRE_NODEBALANCERS="${REQUIRE_NODEBALANCERS:-0}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
READY_TIMEOUT="${READY_TIMEOUT:-90}"
SMOKE="devstats-ingress-smoke"

FAILURES=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES+1)); }

http_code() { # host port ip path -> HTTP status via plain HTTP
  curl -s -o /dev/null -m "${CURL_TIMEOUT}" -w '%{http_code}' \
    -H "Host: $1" "http://$3:$2$4" || echo "000"
}
https_code() { # host port ip path -> HTTP status via HTTPS+SNI (controller fake cert -> -k)
  curl -sk -o /dev/null -m "${CURL_TIMEOUT}" -w '%{http_code}' \
    --resolve "$1:$2:$3" "https://$1:$2$4" || echo "000"
}

pods_snapshot() { # ns -> "uid restartCounts" per controller pod (recreation/restart detector)
  kubectl -n "$1" get po -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller \
    -o jsonpath='{range .items[*]}{.metadata.uid}{" "}{range .status.containerStatuses[*]}{.restartCount}{" "}{end}{"\n"}{end}' | sort
}

echo "=== [1] Kubernetes server version must be exactly v${K8S_PATCH} ==="
SERVER_VERSION="$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion')"
if [ "${SERVER_VERSION}" = "v${K8S_PATCH}" ]; then
  pass "server ${SERVER_VERSION}"
else
  fail "server ${SERVER_VERSION:-unknown}; expected v${K8S_PATCH} - this gate qualifies ONLY the pinned baseline"
  exit 1
fi

SNAP_TEST_BEFORE="$(pods_snapshot devstats-test)"
SNAP_PROD_BEFORE="$(pods_snapshot devstats-prod)"
[ -n "${SNAP_TEST_BEFORE}" ] || { fail "no test controller pods in devstats-test - run install-ingresses.sh first"; exit 1; }
[ -n "${SNAP_PROD_BEFORE}" ] || { fail "no prod controller pods in devstats-prod - run install-ingresses.sh first"; exit 1; }

setup_env() { # ns class release host
  local ns="$1" class="$2" release="$3" host="$4"
  # backend = the controllers' own /healthz on 10254: no external image needed
  kubectl -n "${ns}" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SMOKE}
  labels: { app: ${SMOKE} }
spec:
  selector:
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/instance: ${release}
    app.kubernetes.io/component: controller
  ports:
  - { name: healthz, port: 10254, targetPort: 10254 }
EOF
  # creating this v1 Ingress IS the admission-webhook acceptance test on k8s 1.36.
  # Expose /gate (rewritten to the backend's /healthz), NEVER /healthz itself: the
  # controller's catch-all server special-cases 'location /healthz' and returns 200
  # for ANY Host even with zero Ingresses (cloud-LB health checks), which would make
  # every routing and isolation probe below pass vacuously.
  kubectl -n "${ns}" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${SMOKE}
  labels: { app: ${SMOKE} }
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /healthz
spec:
  ingressClassName: ${class}
  rules:
  - host: ${host}
    http:
      paths:
      - path: /gate
        pathType: Prefix
        backend:
          service:
            name: ${SMOKE}
            port: { number: 10254 }
EOF
}

cleanup_env() { # ns
  kubectl -n "$1" delete ingress,svc "${SMOKE}" --ignore-not-found >/dev/null 2>&1 || true
}

check_env() { # name ns class release host http_port https_port backends...
  local name="$1" ns="$2" class="$3" release="$4" host="$5" http_port="$6" https_port="$7"
  shift 7
  local backends=("$@") ip code deadline slices

  echo "=== [${name}] admission webhook: create v1 Service+Ingress (${class} / ${host}) ==="
  if setup_env "${ns}" "${class}" "${release}" "${host}"; then
    pass "[${name}] networking.k8s.io/v1 Ingress admitted by the ${class} webhook"
  else
    fail "[${name}] admission webhook rejected/errored on a plain v1 Ingress - REAL 1.36 incompatibility signal"
    return
  fi

  echo "=== [${name}] EndpointSlice discovery ==="
  deadline=$((SECONDS + READY_TIMEOUT))
  slices=""
  while [ ${SECONDS} -lt ${deadline} ]; do
    slices="$(kubectl -n "${ns}" get endpointslices -l "kubernetes.io/service-name=${SMOKE}" \
      -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" "}{end}' 2>/dev/null)"
    [ -n "${slices// /}" ] && break
    sleep 3
  done
  if [ -n "${slices// /}" ]; then
    pass "[${name}] EndpointSlices populated: ${slices}"
  else
    fail "[${name}] no EndpointSlice endpoints for ${SMOKE} after ${READY_TIMEOUT}s"
    return
  fi

  echo "=== [${name}] wait for NGINX to load the new Ingress ==="
  deadline=$((SECONDS + READY_TIMEOUT))
  code="000"
  while [ ${SECONDS} -lt ${deadline} ]; do
    code="$(http_code "${host}" "${http_port}" "${backends[0]}" /gate)"
    [ "${code}" = "200" ] && break
    sleep 3
  done
  if [ "${code}" = "200" ]; then
    pass "[${name}] routing live on ${backends[0]}:${http_port}"
  else
    fail "[${name}] ${host} never became routable on ${backends[0]}:${http_port} (last code ${code})"
    return
  fi

  echo "=== [${name}] every NodePort backend, HTTP ${http_port} + HTTPS ${https_port} ==="
  for ip in "${backends[@]}"; do
    code="$(http_code "${host}" "${http_port}" "${ip}" /gate)"
    if [ "${code}" = "200" ]; then pass "[${name}] http://${ip}:${http_port} -> 200"
    else fail "[${name}] http://${ip}:${http_port} -> ${code}"; fi
    code="$(https_code "${host}" "${https_port}" "${ip}" /gate)"
    if [ "${code}" = "200" ]; then pass "[${name}] https://${ip}:${https_port} -> 200"
    else fail "[${name}] https://${ip}:${https_port} -> ${code}"; fi
  done
}

check_isolation() { # name host other_name other_http_port other_backend
  local name="$1" host="$2" other="$3" port="$4" ip="$5" code
  # /gate, never /healthz: /healthz is answered 200 by every controller for any Host
  code="$(http_code "${host}" "${port}" "${ip}" /gate)"
  if [ "${code}" = "200" ]; then
    fail "[isolation] ${other} controller served ${name}'s host ${host} - class separation broken"
  else
    pass "[isolation] ${other} controller does NOT serve ${host} (code ${code})"
  fi
}

check_nodebalancer() { # name nb_ip host
  local name="$1" nb_ip="$2" host="$3" code
  code="$(http_code "${host}" 80 "${nb_ip}" /gate)"
  if [ "${code}" = "200" ]; then pass "[${name}] NB http://${nb_ip}:80 -> 200"
  else fail "[${name}] NB http://${nb_ip}:80 -> ${code}"; fi
  code="$(https_code "${host}" 443 "${nb_ip}" /gate)"
  if [ "${code}" = "200" ]; then pass "[${name}] NB https://${nb_ip}:443 -> 200"
  else fail "[${name}] NB https://${nb_ip}:443 -> ${code}"; fi
}

TEST_HOST="smoke-test.teststats.cncf.io"
PROD_HOST="smoke-prod.devstats.cncf.io"

check_env test devstats-test nginx-test nginx-ingress-test "${TEST_HOST}" \
  "${TEST_HTTP_NODEPORT}" "${TEST_HTTPS_NODEPORT}" "${TEST_INGRESS_BACKENDS[@]}"
check_env prod devstats-prod nginx-prod nginx-ingress-prod "${PROD_HOST}" \
  "${PROD_HTTP_NODEPORT}" "${PROD_HTTPS_NODEPORT}" "${PROD_INGRESS_BACKENDS[@]}"

echo "=== [isolation] classes must not route each other's hostnames ==="
check_isolation test "${TEST_HOST}" prod "${PROD_HTTP_NODEPORT}" "${PROD_INGRESS_BACKENDS[0]}"
check_isolation prod "${PROD_HOST}" test "${TEST_HTTP_NODEPORT}" "${TEST_INGRESS_BACKENDS[0]}"

if [ "${REQUIRE_NODEBALANCERS}" = "1" ]; then
  echo "=== [NB] NodeBalancer path (HTTP 80 / HTTPS 443 -> NodePorts) ==="
  [ -n "${PROD_NB_IP}" ] && [ -n "${TEST_NB_IP}" ] || {
    fail "[NB] REQUIRE_NODEBALANCERS=1 but PROD_NB_IP/TEST_NB_IP unset in linode-env.sh"
  }
  [ -n "${TEST_NB_IP}" ] && check_nodebalancer test "${TEST_NB_IP}" "${TEST_HOST}"
  [ -n "${PROD_NB_IP}" ] && check_nodebalancer prod "${PROD_NB_IP}" "${PROD_HOST}"
else
  echo "=== [NB] skipped (set REQUIRE_NODEBALANCERS=1 after create-nodebalancers.sh) ==="
fi

echo "=== [stability] controller pods must survive the test unchanged ==="
SNAP_TEST_AFTER="$(pods_snapshot devstats-test)"
SNAP_PROD_AFTER="$(pods_snapshot devstats-prod)"
if [ "${SNAP_TEST_BEFORE}" = "${SNAP_TEST_AFTER}" ]; then
  pass "[test] no controller pod recreation/restarts"
else
  fail "[test] controller pods changed during the test:
before: ${SNAP_TEST_BEFORE}
after:  ${SNAP_TEST_AFTER}"
fi
if [ "${SNAP_PROD_BEFORE}" = "${SNAP_PROD_AFTER}" ]; then
  pass "[prod] no controller pod recreation/restarts"
else
  fail "[prod] controller pods changed during the test:
before: ${SNAP_PROD_BEFORE}
after:  ${SNAP_PROD_AFTER}"
fi

echo "=== [logs] recent controller logs must contain no panic/fatal ==="
for ns in devstats-test devstats-prod; do
  bad="$(kubectl -n "${ns}" logs -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller \
    --since=15m --tail=2000 2>/dev/null | grep -Eic 'panic|fatal' || true)"
  if [ "${bad:-0}" = "0" ]; then pass "[${ns}] controller logs clean"
  else fail "[${ns}] ${bad} panic/fatal line(s) in recent controller logs - inspect before proceeding"; fi
done

cleanup_env devstats-test
cleanup_env devstats-prod

echo
if [ "${FAILURES}" = "0" ]; then
  echo "ALL GATES PASSED: k8s v${K8S_PATCH} + ingress-nginx ${INGRESS_NGINX_CONTROLLER_VERSION} (chart ${INGRESS_NGINX_CHART_VERSION}) qualified on THIS cluster."
  echo "Safe to proceed to Patroni / restores (plan §8/§9)."
else
  echo "${FAILURES} GATE(S) FAILED - do NOT proceed to Patroni/restores." >&2
  echo "Cluster holds no state yet: investigate, or rebuild with k8s 1.35.7 (plan §7.1)." >&2
  exit 1
fi
