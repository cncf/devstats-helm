#!/bin/bash
set -euo pipefail

export COMPARTMENT_OCID="$(cat ./OCI_COMPARTMENT_ID.secret)"
export REGION="$(cat ./OCI_REGION.secret)"
export SUBNET_OCID_PUBLIC="$(cat ./OCI_SUBNET.secret)"
export NSG_OCID="$(cat ./OCI_NSG.secret)"

# List of worker node private IPs per env (only the ones you labeled for that env):
# k label node devstats-master ingress=test
# k label node devstats-node-1 ingress=test
# k label node devstats-node-3 ingress=test
# k label node devstats-node-0 ingress=prod
# k label node devstats-node-2 ingress=prod
# k label node devstats-node-4 ingress=prod
export TEST_NODE_IPS=("10.0.0.253" "10.0.0.53" "10.0.9.45")
export PROD_NODE_IPS=("10.0.0.223" "10.0.0.48" "10.0.27.190")

# NodePorts (HTTPS only)
export TEST_HTTPS=31443
export PROD_HTTPS=30443


TEST_NLB_OCID="$(cat ./OCI_NLB_TEST.secret)"
PROD_NLB_OCID="$(cat ./OCI_NLB_PROD.secret)"

## 3) (Optional) Egress from “this NSG” to “this NSG” on NodePorts (explicit NLB → worker egress; you already have egress ANY, so this is optional)
echo "# oci network nsg rules add --network-security-group-id \"$NSG_OCID\" --egress-security-rules '[{\"protocol\":\"6\",\"destination\":\"$NSG_OCID\",\"destinationType\":\"NETWORK_SECURITY_GROUP\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":'$TEST_HTTPS',\"max\":'$TEST_HTTPS'}}},{\"protocol\":\"6\",\"destination\":\"$NSG_OCID\",\"destinationType\":\"NETWORK_SECURITY_GROUP\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":'$PROD_HTTPS',\"max\":'$PROD_HTTPS'}}}]'"
