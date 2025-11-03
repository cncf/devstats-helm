#!/bin/bash

# LG: see oci/nlb-setup.sh.secret instead
set -euo pipefail

export COMPARTMENT_OCID="$(cat ./OCI_COMPARTMENT_ID.secret)"
export REGION="$(cat ./OCI_REGION.secret)"
export SUBNET_OCID_PUBLIC="$(cat ./OCI_SUBNET.secret)"
export NSG_OCID="$(cat ./OCI_NSG.secret)"

# List of worker node private IPs per env (only the ones you labeled for that env):
# k label node devstats-master ingress=test
# k label node devstats-node-1 ingress=test
# k label node devstats-node-0 ingress=prod
# k label node devstats-node-2 ingress=prod
export TEST_NODE_IPS=("10.0.0.253" "10.0.0.53")
export PROD_NODE_IPS=("10.0.0.223" "10.0.0.48")

# NodePorts (HTTPS only)
export TEST_HTTPS=31443
export PROD_HTTPS=30443

## Optional lookups (kept as echo + commented commands)
echo "NLB_SUBNET_CIDR=\$(oci network subnet get --subnet-id \"$SUBNET_OCID_PUBLIC\" --query 'data.\"cidr-block\"' --raw-output)"
NLB_SUBNET_CIDR=$(oci network subnet get --subnet-id "$SUBNET_OCID_PUBLIC" --query 'data."cidr-block"' --raw-output)

## Create the NLBs (attach your existing NSG)
echo "TEST_NLB_OCID=\$(oci nlb network-load-balancer create --compartment-id \"$COMPARTMENT_OCID\" --display-name nlb-test-443 --subnet-id \"$SUBNET_OCID_PUBLIC\" --is-private false --network-security-group-ids \"[\\\"$NSG_OCID\\\"]\" --query 'data.id' --raw-output)"
# TEST_NLB_OCID=$(oci nlb network-load-balancer create --compartment-id "$COMPARTMENT_OCID" --display-name nlb-test-443 --subnet-id "$SUBNET_OCID_PUBLIC" --is-private false --network-security-group-ids "[\"$NSG_OCID\"]" --query 'data.id' --raw-output)

echo "PROD_NLB_OCID=\$(oci nlb network-load-balancer create --compartment-id \"$COMPARTMENT_OCID\" --display-name nlb-prod-443 --subnet-id \"$SUBNET_OCID_PUBLIC\" --is-private false --network-security-group-ids \"[\\\"$NSG_OCID\\\"]\" --query 'data.id' --raw-output)"
# PROD_NLB_OCID=$(oci nlb network-load-balancer create --compartment-id "$COMPARTMENT_OCID" --display-name nlb-prod-443 --subnet-id "$SUBNET_OCID_PUBLIC" --is-private false --network-security-group-ids "[\"$NSG_OCID\"]" --query 'data.id' --raw-output)

## Backend sets (TCP) with TCP health checks on the HTTPS NodePort
echo "oci nlb backend-set create --network-load-balancer-id \"$TEST_NLB_OCID\" --name bs-test-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port \"$TEST_HTTPS\""
# oci nlb backend-set create --network-load-balancer-id "$TEST_NLB_OCID" --name bs-test-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port "$TEST_HTTPS"
echo "oci nlb backend-set create --network-load-balancer-id \"$PROD_NLB_OCID\" --name bs-prod-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port \"$PROD_HTTPS\""
# oci nlb backend-set create --network-load-balancer-id "$PROD_NLB_OCID" --name bs-prod-443 --policy FIVE_TUPLE --health-checker-protocol TCP --health-checker-port "$PROD_HTTPS"

## Add backends (each labeled node, on the env’s HTTPS NodePort)
for ip in "${TEST_NODE_IPS[@]}"; do
  echo "oci nlb backend create --network-load-balancer-id \"$TEST_NLB_OCID\" --backend-set-name bs-test-443 --ip-address \"$ip\" --port \"$TEST_HTTPS\""
  # oci nlb backend create --network-load-balancer-id "$TEST_NLB_OCID" --backend-set-name bs-test-443 --ip-address "$ip" --port "$TEST_HTTPS"
done
for ip in "${PROD_NODE_IPS[@]}"; do
  echo "oci nlb backend create --network-load-balancer-id \"$PROD_NLB_OCID\" --backend-set-name bs-prod-443 --ip-address \"$ip\" --port \"$PROD_HTTPS\""
  # oci nlb backend create --network-load-balancer-id "$PROD_NLB_OCID" --backend-set-name bs-prod-443 --ip-address "$ip" --port "$PROD_HTTPS"
done

## Create listeners (TCP 443)
echo "oci nlb listener create --network-load-balancer-id \"$TEST_NLB_OCID\" --default-backend-set-name bs-test-443 --name li-test-443 --port 443 --protocol TCP"
# oci nlb listener create --network-load-balancer-id "$TEST_NLB_OCID" --default-backend-set-name bs-test-443 --name li-test-443 --port 443 --protocol TCP
echo "oci nlb listener create --network-load-balancer-id \"$PROD_NLB_OCID\" --default-backend-set-name bs-prod-443 --name li-prod-443 --port 443 --protocol TCP"
# oci nlb listener create --network-load-balancer-id "$PROD_NLB_OCID" --default-backend-set-name bs-prod-443 --name li-prod-443 --port 443 --protocol TCP

## NSG rules (using your single NSG attached everywhere):
## 1) Ingress 443 from Internet to anything in the NSG (lets the world reach the NLBs on 443)
echo "oci network nsg rules add --network-security-group-id \"$NSG_OCID\" --ingress-security-rules '[{\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"sourceType\":\"CIDR_BLOCK\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":443,\"max\":443}}}]'"
# oci network nsg rules add --network-security-group-id "$NSG_OCID" --ingress-security-rules '[{"protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","tcpOptions":{"destinationPortRange":{"min":443,"max":443}}}]'

## 2) Ingress NodePorts from “this NSG” to “this NSG” (allows NLB → workers on NodePorts; safe because only nodes/NLBs using this NSG can talk)
echo "oci network nsg rules add --network-security-group-id \"$NSG_OCID\" --ingress-security-rules '[{\"protocol\":\"6\",\"source\":\"$NSG_OCID\",\"sourceType\":\"NETWORK_SECURITY_GROUP\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":'$TEST_HTTPS',\"max\":'$TEST_HTTPS'}}},{\"protocol\":\"6\",\"source\":\"$NSG_OCID\",\"sourceType\":\"NETWORK_SECURITY_GROUP\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":'$PROD_HTTPS',\"max\":'$PROD_HTTPS'}}}]'"
# oci network nsg rules add --network-security-group-id "$NSG_OCID" --ingress-security-rules '[{"protocol":"6","source":"'"$NSG_OCID"'","sourceType":"NETWORK_SECURITY_GROUP","tcpOptions":{"destinationPortRange":{"min":'"$TEST_HTTPS"',"max":'"$TEST_HTTPS"'}}},{"protocol":"6","source":"'"$NSG_OCID"'","sourceType":"NETWORK_SECURITY_GROUP","tcpOptions":{"destinationPortRange":{"min":'"$PROD_HTTPS"',"max":'"$PROD_HTTPS"'}}}]'

## 3) (Optional) Egress from “this NSG” to “this NSG” on NodePorts (explicit NLB → worker egress; you already have egress ANY, so this is optional)
echo "# oci network nsg rules add --network-security-group-id \"$NSG_OCID\" --egress-security-rules '[{\"protocol\":\"6\",\"destination\":\"$NSG_OCID\",\"destinationType\":\"NETWORK_SECURITY_GROUP\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":'$TEST_HTTPS',\"max\":'$TEST_HTTPS'}}},{\"protocol\":\"6\",\"destination\":\"$NSG_OCID\",\"destinationType\":\"NETWORK_SECURITY_GROUP\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":'$PROD_HTTPS',\"max\":'$PROD_HTTPS'}}}]'"

## Get public IPs of the NLBs:
echo "oci nlb network-load-balancer get --network-load-balancer-id \"$TEST_NLB_OCID\" --query 'data.ip-addresses[0].ip-address' --raw-output"
# oci nlb network-load-balancer get --network-load-balancer-id "$TEST_NLB_OCID" --query 'data.ip-addresses[0].ip-address' --raw-output
echo "oci nlb network-load-balancer get --network-load-balancer-id \"$PROD_NLB_OCID\" --query 'data.ip-addresses[0].ip-address' --raw-output"
# oci nlb network-load-balancer get --network-load-balancer-id "$PROD_NLB_OCID" --query 'data.ip-addresses[0].ip-address' --raw-output

