#!/bin/bash

WRAP_TEST="$(kubectl -n devstats-test get ds nginx-ingress-test-ingress-nginx-controller -o json \
  | jq -r '
      .spec.template.spec.containers[]
      | select(.name=="controller")
      | "ulimit -n 65535 && exec " + (.args | join(" "))
    ')"

cat > /tmp/ingress-ulimit-test.yaml <<EOF
controller:
  command:
    - /bin/sh
    - -c
  args:
    - |-
      ${WRAP_TEST}
EOF

cat /tmp/ingress-ulimit-test.yaml

helm upgrade nginx-ingress-test ingress-nginx/ingress-nginx \
  -n devstats-test \
  --reuse-values \
  -f /tmp/ingress-ulimit-test.yaml


WRAP_PROD="$(kubectl -n devstats-prod get ds nginx-ingress-prod-ingress-nginx-controller -o json \
  | jq -r '
      .spec.template.spec.containers[]
      | select(.name=="controller")
      | "ulimit -n 65535 && exec " + (.args | join(" "))
    ')"

cat > /tmp/ingress-ulimit-prod.yaml <<EOF
controller:
  command:
    - /bin/sh
    - -c
  args:
    - |-
      ${WRAP_PROD}
EOF

helm upgrade nginx-ingress-prod ingress-nginx/ingress-nginx \
  -n devstats-prod \
  --reuse-values \
  -f /tmp/ingress-ulimit-prod.yaml

