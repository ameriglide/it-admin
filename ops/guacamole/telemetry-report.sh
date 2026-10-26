#!/usr/bin/env bash
# Summarises AG-1356 client tunnel telemetry from Tomcat's access logs.
# Run on the portal host:  sudo telemetry-report.sh [YYYY-MM-DD]   (default: today, UTC)
#
# One row per browser event, oldest first:
#   time(UTC, client clock)  connection  event  by(page|net)  code  rg  sg  vis  hidden  online  conn-type
# rg/sg = ms since the browser last received/sent tunnel data (for by=page,
# rg is measured when the page called close(): >= 15000 means Guacamole's
# receive timeout fired, i.e. data stopped arriving).
set -euo pipefail

DAY="${1:-$(date -u +%F)}"
LOG="/opt/tomcat/logs/localhost_access_log.${DAY}.txt"
[ -r "$LOG" ] || { echo "no access log for $DAY ($LOG)" >&2; exit 1; }

# connection_id -> connection name, so rows read as people, not numbers
declare -A NAME
while IFS='|' read -r id name; do NAME[$id]="$name"; done < <(
  cd /tmp && sudo -u postgres psql -d guacamole_db -At -c \
    "select connection_id, connection_name from guacamole_connection")

grep -o 'GET /telemetry/ws.gif?[^ ]*' "$LOG" | sed 's/^GET \/telemetry\/ws.gif?//' | while read -r qs; do
  declare -A f=()
  IFS='&' read -ra kv <<<"$qs"
  for p in "${kv[@]}"; do f[${p%%=*}]="${p#*=}"; done
  ts=$(date -u -d "@$(( ${f[t]:-0} / 1000 ))" +%T)
  name="${NAME[${f[cid]:-}]:-${f[cid]:--}}"
  printf '%s  %-32s %-7s %-4s %-5s rg=%-7s sg=%-7s vis=%s hid=%-8s on=%s %s\n' \
    "$ts" "${name#Sage 100 - }" "${f[e]:-}" "${f[by]:--}" "${f[code]:--}" \
    "${f[rg]:--}" "${f[sg]:--}" "${f[vis]:-}" "${f[hid]:-}" "${f[on]:-}" "${f[ct]:-}"
  unset f
done | sort
