#!/bin/bash
# ./oci/oci-list-instances.sh | jq '.data[].id,.data[]."display-name"'
. ./oci/oci-env.sh
oci compute instance list --region="${OCI_REGION}" --compartment-id "${OCI_COMPARTMENT_ID}" --all
