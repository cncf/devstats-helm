#!/bin/bash
if [ -z "${OCI_COMPARTMENT_ID:-}" ] && [ -f ./OCI_COMPARTMENT_ID.secret ]; then
  export OCI_COMPARTMENT_ID="$(cat ./OCI_COMPARTMENT_ID.secret)"
fi
if [ -z "${OCI_REGION:-}" ] && [ -f ./OCI_REGION.secret ]; then
  export OCI_REGION="$(cat ./OCI_REGION.secret)"
fi
