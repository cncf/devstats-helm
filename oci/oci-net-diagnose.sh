#!/usr/bin/env bash

# Requirements:
# - env: OCI_COMPARTMENT_ID, OCI_REGION (or files ./OCI_COMPARTMENT_ID.secret, ./OCI_REGION.secret)
# - tools: oci, jq

. ./oci/oci-env.sh

set -euo pipefail

: "${OCI_COMPARTMENT_ID:?Set OCI_COMPARTMENT_ID to your (root) compartment/tenancy OCID}"
: "${OCI_REGION:?Set OCI_REGION to your region, e.g., us-ashburn-1}"

export OCI_CLI_REGION="${OCI_REGION}"

hr() { printf '\n%s\n' "────────────────────────────────────────────────────────────"; }
sec() { printf '\n%s\n' "## $*"; }

# --- Helpers to safely coerce output to JSON arrays/objects -------------------
# Read stdin into a buffer; if it's valid JSON, print it; otherwise print default.
json_or_default() {
  local def="${1:-[]}"
  local buf
  buf="$(cat || true)"
  if [ -z "$buf" ]; then
    printf '%s' "$def"
    return
  fi
  if printf '%s' "$buf" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$buf"
  else
    printf '%s' "$def"
  fi
}

# --- Simple caches to avoid repeated API calls --------------------------------
declare -A SUBNET_JSON
declare -A VCN_JSON
declare -A SECLIST_JSON
declare -A RT_JSON
declare -A NSG_JSON

fetch_subnet() {
  local id="$1"
  [[ -n "${SUBNET_JSON[$id]+x}" ]] || SUBNET_JSON[$id]="$(oci network subnet get --subnet-id "$id" --query 'data' --raw-output 2>/dev/null | json_or_default '{}')"
  printf '%s' "${SUBNET_JSON[$id]}"
}

fetch_vcn() {
  local id="$1"
  [[ -n "${VCN_JSON[$id]+x}" ]] || VCN_JSON[$id]="$(oci network vcn get --vcn-id "$id" --query 'data' --raw-output 2>/dev/null | json_or_default '{}')"
  printf '%s' "${VCN_JSON[$id]}"
}

fetch_seclist() {
  local id="$1"
  [[ -n "${SECLIST_JSON[$id]+x}" ]] || SECLIST_JSON[$id]="$(oci network security-list get --security-list-id "$id" --query 'data' --raw-output 2>/dev/null | json_or_default '{}')"
  printf '%s' "${SECLIST_JSON[$id]}"
}

fetch_rt() {
  local id="$1"
  [[ -n "${RT_JSON[$id]+x}" ]] || RT_JSON[$id]="$(oci network route-table get --rt-id "$id" --query 'data' --raw-output 2>/dev/null | json_or_default '{}')"
  printf '%s' "${RT_JSON[$id]}"
}

fetch_nsg() {
  local id="$1"
  [[ -n "${NSG_JSON[$id]+x}" ]] || NSG_JSON[$id]="$(
    # Do NOT pre-filter; some builds wrap in {data:{...}}
    (oci network nsg get --network-security-group-id "$id" 2>/dev/null \
     || oci network network-security-group get --network-security-group-id "$id" 2>/dev/null) \
    | json_or_default '{}' | jq -c '.data // .'
  )"
  printf '%s' "${NSG_JSON[$id]}"
}

list_nsg_rules() {
  local id="$1"
  local raw
  if ! raw="$(oci network nsg rules list --nsg-id "$id" --all 2>/dev/null)"; then
    printf '[]'
    return
  fi
  printf '%s' "$raw" | jq -c '.data // []'
}

# Optional: DRG & LPG visibility for cross-VCN checks
list_drg_attachments_for_vcn() {
  local vcn_id="$1"
  oci network drg-attachment list --compartment-id "$OCI_COMPARTMENT_ID" \
    --query "data[?\"vcn-id\"=='${vcn_id}']" --raw-output 2>/dev/null | json_or_default '[]'
}
list_local_peering_gateways_for_vcn() {
  local vcn_id="$1"
  oci network local-peering-gateway list --compartment-id "$OCI_COMPARTMENT_ID" --vcn-id "$vcn_id" \
    --query 'data' --raw-output 2>/dev/null | json_or_default '[]'
}

sec "Instances in ${OCI_REGION} (compartment ${OCI_COMPARTMENT_ID})"
INSTANCES_JSON="$(
  oci compute instance list \
    --compartment-id "$OCI_COMPARTMENT_ID" \
    --all \
    --query 'data' \
    --raw-output 2>/dev/null | json_or_default '[]'
)"
printf '%s' "$INSTANCES_JSON" | jq -r '
  map({name: ."display-name", id: .id, ad: ."availability-domain", state: ."lifecycle-state"}) |
  (["Name","State","AD","OCID"] | @tsv),
  (.[] | [ .name, .state, .ad, .id ] | @tsv)
' | column -t

if [[ "$(printf '%s' "$INSTANCES_JSON" | jq 'length')" -eq 0 ]]; then
  hr
  echo "No instances found here. Double-check region/compartment."
  exit 0
fi

sec "Per-instance networking"
printf '%s' "$INSTANCES_JSON" | jq -r '.[].id' | while read -r INSTANCE_ID; do
  NAME="$(printf '%s' "$INSTANCES_JSON" | jq -r ".[] | select(.id==\"${INSTANCE_ID}\") | .\"display-name\"")"
  hr
  echo "# Instance: ${NAME} (${INSTANCE_ID})"

  VNIC_ATT="$(
    oci compute vnic-attachment list \
      --compartment-id "$OCI_COMPARTMENT_ID" \
      --instance-id "$INSTANCE_ID" \
      --all --query 'data' --raw-output 2>/dev/null | json_or_default '[]'
  )"
  if [[ "$(printf '%s' "$VNIC_ATT" | jq 'length')" -eq 0 ]]; then
    echo "No VNIC attachments found."
    continue
  fi

  printf '%s' "$VNIC_ATT" | jq -r '
    map({id:.id, "vnic-id":."vnic-id", "subnet-id":."subnet-id", "nic-index":."nic-index"}) |
    (["VNIC-ATTACHMENT","VNIC-ID","SUBNET-ID","NIC-INDEX"] | @tsv),
    (.[] | [ .id, ."vnic-id", ."subnet-id", (."nic-index"|tostring) ] | @tsv)
  ' | column -t

  printf '%s' "$VNIC_ATT" | jq -r '.[]."vnic-id"' | while read -r VNIC_ID; do
    echo
    echo "→ VNIC: ${VNIC_ID}"
    VNIC="$(oci network vnic get --vnic-id "$VNIC_ID" --query 'data' --raw-output 2>/dev/null | json_or_default '{}')"
    printf '%s\n' "$VNIC" | jq '{
      "display-name": ."display-name",
      "hostname-label": ."hostname-label",
      "is-primary": ."is-primary",
      "mac-address": ."mac-address",
      "private-ip": ."private-ip",
      "public-ip": ."public-ip",
      "subnet-id": ."subnet-id",
      "nsg-ids": (."nsg-ids" // [])
    }'

    SUBNET_ID="$(printf '%s' "$VNIC" | jq -r '."subnet-id"')"
    SUBNET="$(fetch_subnet "$SUBNET_ID")"
    VCN_ID="$(printf '%s' "$SUBNET" | jq -r '."vcn-id"')"
    VCN="$(fetch_vcn "$VCN_ID")"

    echo
    echo "  Subnet:"
    printf '%s' "$SUBNET" | jq '{id:.id, "cidr-block":."cidr-block", "security-list-ids":."security-list-ids", "route-table-id":."route-table-id", "prohibit-public-ip-on-vnic":."prohibit-public-ip-on-vnic", "dns-label":."dns-label"}'

    echo
    echo "  VCN:"
    printf '%s' "$VCN" | jq '{id:.id, "cidr-blocks":."cidr-blocks", "dns-label":."dns-label", "display-name":."display-name"}'

    RT_ID="$(printf '%s' "$SUBNET" | jq -r '."route-table-id"')"
    if [[ "$RT_ID" != "null" && -n "$RT_ID" ]]; then
      echo
      echo "  Route Table:"
      RT="$(fetch_rt "$RT_ID")"
      printf '%s' "$RT" | jq '{id:.id, "display-name":."display-name", "route-rules":."route-rules"}'
    fi

    echo
    echo "  Security Lists (Subnet-level):"
    printf '%s' "$SUBNET" | jq -r '."security-list-ids"[]?' | while read -r SL_ID; do
      SL="$(fetch_seclist "$SL_ID")"
      echo "    - Security List: $SL_ID"
      printf '%s' "$SL" | jq '{id:.id, "display-name":."display-name"}'
      echo "      Ingress Rules:"
      printf '%s' "$SL" | jq '
        (."ingress-security-rules" // []) |
        map({
          desc:(.description // ""),
          src:(.source // .["source-type"]),
          proto:.protocol,
          tcp:."tcp-options",
          udp:."udp-options",
          icmp:."icmp-options",
          isStateless:.isStateless
        })
      '
      echo "      Egress Rules:"
      printf '%s' "$SL" | jq '
        (."egress-security-rules" // []) |
        map({
          desc:(.description // ""),
          dst:(.destination // .["destination-type"]),
          proto:.protocol,
          tcp:."tcp-options",
          udp:."udp-options",
          icmp:."icmp-options",
          isStateless:.isStateless
        })
      '

      echo "      ⚠ ICMP visibility check (basic):"
      printf '%s' "$SL" | jq '
        {
          any_icmp_ingress: ( (."ingress-security-rules" // []) | any(.protocol=="1") ),
          echo_request_rule: ( (."ingress-security-rules" // []) | any(.protocol=="1" and (."icmp-options".type==8 or (."icmp-options"==null))) ),
          echo_reply_rule:   ( (."ingress-security-rules" // []) | any(.protocol=="1" and (."icmp-options".type==0 or (."icmp-options"==null))) ),
          pmtu_rule_present: ( (."ingress-security-rules" // []) | any(.protocol=="1" and (."icmp-options".type==3 and (."icmp-options".code==4 or (."icmp-options".code==null)))) )
        }
      '
    done

    # NSGs on this VNIC
    NSG_IDS_JSON="$(printf '%s' "$VNIC" | jq -c '."nsg-ids" // []')"
    if [[ "$(printf '%s' "$NSG_IDS_JSON" | jq 'length')" -gt 0 ]]; then
      echo
      echo "  NSGs on VNIC:"
      printf '%s' "$NSG_IDS_JSON" | jq -r '.[]' | while read -r NSG_ID; do
        NSG="$(fetch_nsg "$NSG_ID")"
        echo "    - NSG: $NSG_ID"
        printf '%s' "$NSG" | jq '{id:.id, "display-name":."display-name"}'
        echo "      NSG Ingress Rules:"
        NSG_RULES_JSON="$(list_nsg_rules "$NSG_ID")"
        printf '%s' "$NSG_RULES_JSON" | jq '[ .[] | select(.direction=="INGRESS") ]'
        echo "      NSG Egress Rules:"
        printf '%s' "$NSG_RULES_JSON" | jq '[ .[] | select(.direction=="EGRESS") ]'

        echo "      ⚠ ICMP visibility check (basic):"
        printf '%s' "$NSG_RULES_JSON" | jq '
          {
            any_icmp_ingress: ( any(.direction=="INGRESS" and .protocol=="1") ),
            echo_request_rule: ( any(.direction=="INGRESS" and .protocol=="1" and (."icmp-options".type==8 or (."icmp-options"==null))) ),
            echo_reply_rule:   ( any(.direction=="INGRESS" and .protocol=="1" and (."icmp-options".type==0 or (."icmp-options"==null))) ),
            pmtu_rule_present: ( any(.direction=="INGRESS" and .protocol=="1" and (."icmp-options".type==3 and (.["icmp-options"].code==4 or (.["icmp-options"].code==null)))) )
          }
        '
      done
    else
      echo
      echo "  NSGs on VNIC: (none)"
    fi

    echo
    echo "  DRG Attachments (for this VCN):"
    list_drg_attachments_for_vcn "$VCN_ID" | jq -r '.'

    echo
    echo "  Local Peering Gateways (for this VCN):"
    list_local_peering_gateways_for_vcn "$VCN_ID" | jq -r '.'
  done
done

