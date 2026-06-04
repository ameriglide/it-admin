#!/usr/bin/env bash
# Unit tests for the pure decide() function. No docker/tailscale/network needed.
set -uo pipefail
set +e                                          # disable errexit before sourcing (sourced script sets -e)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/headscale-zombie-detector.sh"   # guarded: defines functions, runs nothing

fail=0
check() { # check DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"; fail=1
  fi
}

# decide PREV_FAILS ONLINE REACHABLE HAS_INCIDENT THRESHOLD -> action
check "online+reachable, no incident -> reset"        reset   "$(decide 0 true  true  false 2)"
check "online+reachable, has incident -> resolve"     resolve "$(decide 2 true  true  true  2)"
check "offline, no incident -> reset"                 reset   "$(decide 0 false false false 2)"
check "offline, has incident -> resolve"              resolve "$(decide 2 false false true  2)"
check "unreachable, prev0/thr2, no incident -> incr"  incr    "$(decide 0 true  false false 2)"
check "unreachable, prev1/thr2, no incident -> open"  open    "$(decide 1 true  false false 2)"
check "unreachable, has incident -> noop"             noop    "$(decide 2 true  false true  2)"
check "unreachable, prev0/thr1, no incident -> open"  open    "$(decide 0 true  false false 1)"

exit $fail
