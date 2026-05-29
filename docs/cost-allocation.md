# DigitalOcean cost allocation

Splits the single DigitalOcean invoice across the businesses sharing the account
(**AmeriGlide**, **Internet Alliance**, **ATC Distributors**) for chargeback —
**without changing anything operationally**.

## How it works

DigitalOcean Projects are a purely organizational layer (moving a resource between
projects causes no downtime or IP change), and the monthly invoice CSV carries a
`project_name` column. So every billable resource is assigned to an entity-named
project, and each month we pivot the invoice by project and split the shared bucket.

### Projects (cost centers)

| Project | ID | Entity |
|---|---|---|
| AmeriGlide | `43613fb8-b04a-4ef1-aeb4-24d75b1e1116` | AMG |
| Internet Alliance | `e378a71d-d07f-473a-abb7-0550d5277739` | IAI |
| Shared Infrastructure | `ba650855-0e7e-4c42-917d-3029a19e481b` | SHARED (split by ratio) |
| ATC Distributors | `ddea8264-c2f8-48a3-b0f6-8fc5484861a5` | ATC (rolled into IAI for now) |

`AmeriGlide` was the renamed former `AmeriGlide CRM` project; the others are new.
Resources were reassigned via `doctl projects resources assign`. The k8s-managed
load balancers and PVC volumes roll up under the `phenix` cluster (AmeriGlide), so
they don't appear as standalone project entries — that's expected.

## Configuration

- `src/cost-allocation/resource-map.json` — ordered resource-name rules
  (`group_description`+`description` substring → entity). Tried **first**, so it
  classifies correctly regardless of which project a resource is in. This is what
  lets the tool allocate pre-restructure invoices and survive the project-name
  transition. First match wins; list specific patterns before general ones.
- `src/cost-allocation/do-entity-map.json` — `project_name` → entity, used as the
  fallback when no resource rule matches. Includes the old project names
  (`AmeriGlide CRM`, `Networking`, `automated-emails`) for historical invoices.
  Anything unmatched by both layers is reported as **unmapped**, never silently dropped.
- `src/cost-allocation/allocation-ratio.json` — `shareSplit` divides the SHARED
  bucket (values must sum to 1; AMG/IAI = 60/40 by agreement) and `rollup` folds a
  direct bucket into another entity (ATC → IAI for now).

## Usage

Requires `DO_BILLING_TOKEN` in `.env` — an **org-level** DO API token (regular
team/user PATs, doctl included, 403 on billing; mint the org token in the cloud
panel under Organization API settings, where `billing` is the only scope).

```sh
bin/cost-allocation                  # latest issued invoice
bin/cost-allocation --period 2026-04 # a specific month
bin/cost-allocation --uuid <uuid>    # a specific invoice
bin/cost-allocation --csv ~/Downloads/invoice.csv  # manual CSV (no PAT needed)
```

Writes `output/do-cost-allocation-<period>.{md,csv}` and prints the summary. Exits
non-zero if any spend is unmapped.

## Notes

- **Stale PBX:** `asterisk-pbx` (droplet `562161442`, nyc1, `159.89.54.77`) is the
  wrong-region original; the live PBX is `asterisk-pbx-nyc3` (`565083097`,
  `pbx.callgrove.com` → 104.236.41.225). The nyc1 box (~$24/mo) is a decommission
  candidate — until removed it sits in the IAI bucket.
- **Future hard split:** if a truly separate invoice is ever needed, IAI resources
  can migrate to a second DO Team — but managed DB/k8s/Spaces require recreate +
  data migration (real downtime), so that's a separate, scheduled project. The
  project structure here makes it straightforward to scope.
