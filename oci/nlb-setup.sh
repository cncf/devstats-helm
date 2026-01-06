#!/bin/bash
. ./oci/oci-env.sh

export SUBNET="ocid1..."
export NLB_TEST="ocid1..."
export NLB_PROD="ocid1..."
export NSG="ocid1..."

# Reserve Public IPs
# oci network public-ip delete --public-ip-id "..."
# oci network public-ip delete --public-ip-id "..."
oci network public-ip create --compartment-id "${OCI_COMPARTMENT_ID}" --lifetime RESERVED --display-name nlb-test-public-ip
oci network public-ip create --compartment-id "${OCI_COMPARTMENT_ID}" --lifetime RESERVED --display-name nlb-prod-public-ip
# oci network public-ip list --compartment-id "${OCI_COMPARTMENT_ID}" --scope REGION --all

# NLBs
# oci nlb network-load-balancer delete --network-load-balancer-id "${NLB_TEST}"
# oci nlb network-load-balancer delete --network-load-balancer-id "${NLB_PROD}"
oci nlb network-load-balancer create --compartment-id "${OCI_COMPARTMENT_ID}" --display-name nlb-test-https --subnet-id "${SUBNET}" --is-private false --network-security-group-ids "[\"${NSG}\"]"
oci nlb network-load-balancer create --compartment-id "${OCI_COMPARTMENT_ID}" --display-name nlb-prod-https --subnet-id "${SUBNET}" --is-private false --network-security-group-ids "[\"${NSG}\"]"
# oci nlb network-load-balancer list --compartment-id "${OCI_COMPARTMENT_ID}" --all

# Backend sets
# For 443 SSL
oci nlb backend-set create --network-load-balancer-id "${NLB_TEST}" --name bs-test-https --policy FIVE_TUPLE --health-checker '{"protocol":"TCP","port":31443,"retries":8,"timeoutInMillis":8000,"intervalInMillis":15000}'
oci nlb backend-set create --network-load-balancer-id "${NLB_PROD}" --name bs-prod-https --policy FIVE_TUPLE --health-checker '{"protocol":"TCP","port": 30443,"retries":8,"timeoutInMillis": 8000,"intervalInMillis": 15000}'
# For 80 HTTP (needed by cert-manager)
oci nlb backend-set create --network-load-balancer-id "${NLB_TEST}" --name bs-test-http --policy FIVE_TUPLE --health-checker "{\"protocol\":\"TCP\",\"port\":31080,\"retries\":8,\"timeoutInMillis\":8000,\"intervalInMillis\":15000}"
oci nlb backend-set create --network-load-balancer-id "${NLB_PROD}" --name bs-prod-http --policy FIVE_TUPLE --health-checker "{\"protocol\":\"TCP\",\"port\":30080,\"retries\":8,\"timeoutInMillis\":8000,\"intervalInMillis\":15000}"
# oci nlb backend-set list --network-load-balancer-id "${NLB_PROD}"
# oci nlb backend-set list --network-load-balancer-id "${NLB_TEST}"

# Backends
# For 443 SSL
# Test
oci nlb backend create --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-https --ip-address "10.0.0.253" --port "31443" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
oci nlb backend create --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-https --ip-address "10.0.0.53" --port "31443" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
oci nlb backend create --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-https --ip-address "10.0.9.45" --port "31443" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
# Prod
oci nlb backend create --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-https --ip-address "10.0.0.223" --port "30443" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
oci nlb backend create --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-https --ip-address "10.0.0.48" --port "30443" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
oci nlb backend create --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-https --ip-address "10.0.27.190" --port "30443" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
# For 80 HTTP (needed by cert-manager)
# Test
oci nlb backend create --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-http --ip-address "10.0.0.253" --port "31080" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
oci nlb backend create --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-http --ip-address "10.0.0.53"  --port "31080" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5                                                                                       
oci nlb backend create --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-http --ip-address "10.0.9.45"  --port "31080" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5 
# Prod
oci nlb backend create --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-http --ip-address "10.0.0.223"   --port "30080" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
oci nlb backend create --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-http --ip-address "10.0.0.48"    --port "30080" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
oci nlb backend create --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-http --ip-address "10.0.27.190"  --port "30080" --wait-for-state SUCCEEDED --max-wait-seconds 600 --wait-interval-seconds 5
# oci nlb backend list --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-https
# oci nlb backend list --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-https
# oci nlb backend list --network-load-balancer-id "${NLB_TEST}" --backend-set-name bs-test-http
# oci nlb backend list --network-load-balancer-id "${NLB_PROD}" --backend-set-name bs-prod-http

# Listeners
# For 443 SSL
oci nlb listener create --network-load-balancer-id "${NLB_TEST}" --default-backend-set-name bs-test-https --name li-test-https --port 443 --protocol TCP
oci nlb listener create --network-load-balancer-id "${NLB_PROD}" --default-backend-set-name bs-prod-https --name li-prod-https --port 443 --protocol TCP
# For 80 HTTP (needed by cert-manager)
oci nlb listener create --network-load-balancer-id "${NLB_TEST}" --default-backend-set-name bs-test-http --name li-test-http --port 80 --protocol TCP
oci nlb listener create --network-load-balancer-id "${NLB_PROD}" --default-backend-set-name bs-prod-http --name li-prod-http --port 80 --protocol TCP
# oci nlb listener list --network-load-balancer-id "${NLB_TEST}"
# oci nlb listener list --network-load-balancer-id "${NLB_PROD}"

# NLB NSG Rules (used by both prod and test NLBs)
oci network nsg rules add --nsg-id "${NSG}" --security-rules '[{"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","tcpOptions":{"destinationPortRange":{"min":443,"max":443}}}]'
oci network nsg rules add --nsg-id "${NSG}" --security-rules '[{"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","tcpOptions":{"destinationPortRange":{"min":80,"max":80}}}]'
oci network nsg rules add --nsg-id "${NSG}" --security-rules '[{"direction":"INGRESS","protocol":"6","source":"'"${NSG}"'","sourceType":"NETWORK_SECURITY_GROUP","tcpOptions":{"destinationPortRange":{"min":31443,"max":31443}}},{"direction":"INGRESS","protocol":"6","source":"'"${NSG}"'","sourceType":"NETWORK_SECURITY_GROUP","tcpOptions":{"destinationPortRange":{"min":30443,"max":30443}}}]'
oci network nsg rules add --nsg-id "${NSG}" --security-rules '[{"direction":"INGRESS","protocol":"6","source":"'"${NSG}"'","sourceType":"NETWORK_SECURITY_GROUP","tcpOptions":{"destinationPortRange":{"min":31080,"max":31080}}},{"direction":"INGRESS","protocol":"6","source":"'"${NSG}"'","sourceType":"NETWORK_SECURITY_GROUP","tcpOptions":{"destinationPortRange":{"min":30080,"max":30080}}}]'

# oci network nsg list --compartment-id "${OCI_COMPARTMENT_ID}"
# oci network nsg rules list --nsg-id "${NSG}"

# Public IPs
oci nlb network-load-balancer get --network-load-balancer-id "${NLB_TEST}" --query 'data."ip-addresses"[0]."ip-address"' --raw-output
oci nlb network-load-balancer get --network-load-balancer-id "${NLB_PROD}" --query 'data."ip-addresses"[0]."ip-address"' --raw-output
