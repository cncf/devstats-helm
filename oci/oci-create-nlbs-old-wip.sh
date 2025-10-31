#!/bin/bash

set -euo pipefail

export COMPARTMENT_OCID="$(cat ./OCI_COMPARTMENT_ID.secret)"
export REGION="$(cat ./OCI_REGION.secret)"
export SUBNET_OCID_PUBLIC="$(cat ./OCI_SUBNET.secret)"

# List of worker node private IPs per env (only the ones you labeled for that env):
# k label node devstats-master ingress=test
# k label node devstats-node-1 ingress=test
# k label node devstats-node-0 ingress=prod
# k label node devstats-node-2 ingress=prod
export TEST_NODE_IPS=("10.0.0.253" "10.0.0.53")
export PROD_NODE_IPS=("10.0.0.223" "10.0.0.48")   # example

export TEST_HTTPS=31443
export PROD_HTTPS=30443

## Create the NLBs
# TEST NLB (public)
echo "oci nlb network-load-balancer create --compartment-id \"$COMPARTMENT_OCID\" --display-name nlb-test-443 --subnet-id \"$SUBNET_OCID_PUBLIC\" --is-private false --query 'data.id' --raw-output"
# TEST_NLB_OCID=$(oci nlb network-load-balancer create --compartment-id "$COMPARTMENT_OCID" --display-name nlb-test-443 --subnet-id "$SUBNET_OCID_PUBLIC" --is-private false --query 'data.id' --raw-output)

# PROD NLB (public)
echo "oci nlb network-load-balancer create --compartment-id \"$COMPARTMENT_OCID\" --display-name nlb-prod-443 --subnet-id \"$SUBNET_OCID_PUBLIC\" --is-private false --query 'data.id' --raw-output"
# PROD_NLB_OCID=$(oci nlb network-load-balancer create --compartment-id "$COMPARTMENT_OCID" --display-name nlb-prod-443 --subnet-id "$SUBNET_OCID_PUBLIC" --is-private false --query 'data.id' --raw-output)

## Backend sets (TCP) with TCP health checks on the HTTPS NodePort
echo "oci nlb backend-set create --network-load-balancer-id \"$TEST_NLB_OCID\" --name bs-test-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port \"$TEST_HTTPS\""
# oci nlb backend-set create --network-load-balancer-id "$TEST_NLB_OCID" --name bs-test-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port "$TEST_HTTPS"

# PROD backend set (health check TCP:30443)
echo "oci nlb backend-set create --network-load-balancer-id \"$PROD_NLB_OCID\" --name bs-prod-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port \"$PROD_HTTPS\""
# oci nlb backend-set create --network-load-balancer-id "$PROD_NLB_OCID" --name bs-prod-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port "$PROD_HTTPS"

## Add backends (each labeled node, on the env’s HTTPS NodePort)
# TEST backends
for ip in "${TEST_NODE_IPS[@]}"; do
  echo "oci nlb backend create --network-load-balancer-id \"$TEST_NLB_OCID\" --backend-set-name bs-test-443 --ip-address \"$ip\" --port \"$TEST_HTTPS\""
  # oci nlb backend create --network-load-balancer-id "$TEST_NLB_OCID" --backend-set-name bs-test-443 --ip-address "$ip" --port "$TEST_HTTPS"
done

# PROD backends
for ip in "${PROD_NODE_IPS[@]}"; do
  echo "oci nlb backend create --network-load-balancer-id \"$PROD_NLB_OCID\" --backend-set-name bs-prod-443 --ip-address \"$ip\" --port \"$PROD_HTTPS\""
  # oci nlb backend create --network-load-balancer-id "$PROD_NLB_OCID" --backend-set-name bs-prod-443 --ip-address "$ip" --port "$PROD_HTTPS"
done

## Create listeners (TCP 443)
echo "oci nlb listener create --network-load-balancer-id \"$TEST_NLB_OCID\" --default-backend-set-name bs-test-443 --name li-test-443 --port 443 --protocol TCP"
# oci nlb listener create --network-load-balancer-id "$TEST_NLB_OCID" --default-backend-set-name bs-test-443 --name li-test-443 --port 443 --protocol TCP

echo "oci nlb listener create --network-load-balancer-id \"$PROD_NLB_OCID\" --default-backend-set-name bs-prod-443 --name li-prod-443 --port 443 --protocol TCP"
# oci nlb listener create --network-load-balancer-id "$PROD_NLB_OCID" --default-backend-set-name bs-prod-443 --name li-prod-443 --port 443 --protocol TCP


## Security rules: XXX (missing oci commands)
# - Allow 0.0.0.0/0 → NLB on TCP/443 (ingress on the NLB’s subnet/NSG).
# - Allow NLB subnet CIDR → worker subnet on TCP 40443 (test) and 30443 (prod).


## Get public IPs of the NLBs:
echo "oci nlb network-load-balancer get --network-load-balancer-id \"$TEST_NLB_OCID\" --query 'data.ip-addresses[0].ip-address' --raw-output"
# oci nlb network-load-balancer get --network-load-balancer-id "$TEST_NLB_OCID" --query 'data.ip-addresses[0].ip-address' --raw-output
echo "oci nlb network-load-balancer get --network-load-balancer-id \"$PROD_NLB_OCID\" --query 'data.ip-addresses[0].ip-address' --raw-output"
# oci nlb network-load-balancer get --network-load-balancer-id "$PROD_NLB_OCID" --query 'data.ip-addresses[0].ip-address' --raw-output

