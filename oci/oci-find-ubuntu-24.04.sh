#!/bin/bash
. ./oci/oci-env.sh
if [ ! -z "${DEBUG}" ]
then
  oci compute image list \
    --region="${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_ID}" \
    --operating-system "Canonical Ubuntu" \
    --operating-system-version "24.04" \
    --sort-by TIMECREATED --sort-order DESC --all
fi
IMG="$(oci compute image list \
  --region="${OCI_REGION}" \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --sort-by TIMECREATED --sort-order DESC --all \
  --query 'data[0].id' --raw-output)"
echo "$IMG"
