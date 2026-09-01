#!/usr/bin/env bash
# Unit tests for the pure decide() function. No /proc, ss, or network needed,
# so this runs on a laptop as well as on the portal host.
set -uo pipefail
set +e                                        # disable errexit before sourcing (sourced script sets -e)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/guacd-leak-reaper.sh"           # guarded: defines functions, runs nothing

fail=0
check() { # check DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1 (expected '$2', got '$3')"; fail=1
  fi
}

# decide RDP_CONNS CPU_PCT AGE_SECS CPU_THRESHOLD MIN_AGE_SECS -> keep|reap
# Thresholds below mirror the defaults: CPU 20%, min age 120s.

# A live session is never touched, however much CPU it uses.
check "serving a session, idle cpu            -> keep" keep "$(decide 1 0.2   3600 20 120)"
check "serving a session, heavy cpu           -> keep" keep "$(decide 1 95.0  3600 20 120)"
check "serving several sessions               -> keep" keep "$(decide 4 60.0  3600 20 120)"

# Young children get a grace period: they may still be handshaking.
check "no session, spinning, but only 5s old  -> keep" keep "$(decide 0 90.0  5    20 120)"
check "no session, spinning, 119s old         -> keep" keep "$(decide 0 90.0  119  20 120)"
check "no session, spinning, exactly 120s     -> reap" reap "$(decide 0 90.0  120  20 120)"

# Idle orphans are harmless; only the spinners are worth killing.
check "no session, 0.1% cpu, old              -> keep" keep "$(decide 0 0.1   3600 20 120)"
check "no session, 19.9% cpu (under thresh)   -> keep" keep "$(decide 0 19.9  3600 20 120)"
check "no session, 20.0% cpu (at thresh)      -> reap" reap "$(decide 0 20.0  3600 20 120)"

# The real observed leaks from 2026-09-01.
check "leak 69031: 57.6% cpu, 59m, no conn    -> reap" reap "$(decide 0 57.6  3540 20 120)"
check "leak 69107: 58.1% cpu, 58m, no conn    -> reap" reap "$(decide 0 58.1  3494 20 120)"
check "healthy 71781: 0.2% cpu, 16m, 1 conn   -> keep" keep "$(decide 1 0.2   986  20 120)"

# Threshold is configurable.
check "no session, 10% cpu, thresh 5          -> reap" reap "$(decide 0 10.0  3600 5  120)"
check "no session, 10% cpu, thresh 50         -> keep" keep "$(decide 0 10.0  3600 50 120)"

exit $fail
