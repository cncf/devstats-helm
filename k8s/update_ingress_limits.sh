#!/usr/bin/env bash
set -euo pipefail

# Requirements: kubectl, jq, helm
for bin in kubectl jq helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: missing $bin"; exit 1; }
done

ULIMIT_N="${ULIMIT_N:-65535}"
CHART="${CHART:-ingress-nginx/ingress-nginx}"

info() { echo "[$(date -u +'%F %T UTC')] $*"; }

# Build wrapper by reading the *current* DaemonSet controller args (source of truth)
build_wrap() {
  local ns="$1" ds="$2"
  kubectl -n "$ns" get ds "$ds" -o json | jq -r --arg u "$ULIMIT_N" '
    .spec.template.spec.containers[] | select(.name=="controller") |
    "ulimit -n " + $u + " && exec " + (.args | join(" "))
  '
}

# Find index of "controller" container in DS (for patch paths)
controller_index() {
  local ns="$1" ds="$2"
  kubectl -n "$ns" get ds "$ds" -o json \
    | jq -r '.spec.template.spec.containers | to_entries[] | select(.value.name=="controller") | .key' \
    | head -n1
}

# After helm upgrade, patch DS to force /bin/sh -c wrapper (because chart ignores controller.command/args in this version)
patch_ds_with_wrap() {
  local ns="$1" ds="$2" wrap="$3"
  local idx
  idx="$(controller_index "$ns" "$ds")"
  [[ -n "$idx" && "$idx" != "null" ]] || { echo "ERROR: cannot find controller container index for $ns/$ds"; exit 1; }

  info "Patching $ns/$ds (controller index=$idx) to run wrapper (ulimit=$ULIMIT_N)"
  # Use a JSON patch built with jq to avoid any quoting issues
  local patch
  patch="$(jq -n --arg wrap "$wrap" --argjson idx "$idx" '
    [
      {"op":"add","path":("/spec/template/spec/containers/"+($idx|tostring)+"/command"),"value":["/bin/sh","-c"]},
      {"op":"replace","path":("/spec/template/spec/containers/"+($idx|tostring)+"/args"),"value":[$wrap]}
    ]
  ')"

  kubectl -n "$ns" patch ds "$ds" --type='json' -p "$patch" >/dev/null
}

restart_pods() {
  local ns="$1" selector="$2"
  info "Restarting pods in $ns (selector: $selector)"
  kubectl -n "$ns" delete pod -l "$selector" >/dev/null
}

wait_ready() {
  local ns="$1" selector="$2"
  info "Waiting for pods Ready in $ns (selector: $selector)"
  kubectl -n "$ns" wait --for=condition=Ready pod -l "$selector" --timeout=300s >/dev/null
}

verify_limits() {
  local ns="$1" selector="$2"
  info "Verifying open-files limits inside pods in $ns (selector: $selector)"
  local pods
  pods="$(kubectl -n "$ns" get pods -l "$selector" -o name)"
  for p in $pods; do
    p="${p#pod/}"
    echo "=== $ns/$p ==="
    kubectl -n "$ns" exec "$p" -- sh -c 'ulimit -n; grep -i "open files" /proc/1/limits'
  done
}

do_one_env() {
  local env="$1" ns="$2" release="$3" ds="$4" selector="$5"
  info "==== $env: begin ===="

  # Build wrapper from CURRENT DS state (pre-upgrade)
  local wrap
  wrap="$(build_wrap "$ns" "$ds")"
  info "$env wrapper:"
  echo "$wrap"

  # Helm upgrade (kept because you asked; but chart ignores controller.command/args in this version)
  local values_file="/tmp/ingress-ulimit-${env}.yaml"
  cat > "$values_file" <<EOF
controller:
  command:
    - /bin/sh
    - -c
  args:
    - |-
      ${wrap}
EOF

  info "$env: helm upgrade (reuse-values) with $values_file"
  helm upgrade "$release" "$CHART" -n "$ns" --reuse-values -f "$values_file" >/dev/null || {
    echo "ERROR: helm upgrade failed for $env"
    exit 1
  }

  # Patch DS (the real effective step)
  patch_ds_with_wrap "$ns" "$ds" "$wrap"

  # Restart pods to pick up new DS template
  restart_pods "$ns" "$selector"
  wait_ready "$ns" "$selector"
  verify_limits "$ns" "$selector"

  info "==== $env: done ===="
}

# ----- Config for your cluster -----
TEST_NS="devstats-test"
TEST_RELEASE="nginx-ingress-test"
TEST_DS="nginx-ingress-test-ingress-nginx-controller"
TEST_SELECTOR='app.kubernetes.io/instance=nginx-ingress-test'

PROD_NS="devstats-prod"
PROD_RELEASE="nginx-ingress-prod"
PROD_DS="nginx-ingress-prod-ingress-nginx-controller"
PROD_SELECTOR='app.kubernetes.io/instance=nginx-ingress-prod'

do_one_env "test" "$TEST_NS" "$TEST_RELEASE" "$TEST_DS" "$TEST_SELECTOR"
do_one_env "prod" "$PROD_NS" "$PROD_RELEASE" "$PROD_DS" "$PROD_SELECTOR"

info "All done."

