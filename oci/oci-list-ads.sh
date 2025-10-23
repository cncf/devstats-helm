#!/bin/bash
. ./oci/oci-env.sh
oci iam availability-domain list --region="${OCI_REGION}" --compartment-id "${OCI_COMPARTMENT_ID}" --query 'data[].name' --raw-output
