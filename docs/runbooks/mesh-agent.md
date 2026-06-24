# MeshCentral workstation remote management

A self-hosted, **tailnet-only** MeshCentral server gives the AmeriGlide and IAI
on-prem Windows workstations an SSM-style remote command/console capability
(remote shell, file transfer, remote desktop). The Windows agent dials out to the
server over the headscale tailnet, so there are no inbound ports on the workstation
and nothing is exposed publicly.

- **Server:** a dedicated DigitalOcean droplet (`meshcentral`, nyc3) joined to the
  tailnet, running MeshCentral in Docker, bound to its tailnet IP only.
- **Fleets:** two device groups — `AmeriGlide Workstations` and `IAI Workstations`.
- **Servers are out of scope** — sage-* boxes use SSH today and AWS-native SSM after
  the migration.

## Prerequisites (`.env`)

The agent install reads these from `ag-admin/.env` (topology stays out of the public
repo — see `.env.example` for the documented keys):

| Key | Value |
|---|---|
| `MESHCENTRAL_URL` | server tailnet URL, e.g. `https://meshcentral` |
| `MESH_GROUP_ID_AMERIGLIDE` | AmeriGlide group `meshid` token |
| `MESH_GROUP_ID_IAI` | IAI group `meshid` token |

The two `meshid` tokens come from the MeshCentral web UI: open a device group ->
**Add Device** -> copy the value of `meshid=` from the generated install command.

## Install the agent on a workstation

The box must already be on the tailnet (Tailscale is installed by
`setup-workstation.ps1`).

1. Run `./bin/copy`, choose **"Mesh agent - install (remote management, only)..."**,
   and pick the fleet (AmeriGlide / IAI). The one-liner is copied to your clipboard.
2. Paste it into an **elevated** PowerShell on the target workstation.
3. The box appears in the matching device group in the MeshCentral console within a
   few seconds. The agent runs as the `Mesh Agent` Windows service and reconnects on
   reboot.

New / re-imaged machines get the agent automatically: the full
**"Set up workstation"** entry in `bin/copy` passes the mesh flags (group chosen by
`DOMAIN`) when `MESHCENTRAL_URL` + the group id are set in `.env`.

The install is idempotent — re-running it on a box that already has the service prints
"Already installed. Skipping."

## Run a command across a fleet

In the MeshCentral console: open the device group -> select one or more devices ->
**Run Commands** (PowerShell or shell), or open a single device for an interactive
terminal / desktop.

## Uninstall the agent

On the workstation, elevated:

```powershell
& "C:\Program Files\Mesh Agent\MeshAgent.exe" -fulluninstall
```

(If the install exe is still in `%TEMP%`, `& "$env:TEMP\meshagent.exe" -fulluninstall`
works too.)

## Server

The droplet bootstrap (create, tailnet join, `docker compose up`) and the Docker/
config files live in `ops/meshcentral/` (see its `README.md`) and the implementation
plan (`it-admin-docs/plans/2026-06-24-meshcentral-workstation-management.md`). The live
`config.json` and the droplet's tailnet bind IP stay on the droplet, never committed.
