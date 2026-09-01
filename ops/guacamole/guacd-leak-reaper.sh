#!/usr/bin/env bash
# Reaps leaked guacd connection children on the Guacamole portal host.
#
# When an RDP connection dies uncleanly, guacd sometimes fails to tear down the
# forked child that was serving it. The child keeps spinning on the dead socket
# (wchan __skb_wait_for_more_packets / futex_wait_queue) and burns 25-100% of a
# core forever. Enough of them starve the box, new RDP connections cannot be
# serviced in time, they abort, Guacamole retries, and users get stuck on the
# Windows "Welcome" spinner while sessions thrash. Observed 2026-09-01: six
# leaked children, ~5 cores of demand on a 4-core host, 0% idle.
#
# Run via systemd timer on the portal host. Needs ss, logger, curl, jq.
set -euo pipefail

# --- pure decision logic (no I/O; sourced by the test harness) ------------
# decide RDP_CONNS CPU_PCT AGE_SECS CPU_THRESHOLD MIN_AGE_SECS
# Prints exactly one action: keep | reap
#
#   RDP_CONNS > 0                      -> keep  (serving a live session)
#   AGE_SECS  < MIN_AGE_SECS           -> keep  (grace; may be mid-handshake)
#   CPU_PCT   < CPU_THRESHOLD          -> keep  (idle orphan, harmless)
#   otherwise                          -> reap  (spinning with no session)
decide() {
  local conns="$1" cpu="$2" age="$3" cpu_thresh="$4" min_age="$5"
  if [ "$conns" -gt 0 ]; then echo "keep"; return; fi
  if [ "$age" -lt "$min_age" ]; then echo "keep"; return; fi
  # CPU_PCT is fractional, so compare in awk rather than bash integer math.
  if awk -v c="$cpu" -v t="$cpu_thresh" 'BEGIN { exit !(c < t) }'; then echo "keep"; return; fi
  echo "reap"
}

# cpu_pct PID SAMPLE_SECS -> percent of ONE core used over the sample window.
# Uses /proc jiffy deltas, not ps lifetime average: a child that worked hard an
# hour ago then went idle must not look like a spinner.
cpu_pct() {
  local pid="$1" secs="$2" t0 t1 hz
  hz=$(getconf CLK_TCK)
  t0=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || { echo "0.0"; return; }
  sleep "$secs"
  t1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || { echo "0.0"; return; }
  awk -v a="$t0" -v b="$t1" -v hz="$hz" -v s="$secs" \
    'BEGIN { printf "%.1f", ((b-a)/hz/s)*100 }'
}

# proc_age PID -> seconds since process start.
proc_age() {
  local pid="$1" starttime hz btime now_s proc_start
  hz=$(getconf CLK_TCK)
  starttime=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null) || { echo "0"; return; }
  btime=$(awk '/^btime/ {print $2}' /proc/stat)
  now_s=$(date +%s)
  proc_start=$(( btime + starttime / hz ))
  echo "$(( now_s - proc_start ))"
}

# rdp_conns PID -> count of established outbound connections to RDP_PORT.
rdp_conns() {
  local pid="$1"
  ss -tnpH state established "( dport = :${RDP_PORT} )" 2>/dev/null \
    | grep -c "pid=${pid}," || true
}

# bs_notify SUMMARY DESC -> best-effort Better Stack incident (never fatal).
bs_notify() {
  local summary="$1" desc="$2"
  [ "${DRY_RUN:-0}" = "1" ] && { echo "[DRY_RUN] would notify: $summary" >&2; return 0; }
  [ -z "${BETTERSTACK_API_TOKEN:-}" ] && return 0
  curl -sf -X POST https://uptime.betterstack.com/api/v2/incidents \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg s "$summary" --arg d "$desc" --arg e "$REQUESTER_EMAIL" \
        --arg p "${BETTERSTACK_POLICY_ID:-}" \
        '{summary:$s,description:$d,requester_email:$e,call:false,sms:false,email:true}
         + (if $p == "" then {} else {policy_id:$p} end)')" >/dev/null || true
}

main() {
  SERVICE="${GUACD_SERVICE:-guacd.service}"
  RDP_PORT="${RDP_PORT:-3389}"
  CPU_THRESHOLD="${CPU_THRESHOLD:-20}"      # percent of one core
  MIN_AGE_SECS="${MIN_AGE_SECS:-120}"       # grace before a child is eligible
  SAMPLE_SECS="${SAMPLE_SECS:-3}"
  MAX_REAP="${MAX_REAP:-6}"                 # blast-radius cap per run
  TERM_GRACE="${TERM_GRACE:-5}"
  REQUESTER_EMAIL="${REQUESTER_EMAIL:-it@ameriglide.com}"
  DRY_RUN="${DRY_RUN:-0}"

  master=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
  if [ -z "$master" ] || [ "$master" = "0" ] || [ ! -d "/proc/$master" ]; then
    logger -t guacd-reaper "WARNING: cannot resolve $SERVICE MainPID; skipping run"
    echo "WARNING: cannot resolve $SERVICE MainPID; skipping run" >&2
    exit 0
  fi

  # Children of the master only. Never the master itself.
  children=$(pgrep -P "$master" -x guacd 2>/dev/null || true)
  if [ -z "$children" ]; then
    [ "$DRY_RUN" = "1" ] && echo "no guacd children under master $master"
    exit 0
  fi

  total=0; candidates=""
  for pid in $children; do
    [ "$pid" = "$master" ] && continue
    [ -d "/proc/$pid" ] || continue
    total=$(( total + 1 ))
    conns=$(rdp_conns "$pid")
    age=$(proc_age "$pid")
    cpu=$(cpu_pct "$pid" "$SAMPLE_SECS")
    action=$(decide "$conns" "$cpu" "$age" "$CPU_THRESHOLD" "$MIN_AGE_SECS")
    if [ "$DRY_RUN" = "1" ]; then
      printf '[DRY_RUN] pid=%s age=%ss cpu=%s%% rdp_conns=%s -> %s\n' \
        "$pid" "$age" "$cpu" "$conns" "$action"
    fi
    [ "$action" = "reap" ] && candidates="$candidates $cpu:$pid"
  done

  # shellcheck disable=SC2086  # intentional word-split: one "cpu:pid" per line for sort
  candidates=$(printf '%s\n' $candidates | sort -t: -k1 -rn || true)
  count=$(printf '%s' "$candidates" | grep -c . || true)
  [ "$count" -eq 0 ] && { [ "$DRY_RUN" = "1" ] && echo "nothing to reap"; exit 0; }

  # Safety valve: every child looks leaked. That is more likely the RDP target
  # being unreachable than a fleet of leaks. Cap the run and raise an incident
  # rather than mass-killing every session on the host.
  if [ "$count" -eq "$total" ] && [ "$total" -gt 1 ]; then
    logger -t guacd-reaper "WARNING: all $total guacd children look leaked; RDP target may be down. Reaping at most $MAX_REAP."
    bs_notify "Guacamole: all $total guacd children spinning" \
      "Every guacd child on the portal has no RDP connection and is burning CPU. This usually means the RDP target host is unreachable rather than a normal leak. Check sage-host before assuming a guacd bug."
  fi

  reaped=0
  for entry in $candidates; do
    [ "$reaped" -ge "$MAX_REAP" ] && { logger -t guacd-reaper "cap $MAX_REAP reached; $(( count - reaped )) left for next run"; break; }
    pid="${entry#*:}"; cpu="${entry%%:*}"
    # Re-verify at kill time: state may have changed during sampling.
    [ -d "/proc/$pid" ] || continue
    [ "$(cat /proc/"$pid"/comm 2>/dev/null)" = "guacd" ] || { logger -t guacd-reaper "BUG: pid $pid is not guacd; refusing"; continue; }
    [ "$(awk '{print $4}' /proc/"$pid"/stat 2>/dev/null)" = "$master" ] || { logger -t guacd-reaper "pid $pid no longer a child of $master; skipping"; continue; }
    if [ "$(rdp_conns "$pid")" -gt 0 ]; then
      logger -t guacd-reaper "pid $pid picked up a live RDP connection; sparing it"
      continue
    fi
    if [ "$DRY_RUN" = "1" ]; then echo "[DRY_RUN] would reap pid=$pid (cpu=${cpu}%)"; reaped=$(( reaped + 1 )); continue; fi
    kill -TERM "$pid" 2>/dev/null || true
    sleep "$TERM_GRACE"
    if [ -d "/proc/$pid" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
    logger -t guacd-reaper "reaped leaked guacd pid=$pid (cpu=${cpu}%, no RDP connection)"
    reaped=$(( reaped + 1 ))
  done

  [ "$reaped" -gt 0 ] && logger -t guacd-reaper "reaped $reaped of $total guacd children"
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
