# MeshCentral — workstation remote management (server side)

Self-hosted, **tailnet-only** MeshCentral server that gives AmeriGlide + IAI on-prem
Windows workstations an SSM-style remote command/console capability. The Windows agent
is delivered through the existing it-admin pipeline (`setup-workstation.ps1 -Only meshagent`
+ the `bin/copy` "Mesh agent" entry); see `docs/runbooks/mesh-agent.md`.

## What's here

- `docker-compose.yml` — the MeshCentral container. Binds port 443 to the droplet's
  **tailnet IP** (`${MESH_BIND}`) only, so there is no public listener.
- `config.json.template` — intended server settings (`LANonly`, `cert=<tailnet name>`,
  no self-update). The live `config.json` lands in `meshcentral-data/config.json` on the
  droplet.

## Topology stays on the droplet

`ameriglide/it-admin` is public. The droplet's tailnet IP (`MESH_BIND`) and the live
`config.json` carry topology and live **only on the droplet** (in `ops/meshcentral/.env`
and `meshcentral-data/`), never committed here. Two device groups
(`AmeriGlide Workstations`, `IAI Workstations`) and the admin account are created in the
web UI on first run; their `meshid` install tokens go into `ag-admin/.env` as
`MESH_GROUP_ID_AMERIGLIDE` / `MESH_GROUP_ID_IAI`.

## Bootstrap

Droplet creation, tailnet join, and group setup are documented in the implementation
plan (`it-admin-docs/plans/2026-06-24-meshcentral-workstation-management.md`, Task 2) and
summarized in `docs/runbooks/mesh-agent.md`.
