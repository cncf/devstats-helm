#!/bin/bash
for e in $NODE_INVENTORY; do
  name="${e%%:*}"; rest="${e#*:}"; vpc_ip="${rest%%:*}"; pg="${rest##*:}"
  [ "$pg" = "prod" ] && pgid="$PG_PROD_ID" || pgid="$PG_TC_ID"
  echo "creating $name ($vpc_ip, pg $pgid)..."
  echo "linode-cli linodes create --label \"$name\" --region \"$REGION\" --type \"$TYPE_256\" --image \"$IMAGE\" --root_pass \"$ROOT_PASS\" --authorized_keys \"$(cat $SSH_PUB_KEY_FILE)\" --private_ip false --backups_enabled false --placement_group.id \"$pgid\" --interfaces '[{\"purpose\":\"vpc\",\"subnet_id\":'\"$SUBNET_ID\"',\"primary\":true,\"ipv4\":{\"vpc\":\"'\"$vpc_ip\"'\",\"nat_1_1\":\"any\"}}]' --tags devstats --json | jq -r '.[0] | \"  id=\(.id) status=\(.status)\"'"
  # linode-cli linodes create --label "$name" --region "$REGION" --type "$TYPE_256" --image "$IMAGE" --root_pass "$ROOT_PASS" --authorized_keys "$(cat "$SSH_PUB_KEY_FILE")" --private_ip false --backups_enabled false --placement_group.id "$pgid" --interfaces '[{"purpose":"vpc","subnet_id":'"$SUBNET_ID"',"primary":true,"ipv4":{"vpc":"'"$vpc_ip"'","nat_1_1":"any"}}]' --tags devstats --json | jq -r '.[0] | "  id=\(.id) status=\(.status)"'
done
