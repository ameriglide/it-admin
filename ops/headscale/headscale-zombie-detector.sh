#!/usr/bin/env bash
# Flags tailnet nodes that are online in Headscale but whose last_seen is stale
# (a half-closed control connection), and raises/resolves a Better Stack incident
# per node. Run via systemd timer on the Headscale host. Needs docker, jq, curl.
set -euo pipefail

STALE_SECONDS="${STALE_SECONDS:-900}"
STATE_FILE="${STATE_FILE:-/var/lib/headscale-zombie-detector/state.json}"
CONTAINER="${HEADSCALE_CONTAINER:-headscale}"
REQUESTER_EMAIL="${REQUESTER_EMAIL:-it@ameriglide.com}"
# The API token spans multiple Better Stack teams, so incident creates must name
# the team explicitly or the API returns 422.
BETTERSTACK_TEAM_ID="${BETTERSTACK_TEAM_ID:-540247}"
DRY_RUN="${DRY_RUN:-0}"
: "${BETTERSTACK_API_TOKEN:?BETTERSTACK_API_TOKEN required}"

mkdir -p "$(dirname "$STATE_FILE")"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

now=$(date +%s)
nodes_json=$(docker exec "$CONTAINER" headscale nodes list -o json)

zombies=$(echo "$nodes_json" | jq -r --argjson now "$now" --argjson stale "$STALE_SECONDS" '
  def epoch:
    if (.last_seen | type) == "object" then (.last_seen.seconds // 0)
    elif (.last_seen | type) == "string" then (try (.last_seen | fromdateiso8601) catch 0)
    else 0 end;
  .[]
  | select(.online == true)
  | (epoch) as $ls
  | select($ls > 0 and ($now - $ls) > $stale)
  | .given_name')

state=$(cat "$STATE_FILE")
new_state="$state"

bs_create() {
  local node="$1"
  if [ "$DRY_RUN" = "1" ]; then echo "DRYRUN-$node"; return; fi
  local resp
  resp=$(curl -sf -X POST https://uptime.betterstack.com/api/v2/incidents \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"summary\":\"Tailnet zombie: $node\",\"description\":\"Node $node is online in Headscale but last_seen is stale (> ${STALE_SECONDS}s). Likely a half-closed Tailscale control connection. Restart the Tailscale service on $node.\",\"requester_email\":\"$REQUESTER_EMAIL\",\"call\":false,\"sms\":false,\"email\":true,\"better_stack_team_id\":$BETTERSTACK_TEAM_ID}") || { echo ""; return; }
  echo "$resp" | jq -r '.data.id // empty'
}

bs_resolve() {
  local id="$1"
  if [ "$DRY_RUN" = "1" ]; then echo "DRYRUN resolve $id"; return 0; fi
  curl -sf -X POST "https://uptime.betterstack.com/api/v2/incidents/${id}/resolve" \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" >/dev/null
}

# Open incidents for newly-zombied nodes.
# shellcheck disable=SC2086  # word-split on $zombies is intentional: newline-separated node names
for z in $zombies; do
  open_id=$(echo "$state" | jq -r --arg n "$z" '.[$n] // empty')
  if [ -z "$open_id" ]; then
    id=$(bs_create "$z")
    if [ -n "$id" ]; then
      new_state=$(echo "$new_state" | jq --arg n "$z" --arg id "$id" '.[$n]=$id')
      logger -t headscale-zombie "opened incident $id for $z"
    else
      logger -t headscale-zombie "WARNING: failed to open incident for $z (will retry next run)"
    fi
  fi
done

# Resolve incidents for recovered nodes.
for n in $(echo "$state" | jq -r 'keys[]'); do
  if ! echo "$zombies" | grep -qx "$n"; then
    id=$(echo "$state" | jq -r --arg n "$n" '.[$n]')
    if bs_resolve "$id"; then
      new_state=$(echo "$new_state" | jq --arg n "$n" 'del(.[$n])')
      logger -t headscale-zombie "resolved incident $id for $n"
    else
      logger -t headscale-zombie "WARNING: failed to resolve incident $id for $n (will retry)"
    fi
  fi
done

echo "$new_state" > "$STATE_FILE"
