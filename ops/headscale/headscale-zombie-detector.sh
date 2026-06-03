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

main() {
  CONTAINER="${HEADSCALE_CONTAINER:-headscale}"
  STATE_FILE="${STATE_FILE:-/var/lib/headscale-zombie-detector/state.json}"
  THRESHOLD="${FAILS_THRESHOLD:-2}"
  REQUESTER_EMAIL="${REQUESTER_EMAIL:-it@ameriglide.com}"
  BETTERSTACK_TEAM_ID="${BETTERSTACK_TEAM_ID:-540247}"
  DRY_RUN="${DRY_RUN:-0}"
  : "${MONITORED_NODES:?MONITORED_NODES required (space-separated given_names)}"
  if [ "$DRY_RUN" != "1" ]; then : "${BETTERSTACK_API_TOKEN:?BETTERSTACK_API_TOKEN required}"; fi

  mkdir -p "$(dirname "$STATE_FILE")"
  [ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

  # Inventory. Fail safe on any error or unexpected shape.
  if ! nodes_json=$(docker exec "$CONTAINER" headscale nodes list -o json 2>/dev/null) \
      || ! echo "$nodes_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
    logger -t headscale-zombie "WARNING: could not read headscale nodes list; skipping run"
    echo "WARNING: could not read headscale nodes list; skipping run" >&2
    exit 0
  fi

  state=$(cat "$STATE_FILE")

  # First pass: probe reachability for each monitored, online node.
  declare -A ONLINE REACHABLE
  online_count=0; reachable_count=0
  for node in $MONITORED_NODES; do
    row=$(echo "$nodes_json" | jq -c --arg n "$node" 'map(select(.given_name==$n)) | .[0] // empty')
    if [ -z "$row" ]; then ONLINE[$node]="absent"; continue; fi
    online=$(echo "$row" | jq -r '.online // false')
    ONLINE[$node]="$online"
    if [ "$online" = "true" ]; then
      online_count=$(( online_count + 1 ))
      ip=$(echo "$row" | jq -r '[.ip_addresses[] | select(test(":")|not)][0] // empty')
      if [ -n "$ip" ] && probe_reachable "$ip"; then
        REACHABLE[$node]="true"; reachable_count=$(( reachable_count + 1 ))
      else
        REACHABLE[$node]="false"
      fi
    fi
  done

  # Safety valve: monitored nodes are online but NONE are reachable -> assume
  # the host's own tailscale/DERP path is broken, not a fleet of zombies.
  if [ "$online_count" -gt 0 ] && [ "$reachable_count" -eq 0 ]; then
    logger -t headscale-zombie "WARNING: 0/$online_count online monitored nodes reachable; assuming local tailscale/DERP issue, skipping run"
    echo "WARNING: 0/$online_count online monitored nodes reachable; skipping run" >&2
    exit 0
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
