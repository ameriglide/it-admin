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

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
