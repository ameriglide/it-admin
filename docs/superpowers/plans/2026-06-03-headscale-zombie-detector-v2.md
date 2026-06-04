# Headscale Zombie Detector v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the invalid `online + stale last_seen` zombie heuristic with active `tailscale ping` reachability probing from the Headscale host, scoped to an always-on allowlist, debounced over 2 runs.

**Architecture:** A single bash script on the Headscale host (run by the existing 5-min systemd timer) reads the node inventory from `headscale nodes list -o json`, probes each always-on node with `tailscale ping`, and raises/resolves a Better Stack incident per node. The debounce/lifecycle logic is a pure, unit-tested function; docker/tailscale/curl are isolated in thin wrappers. A safety valve suppresses all action when the host's own tailscale path looks broken.

**Tech Stack:** bash 5.x, jq, curl, tailscale CLI, docker, systemd, Better Stack Incidents API. Tests are a plain bash assertion script (no bats).

---

## File Structure

- **Modify (rewrite):** `ops/headscale/headscale-zombie-detector.sh` — detector. Top-level defines the pure `decide()` plus thin I/O wrappers (`probe_reachable`, `bs_create`, `bs_resolve`) and `main`; guarded so sourcing defines functions without running `main`.
- **Create:** `ops/headscale/test-headscale-zombie-detector.sh` — sources the script and asserts the `decide()` decision table.
- **Modify:** `ops/headscale/README.md` — v2 install/config/test instructions.
- **Unchanged:** `ops/headscale/headscale-zombie-detector.service`, `headscale-zombie-detector.timer` (still a oneshot on a 5-min timer).
- **Host-only (not in repo):** `/etc/headscale-zombie-detector.env` — add `MONITORED_NODES`, `FAILS_THRESHOLD`; remove `STALE_SECONDS`.

---

## Task 1: Pure decision function + tests

**Files:**
- Create: `ops/headscale/headscale-zombie-detector.sh` (start fresh; full script lands across Tasks 1–4)
- Test: `ops/headscale/test-headscale-zombie-detector.sh`

- [ ] **Step 1: Write the failing test**

Create `ops/headscale/test-headscale-zombie-detector.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for the pure decide() function. No docker/tailscale/network needed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/headscale-zombie-detector.sh"   # guarded: defines functions, runs nothing
set +e                                          # sourced script enables -e; tests need it off

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ops/headscale/test-headscale-zombie-detector.sh`
Expected: FAIL — `headscale-zombie-detector.sh` does not exist yet (`source: No such file`), or `decide: command not found`.

- [ ] **Step 3: Write minimal implementation**

Create `ops/headscale/headscale-zombie-detector.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ops/headscale/test-headscale-zombie-detector.sh`
Expected: 8 `ok` lines, exit 0. (`main` is referenced only inside the guard, which does not run when sourced, so the missing `main` does not break the test.)

- [ ] **Step 5: Commit**

```bash
chmod +x ops/headscale/headscale-zombie-detector.sh ops/headscale/test-headscale-zombie-detector.sh
git add ops/headscale/headscale-zombie-detector.sh ops/headscale/test-headscale-zombie-detector.sh
git commit -m "feat(headscale): pure decide() for v2 reachability detector + tests"
```

---

## Task 2: Reachability probe + node inventory + safety valve

**Files:**
- Modify: `ops/headscale/headscale-zombie-detector.sh` (add `probe_reachable` and the first half of `main`)

- [ ] **Step 1: Add the probe wrapper**

Insert `probe_reachable` after the `decide()` function (before the bottom guard):

```bash
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
```

- [ ] **Step 2: Add `main` config + inventory + first pass + safety valve**

Insert this `main()` definition after `probe_reachable` (the second pass/state write is added in Task 3 — for now `main` ends after the safety valve and writes nothing):

```bash
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
```

- [ ] **Step 3: Verify the unit tests still pass (logic unchanged)**

Run: `bash ops/headscale/test-headscale-zombie-detector.sh`
Expected: 8 `ok` lines, exit 0.

- [ ] **Step 4: Lint**

Run: `shellcheck ops/headscale/headscale-zombie-detector.sh`
Expected: no errors. (Acceptable to ignore `SC2034` on associative arrays consumed in Task 3; if it appears, leave it — Task 3 uses them.)

- [ ] **Step 5: Commit**

```bash
git add ops/headscale/headscale-zombie-detector.sh
git commit -m "feat(headscale): node inventory, tailscale-ping probe, safety valve"
```

---

## Task 3: Incident lifecycle + state apply + pruning

**Files:**
- Modify: `ops/headscale/headscale-zombie-detector.sh` (add Better Stack wrappers; extend `main` with the second pass, pruning, state write)

- [ ] **Step 1: Add the Better Stack wrappers**

Insert after `probe_reachable` (before `main`):

```bash
# bs_create NODE CHECKS -> prints new incident id (empty on failure).
bs_create() {
  local node="$1" checks="$2" resp desc
  if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRYRUN-$node"; return; fi
  desc="Node $node is online in Headscale but unreachable via tailscale ping for $checks consecutive checks. Likely a half-closed Tailscale control connection. Restart the Tailscale service on $node or check the host."
  resp=$(curl -sf -X POST https://uptime.betterstack.com/api/v2/incidents \
    -H "Authorization: Bearer $BETTERSTACK_API_TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg s "Tailnet zombie: $node" --arg d "$desc" --arg e "$REQUESTER_EMAIL" --argjson t "$BETTERSTACK_TEAM_ID" \
        '{summary:$s,description:$d,requester_email:$e,call:false,sms:false,email:true,better_stack_team_id:$t}')") \
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
```

- [ ] **Step 2: Extend `main` with the second pass, pruning, and state write**

Append the following INSIDE `main()`, immediately after the safety-valve block (before `main`'s closing `}`):

```bash
  # Second pass: apply per-node decisions.
  new_state="$state"
  for node in $MONITORED_NODES; do
    [ "${ONLINE[$node]}" = "absent" ] && continue
    prev_fails=$(echo "$state" | jq -r --arg n "$node" '.[$n].fails // 0')
    incident=$(echo "$state" | jq -r --arg n "$node" '.[$n].incident // empty')
    if [ -n "$incident" ]; then has_incident="true"; else has_incident="false"; fi
    action=$(decide "$prev_fails" "${ONLINE[$node]}" "${REACHABLE[$node]:-false}" "$has_incident" "$THRESHOLD")
    next_fails=$(( prev_fails + 1 ))
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
    esac
  done

  # Prune nodes no longer in MONITORED_NODES: resolve their incidents, drop them.
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
    echo "$new_state" > "$STATE_FILE"
  fi
```

- [ ] **Step 3: Verify the unit tests still pass**

Run: `bash ops/headscale/test-headscale-zombie-detector.sh`
Expected: 8 `ok` lines, exit 0.

- [ ] **Step 4: Lint**

Run: `shellcheck ops/headscale/headscale-zombie-detector.sh`
Expected: no errors. The intentional word-split on `$MONITORED_NODES` (config, space-separated) may raise `SC2086`; add `# shellcheck disable=SC2086` on the two `for node in $MONITORED_NODES` lines and the `printf '%s\n' $MONITORED_NODES` line with a brief reason comment.

- [ ] **Step 5: Commit**

```bash
git add ops/headscale/headscale-zombie-detector.sh
git commit -m "feat(headscale): Better Stack incident lifecycle, state apply, pruning"
```

---

## Task 4: DRY_RUN classification output

**Files:**
- Modify: `ops/headscale/headscale-zombie-detector.sh` (add a per-node classification line during DRY_RUN in the first pass)

- [ ] **Step 1: Add classification logging in the first pass**

In `main`'s first-pass loop, replace the reachability assignment block with one that prints a line under DRY_RUN. The loop body becomes:

```bash
  for node in $MONITORED_NODES; do
    row=$(echo "$nodes_json" | jq -c --arg n "$node" 'map(select(.given_name==$n)) | .[0] // empty')
    if [ -z "$row" ]; then
      ONLINE[$node]="absent"
      [ "$DRY_RUN" = "1" ] && echo "[DRY_RUN] $node: ABSENT (not in headscale)"
      continue
    fi
    online=$(echo "$row" | jq -r '.online // false')
    ONLINE[$node]="$online"
    if [ "$online" = "true" ]; then
      online_count=$(( online_count + 1 ))
      ip=$(echo "$row" | jq -r '[.ip_addresses[] | select(test(":")|not)][0] // empty')
      if [ -n "$ip" ] && probe_reachable "$ip"; then
        REACHABLE[$node]="true"; reachable_count=$(( reachable_count + 1 ))
        [ "$DRY_RUN" = "1" ] && echo "[DRY_RUN] $node: online + REACHABLE ($ip) -> ok"
      else
        REACHABLE[$node]="false"
        [ "$DRY_RUN" = "1" ] && echo "[DRY_RUN] $node: online + UNREACHABLE ($ip) -> suspect"
      fi
    else
      [ "$DRY_RUN" = "1" ] && echo "[DRY_RUN] $node: offline ($online) -> skip"
    fi
  done
```

- [ ] **Step 2: Verify the unit tests still pass**

Run: `bash ops/headscale/test-headscale-zombie-detector.sh`
Expected: 8 `ok` lines, exit 0.

- [ ] **Step 3: Lint**

Run: `shellcheck ops/headscale/headscale-zombie-detector.sh`
Expected: no new errors.

- [ ] **Step 4: Commit**

```bash
git add ops/headscale/headscale-zombie-detector.sh
git commit -m "feat(headscale): DRY_RUN per-node classification output"
```

---

## Task 5: README + verify full script end-to-end locally

**Files:**
- Modify: `ops/headscale/README.md`

- [ ] **Step 1: Rewrite the README**

Replace the entire contents of `ops/headscale/README.md` with:

````markdown
# Headscale zombie-node detector (v2, active reachability)

Flags **always-on** nodes that Headscale reports `online=true` but that are
actually **unreachable** via `tailscale ping` from the Headscale host -- the
signature of a half-closed Tailscale control connection -- and raises a Better
Stack incident per node, auto-resolving on recovery.

Why active probing: on Headscale v0.28 `last_seen` is not a keepalive (it
freezes for stably-connected nodes) and `online` is sticky on interrupted
connections, so "online + stale last_seen" produced ~92% false positives. The
Headscale host is itself a tailnet member, so it probes nodes directly. See
`docs/superpowers/specs/2026-06-03-headscale-zombie-detector-v2-design.md`.

Scope is **always-on infrastructure only** (servers/routers/PBX), listed in
`MONITORED_NODES`. Workstations are covered by the per-node self-heal watchdog
(AMG-409) and are intentionally not probed (they sleep/suspend normally).

## Install (on the Headscale host)

```bash
sudo mkdir -p /opt/headscale-zombie-detector
sudo cp headscale-zombie-detector.sh /opt/headscale-zombie-detector/
sudo chmod +x /opt/headscale-zombie-detector/headscale-zombie-detector.sh
sudo cp headscale-zombie-detector.service headscale-zombie-detector.timer /etc/systemd/system/

# Secrets / config (not committed):
sudo tee /etc/headscale-zombie-detector.env >/dev/null <<'EOF'
BETTERSTACK_API_TOKEN=...
BETTERSTACK_TEAM_ID=540247
REQUESTER_EMAIL=it@ameriglide.com
HEADSCALE_CONTAINER=headscale
FAILS_THRESHOLD=2
MONITORED_NODES=web phenix headscale db sage-amg sage-iai sage-server amg-bjx iai-bjx tailscale-router-b asterisk-pbx asterisk-pbx-nyc3 amg-blog youtrack
EOF
sudo chmod 600 /etc/headscale-zombie-detector.env

sudo systemctl daemon-reload
sudo systemctl enable --now headscale-zombie-detector.timer
```

`MONITORED_NODES` is a space-separated list of Headscale `given_name`s. Edit it
when always-on infrastructure is added or removed; nodes dropped from the list
have any open incident auto-resolved on the next run.

## Test

```bash
# Unit-test the decision logic (no network needed):
bash test-headscale-zombie-detector.sh

# Read-only classification on the host (real pings, no incidents, no state write):
sudo DRY_RUN=1 \
  MONITORED_NODES="web phenix headscale db sage-amg sage-iai sage-server amg-bjx iai-bjx tailscale-router-b asterisk-pbx asterisk-pbx-nyc3 amg-blog youtrack" \
  /opt/headscale-zombie-detector/headscale-zombie-detector.sh
```

Expect each monitored node printed as `REACHABLE -> ok`, `UNREACHABLE -> suspect`,
`offline -> skip`, or `ABSENT`. A normally-running fleet shows everything `ok`
or `skip`. Then run once for real
(`sudo systemctl start headscale-zombie-detector.service`) and check
`journalctl -t headscale-zombie`.

## How it decides

Per run, for each monitored node: `online=false` -> reset (powered off is the
heartbeat's job, not this detector's); `online=true` + reachable -> reset /
resolve; `online=true` + unreachable for `FAILS_THRESHOLD` (2) consecutive runs
-> open incident. Safety valve: if some monitored nodes are online but **none**
are reachable, the run assumes the host's own tailscale/DERP path is broken and
does nothing.
````

- [ ] **Step 2: Final local verification (unit tests + lint)**

Run: `bash ops/headscale/test-headscale-zombie-detector.sh && shellcheck ops/headscale/headscale-zombie-detector.sh ops/headscale/test-headscale-zombie-detector.sh`
Expected: 8 `ok` lines, then no shellcheck errors.

- [ ] **Step 3: Commit**

```bash
git add ops/headscale/README.md
git commit -m "docs(headscale): v2 README (active reachability, allowlist, dry-run)"
```

---

## Task 6: Deploy to the Headscale host + dry-run verify + enable

**Files:** none in repo (host operations). Run from the repo root; `ssh headscale` reaches the host as root.

- [ ] **Step 1: Copy the updated script + test to the host**

```bash
scp -q ops/headscale/headscale-zombie-detector.sh ops/headscale/test-headscale-zombie-detector.sh headscale:/opt/headscale-zombie-detector/
ssh headscale 'chmod +x /opt/headscale-zombie-detector/headscale-zombie-detector.sh /opt/headscale-zombie-detector/test-headscale-zombie-detector.sh'
```

- [ ] **Step 2: Run the unit tests on the host**

```bash
ssh headscale 'bash /opt/headscale-zombie-detector/test-headscale-zombie-detector.sh'
```
Expected: 8 `ok` lines, exit 0.

- [ ] **Step 3: Update the env file (add MONITORED_NODES + FAILS_THRESHOLD, remove STALE_SECONDS)**

Rewrite the env file preserving the existing token. Run from the repo root (token read from local `.env`, never echoed):

```bash
tok=$(grep -E '^BETTERSTACK_API_TOKEN=' .env | head -1 | cut -d= -f2-)
printf 'BETTERSTACK_API_TOKEN=%s\nBETTERSTACK_TEAM_ID=540247\nREQUESTER_EMAIL=it@ameriglide.com\nHEADSCALE_CONTAINER=headscale\nFAILS_THRESHOLD=2\nMONITORED_NODES=web phenix headscale db sage-amg sage-iai sage-server amg-bjx iai-bjx tailscale-router-b asterisk-pbx asterisk-pbx-nyc3 amg-blog youtrack\n' "$tok" \
  | ssh headscale 'umask 077; cat > /etc/headscale-zombie-detector.env && chmod 600 /etc/headscale-zombie-detector.env'
ssh headscale 'sed -E "s/=.*/=<set>/" /etc/headscale-zombie-detector.env'
```
Expected: 6 keys printed with `<set>` values; `STALE_SECONDS` absent.

- [ ] **Step 4: Dry-run classification on the host**

```bash
ssh headscale 'set -a; . /etc/headscale-zombie-detector.env; set +a; DRY_RUN=1 /opt/headscale-zombie-detector/headscale-zombie-detector.sh'
```
Expected: one `[DRY_RUN] <node>: ...` line per monitored node (`ok`/`suspect`/`skip`/`ABSENT`), a `[DRY_RUN] resulting state:` block, no incidents opened, and the real state file unchanged (none written under DRY_RUN). Sanity-check that healthy servers (`web`, `db`, `sage-amg`, ...) read `REACHABLE -> ok`.

- [ ] **Step 5: Run once for real, then check the log**

```bash
ssh headscale 'systemctl start headscale-zombie-detector.service; sleep 2; journalctl -t headscale-zombie --since "2 min ago" --no-pager | tail -20; echo "--- state ---"; cat /var/lib/headscale-zombie-detector/state.json 2>/dev/null | jq .'
```
Expected: no `opened incident` lines for healthy nodes; state shows `fails:0` for reachable nodes. (A node that is genuinely online-but-unreachable will show `unreachable <node> (1/2)` on the first run and only open an incident on the second run ~5 min later — that is correct debounce behavior.)

- [ ] **Step 6: Enable the timer**

```bash
ssh headscale 'systemctl enable --now headscale-zombie-detector.timer; systemctl status headscale-zombie-detector.timer --no-pager | head -5; systemctl list-timers headscale-zombie-detector.timer --no-pager'
```
Expected: timer `enabled` and `active (waiting)`, next run scheduled ~5 min out.

- [ ] **Step 7: Confirm clean for ~10–15 min (let debounce settle)**

```bash
ssh headscale 'journalctl -t headscale-zombie --since "15 min ago" --no-pager | tail -30; echo "--- open incidents in state ---"; jq "to_entries | map(select(.value.incident != null)) | from_entries" /var/lib/headscale-zombie-detector/state.json'
```
Expected: no unexpected incidents. Investigate any node that opened one (it is genuinely online-in-headscale-but-unreachable — a real finding to chase, e.g. `adams-lenovo7400`/`narwhal` from the investigation, if still in that state and on the allowlist — note they are NOT on the allowlist, so they will not alert).

---

## Task 7: Verify AMG-397 escalation routing + close out

**Files:** none (Better Stack + Linear).

- [ ] **Step 1: Confirm incidents route through the AMG-397 escalation policy**

Use the Better Stack MCP/UI to confirm the escalation policy from AMG-397 applies to incidents created by this detector (created via the Incidents API with `better_stack_team_id=540247`). If incident routing is policy-driven by team/source rather than per-incident, verify the team's default policy is the AMG-397 one; otherwise note the gap on AMG-410 for follow-up.

- [ ] **Step 2: Update Linear AMG-410**

Post a comment summarizing: v1 premise invalidated on v0.28 (evidence), v2 active-reachability detector built + deployed, allowlist of 14 always-on nodes via `MONITORED_NODES`, timer enabled, dry-run/real-run results. Move to In Review or Done per the team's flow.

- [ ] **Step 3: Update mem0**

Update the existing AMG-410 mem0 memory to record that v2 is deployed and live (supersede the "do not enable" note with "v2 active-reachability detector deployed; v1 premise was invalid on v0.28").

- [ ] **Step 4: Open the branch PR**

```bash
git push -u origin chore/amg-410-deploy-zombie-detector
gh pr create --fill --base main
```

---

## Self-Review

**Spec coverage:** active-reachability probe (Tasks 2,4) ✓; always-on env-var allowlist (Tasks 2,3,5,6) ✓; 2-run debounce via `decide` (Task 1) ✓; drop `last_seen` (Task 1, no last_seen anywhere) ✓; safety valve (Task 2) ✓; state schema (Task 3) ✓; error handling / fail-safe inventory + create/resolve retry (Tasks 2,3) ✓; incident content (Task 3) ✓; DRY_RUN read-only (Tasks 3,4 — bs_* short-circuit, no state write) ✓; pure-function + dry-run testability (Tasks 1,4,5) ✓; env config changes (Tasks 5,6) ✓; AMG-397 routing (Task 7) ✓.

**Placeholder scan:** all code steps contain full code; commands have expected output. No TBD/TODO.

**Type/name consistency:** `decide` signature `(prev_fails, online, reachable, has_incident, threshold)` and outputs `reset|resolve|incr|open|noop` are identical across Tasks 1 and 3. `probe_reachable`, `bs_create NODE CHECKS`, `bs_resolve ID`, env var names (`MONITORED_NODES`, `FAILS_THRESHOLD`, `HEADSCALE_CONTAINER`, `BETTERSTACK_TEAM_ID`, `REQUESTER_EMAIL`, `BETTERSTACK_API_TOKEN`), and state shape `{fails, incident}` are consistent across tasks and the env file.
