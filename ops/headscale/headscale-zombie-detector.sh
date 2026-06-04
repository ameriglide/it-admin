#!/usr/bin/env bash
# Flags always-on tailnet nodes that Headscale reports online but that are
# actually unreachable (the zombie signature), and raises/resolves a Better
# Stack incident per node. Run via systemd timer on the Headscale host, which
# is itself a tailnet member. Needs docker, jq, curl, logger, tailscale.
set -euo pipefail

# --- pure decision logic (no I/O; sourced by the test harness) ------------
# decide PREV_FAILS ONLINE REACHABLE HAS_INCIDENT THRESHOLD
#   ONLINE/REACHABLE/HAS_INCIDENT are "true"/"false" strings.
#   REACHABLE is ignored when ONLINE != "true".
# Prints exactly one action: reset | resolve | incr | open | noop
#
#   ONLINE  REACHABLE  HAS_INCIDENT            -> ACTION
#   false   (ignored)  false                   -> reset
#   false   (ignored)  true                    -> resolve
#   true    true       false                   -> reset
#   true    true       true                    -> resolve
#   true    false      true                    -> noop
#   true    false      false  (fails+1<thresh) -> incr
#   true    false      false  (fails+1>=thresh)-> open
decide() {
  local prev_fails="$1" online="$2" reachable="$3" has_incident="$4" threshold="$5"
  if [ "$online" != "true" ]; then
    if [ "$has_incident" = "true" ]; then echo "resolve"; else echo "reset"; fi
    return
  fi
  if [ "$reachable" = "true" ]; then
    if [ "$has_incident" = "true" ]; then echo "resolve"; else echo "reset"; fi
    return
  fi
  # online and unreachable
  if [ "$has_incident" = "true" ]; then echo "noop"; return; fi
  if [ "$(( prev_fails + 1 ))" -ge "$threshold" ]; then echo "open"; else echo "incr"; fi
}

# probe_reachable IP -> exit 0 if any of PING_RETRIES tailscale pings pong.
# DERP-relayed replies count (--until-direct=false), so a working-but-relayed
# node is reachable.
probe_reachable() {
  local ip="$1" i
  for (( i=0; i<${PING_RETRIES:-3}; i++ )); do
    if tailscale ping -c 1 --timeout "${PING_TIMEOUT:-5s}" --until-direct=false "$ip" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# bs_create NODE CHECKS -> prints new incident id (empty on failure).
bs_create() {
  local node="$1" checks="$2" resp desc
  if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRYRUN-$node"; return; fi
  desc="Node $node is online in Headscale but unreachable via tailscale ping for $checks consecutive checks. Likely a half-closed Tailscale control connection. Restart the Tailscale service on $node or check the host."
  resp=$(curl -sf -X POST https://uptime.betterstack.com/api/v2/incidents \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg s "Tailnet zombie: $node" --arg d "$desc" --arg e "$REQUESTER_EMAIL" --arg p "$BETTERSTACK_POLICY_ID" \
        '{summary:$s,description:$d,requester_email:$e,call:false,sms:false,email:true}
         + (if $p == "" then {} else {policy_id:$p} end)')") \
    || { echo ""; return; }
  echo "$resp" | jq -r '.data.id // empty'
}

# bs_resolve ID -> exit 0 on success.
bs_resolve() {
  local id="$1"
  if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRYRUN resolve $id" >&2; return 0; fi
  curl -sf -X POST "https://uptime.betterstack.com/api/v2/incidents/${id}/resolve" \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" >/dev/null
}

main() {
  CONTAINER="${HEADSCALE_CONTAINER:-headscale}"
  STATE_FILE="${STATE_FILE:-/var/lib/headscale-zombie-detector/state.json}"
  THRESHOLD="${FAILS_THRESHOLD:-2}"
  REQUESTER_EMAIL="${REQUESTER_EMAIL:-it@ameriglide.com}"
  # Token is team-scoped, so incident creates must NOT pass a team id.
  BETTERSTACK_POLICY_ID="${BETTERSTACK_POLICY_ID:-}"
  DRY_RUN="${DRY_RUN:-0}"
  : "${MONITORED_NODES:?MONITORED_NODES required (space-separated given_names)}"
  if [ "$DRY_RUN" != "1" ]; then : "${BETTERSTACK_API_TOKEN:?BETTERSTACK_API_TOKEN required}"; fi

  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
  fi

  # Inventory. Fail safe on any error or unexpected shape.
  if ! nodes_json=$(docker exec "$CONTAINER" headscale nodes list -o json 2>/dev/null) \
      || ! echo "$nodes_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    logger -t headscale-zombie "WARNING: could not read headscale nodes list; skipping run"
    echo "WARNING: could not read headscale nodes list; skipping run" >&2
    exit 0
  fi

  state=$(cat "$STATE_FILE" 2>/dev/null) || true
  if ! printf '%s' "$state" | jq -e 'type=="object"' >/dev/null 2>&1; then
    if [ -n "$state" ]; then logger -t headscale-zombie "WARNING: state file invalid JSON; resetting to {}"; fi
    state='{}'
  fi

  # First pass: probe reachability for each monitored, online node.
  declare -A ONLINE REACHABLE
  online_count=0; reachable_count=0
  # shellcheck disable=SC2086  # intentional word-split: MONITORED_NODES is space-separated
  for node in $MONITORED_NODES; do
    row=$(echo "$nodes_json" | jq -c --arg n "$node" 'map(select(.given_name==$n)) | .[0] // empty')
    if [ -z "$row" ]; then
      ONLINE[$node]="absent"
      if [ "$DRY_RUN" = "1" ]; then echo "[DRY_RUN] $node: ABSENT (not in headscale)"; fi
      continue
    fi
    online=$(echo "$row" | jq -r '.online // false')
    ONLINE[$node]="$online"
    if [ "$online" = "true" ]; then
      online_count=$(( online_count + 1 ))
      ip=$(echo "$row" | jq -r '[.ip_addresses[] | select(test(":")|not)][0] // empty')
      if [ -n "$ip" ] && probe_reachable "$ip"; then
        REACHABLE[$node]="true"; reachable_count=$(( reachable_count + 1 ))
        if [ "$DRY_RUN" = "1" ]; then echo "[DRY_RUN] $node: online + REACHABLE ($ip) -> ok"; fi
      else
        REACHABLE[$node]="false"
        if [ "$DRY_RUN" = "1" ]; then echo "[DRY_RUN] $node: online + UNREACHABLE ($ip) -> suspect"; fi
      fi
    else
      if [ "$DRY_RUN" = "1" ]; then echo "[DRY_RUN] $node: offline ($online) -> skip"; fi
    fi
  done

  # Safety valve: monitored nodes are online but NONE are reachable -> assume
  # the host's own tailscale/DERP path is broken, not a fleet of zombies.
  if [ "$online_count" -gt 0 ] && [ "$reachable_count" -eq 0 ]; then
    logger -t headscale-zombie "WARNING: 0/$online_count online monitored nodes reachable; assuming local tailscale/DERP issue, skipping run"
    echo "WARNING: 0/$online_count online monitored nodes reachable; skipping run" >&2
    exit 0
  fi

  # Second pass: apply per-node decisions.
  new_state="$state"
  # shellcheck disable=SC2086  # intentional word-split: MONITORED_NODES is space-separated
  for node in $MONITORED_NODES; do
    [ "${ONLINE[$node]}" = "absent" ] && continue
    prev_fails=$(echo "$state" | jq -r --arg n "$node" '.[$n].fails // 0')
    incident=$(echo "$state" | jq -r --arg n "$node" '.[$n].incident // empty')
    if [ -n "$incident" ]; then has_incident="true"; else has_incident="false"; fi
    action=$(decide "$prev_fails" "${ONLINE[$node]}" "${REACHABLE[$node]:-false}" "$has_incident" "$THRESHOLD")
    next_fails=$(( prev_fails + 1 > THRESHOLD ? THRESHOLD : prev_fails + 1 ))
    case "$action" in
      reset)
        new_state=$(echo "$new_state" | jq --arg n "$node" '.[$n]={fails:0,incident:null}') ;;
      incr)
        new_state=$(echo "$new_state" | jq --arg n "$node" --argjson f "$next_fails" '.[$n]={fails:$f,incident:null}')
        logger -t headscale-zombie "unreachable $node ($next_fails/$THRESHOLD)" ;;
      open)
        id=$(bs_create "$node" "$next_fails")
        if [ -n "$id" ]; then
          new_state=$(echo "$new_state" | jq --arg n "$node" --argjson f "$next_fails" --arg id "$id" '.[$n]={fails:$f,incident:$id}')
          logger -t headscale-zombie "opened incident $id for $node (online in headscale, unreachable)"
        else
          new_state=$(echo "$new_state" | jq --arg n "$node" --argjson f "$next_fails" '.[$n]={fails:$f,incident:null}')
          logger -t headscale-zombie "WARNING: failed to open incident for $node (will retry)"
        fi ;;
      resolve)
        if bs_resolve "$incident"; then
          new_state=$(echo "$new_state" | jq --arg n "$node" '.[$n]={fails:0,incident:null}')
          logger -t headscale-zombie "resolved incident $incident for $node (recovered)"
        else
          logger -t headscale-zombie "WARNING: failed to resolve incident $incident for $node (will retry)"
        fi ;;
      noop) : ;;
      *) logger -t headscale-zombie "BUG: unknown action '$action' for $node" ;;
    esac
  done

  # Prune nodes no longer in MONITORED_NODES: resolve their incidents, drop them.
  # shellcheck disable=SC2086  # intentional word-split: MONITORED_NODES is space-separated
  for node in $(echo "$state" | jq -r 'keys[]'); do
    if ! printf '%s\n' $MONITORED_NODES | grep -qx "$node"; then
      incident=$(echo "$state" | jq -r --arg n "$node" '.[$n].incident // empty')
      [ -n "$incident" ] && { bs_resolve "$incident" || true; }
      new_state=$(echo "$new_state" | jq --arg n "$node" 'del(.[$n])')
    fi
  done

  if [ "$DRY_RUN" = "1" ]; then
    echo "[DRY_RUN] resulting state:"; echo "$new_state" | jq .
  else
    tmp=$(mktemp "${STATE_FILE}.XXXXXX") && printf '%s\n' "$new_state" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
