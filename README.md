# IT Admin

IT administration scripts for workstation and device management.

> **No secrets here.** This repo is intentionally public. Nothing in this repo should contain credentials, API keys, tokens, or domain-specific configuration. All sensitive values are passed as parameters at runtime.

## GCPW Deployment

Deploys [Google Credential Provider for Windows](https://support.google.com/a/answer/9250996) to replace JumpCloud for workstation access control.

### Quick Setup (new machine)

Open PowerShell **as Administrator** and paste:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/deploy-gcpw.ps1 -OutFile $env:TEMP\deploy-gcpw.ps1; & $env:TEMP\deploy-gcpw.ps1 -NewMachine -Domain ameriglide.com
```

### JumpCloud Migration (existing machine)

**Phase 1** — Install GCPW alongside JumpCloud:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/deploy-gcpw.ps1 -OutFile $env:TEMP\deploy-gcpw.ps1; & $env:TEMP\deploy-gcpw.ps1 -GoogleEmail <USER>@ameriglide.com -Domain ameriglide.com -WindowsUsername <USER> -Phase 1
```
Replace `<USER>` with the employee's username (e.g. `jsmith`).

Reboot, verify Google login works and existing profile is intact, then:

**Phase 2** — Remove JumpCloud:
```powershell
& $env:TEMP\deploy-gcpw.ps1 -Phase 2
```

### sage-amg cutover (Windows Server 2022 RDP host)

Server-specific cutover for `sage-amg`. Configures cross-domain GCPW (`ameriglide.com,atlasacces.com`), pre-associates existing JumpCloud-provisioned local accounts with their Google emails so SAM names are reused, disables RDP NLA so the Google tile renders through RDP, and removes JumpCloud.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/deploy-gcpw-sage-amg.ps1 -OutFile $env:TEMP\deploy-gcpw-sage-amg.ps1; & $env:TEMP\deploy-gcpw-sage-amg.ps1
```

Use `-SkipJumpCloudRemoval` to install GCPW alongside JumpCloud first, validate sign-in, then re-run without the flag to remove JumpCloud.

### sage-iai cutover (Windows Server 2022 RDP host, Internet Alliance)

Sister script for `sage-iai`. Single-domain GCPW (`inetalliance.net`). Same `-SkipJumpCloudRemoval` staging pattern.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/deploy-gcpw-sage-iai.ps1 -OutFile $env:TEMP\deploy-gcpw-sage-iai.ps1; & $env:TEMP\deploy-gcpw-sage-iai.ps1
```

### Repair (GCPW installed but no Google tile on login)

If the script ran successfully but the Google login option doesn't appear on the sign-in screen, do a clean reinstall:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/repair-gcpw.ps1 -OutFile $env:TEMP\repair-gcpw.ps1; & $env:TEMP\repair-gcpw.ps1 -Domain ameriglide.com
```

### Prerequisites

- Enable GCPW in Google Admin Console: **Devices > Mobile & endpoints > Settings > Windows > GCPW settings**
- Windows 10 or 11
- PowerShell run as Administrator

## Workstation Setup

`scripts/setup-workstation.ps1` installs Chrome, Adobe Acrobat Reader DC, Slack, Tailscale, Google Drive, and Zoiper 5 via Chocolatey (skips anything already installed, so it's safe to re-run), joins the Tailscale/Headscale network, and — when given `-SipUser`/`-SipPassword` — writes the employee's SIP login into the Default profile so the phone is ready at first login.

Generate a pre-auth key from your Headscale admin console first, then:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/setup-workstation.ps1 -OutFile $env:TEMP\setup-workstation.ps1; & $env:TEMP\setup-workstation.ps1 -TailscaleAuthKey "tskey-auth-..."
```

If you omit `-TailscaleAuthKey`, the script will prompt for it and refuse to continue without one. (`bin/copy` builds this one-liner for you, and `bin/onboard` runs it as part of its workstation walkthrough.)

## Employee Provisioning

### Onboard a new employee

`bin/onboard` is the single entry point: it provisions the cloud accounts, then offers to walk you through the workstation setup, copying each PowerShell one-liner to your clipboard as you go.

```sh
bin/onboard --first <First> --last <Last>
```

What it does, in order:

1. **Provision accounts** (Mac) — Google Workspace user, Amberjack employee, Phenix agent, Twilio worker + SIP credential, optional direct line, and the Zoiper config. Idempotent — re-run to resume after a failure.
2. **Workstation walkthrough** (optional, prompted at the end). For each step it copies a one-liner to paste into an **elevated** PowerShell on the machine:
   - GCPW new-machine setup — *only if the machine doesn't already have GCPW*
   - `setup-workstation.ps1` — apps + Tailscale + Zoiper, plus the employee's SIP login written into the **Default profile** so the phone is ready at first sign-in
   - Verify the device shows in Google Admin Console > Devices and the employee can sign in
   - *(optional)* `bin/reset-user` to re-arm a clean first-login, if you test-signed-in yourself

Notes:

- **Local-admin rights** for the employee are not granted by these scripts. They come from the Google Admin console (*Account settings → Accounts with local administrative access*) and take effect on the employee's **next** sign-in after device sync. The `localadmin` account that `deploy-gcpw.ps1` creates is a separate, permanent break-glass admin.
- The workstation one-liners require an **elevated** PowerShell (`#Requires -RunAsAdministrator`).
- `bin/copy` remains a menu of the individual one-liners for one-offs (re-imaging, standalone Zoiper config, Tailscale, sage-amg, JumpCloud migration phases).

### Google Groups

`bin/onboard` adds new hires to distribution lists based on role bundles defined
in `ONBOARD_ROLES` (a JSON map of role name -> group addresses, in `.env`). The
onboarder picks a role; its groups are pre-selected and can be toggled before
applying. Pass `--role "Sales Rep"` to skip the prompt. If `ONBOARD_ROLES` is
unset, the step is skipped.

Short group tokens (`sales-staff@`) expand to `<localpart>@$DOMAIN`; full
addresses (`marketing@other-domain.com`) pass through unchanged.

To repair existing membership, use `bin/groups`:

- `bin/groups roles` — list configured roles and their groups.
- `bin/groups show <email>` — which role-groups a person is currently in.
- `bin/groups audit "<Role>"` — member counts plus a drift report (people in
  some but not all of a role's groups). Broad lists like `staff@` are shown but
  excluded from the diff; override the broad set with `ONBOARD_BROAD_GROUPS`.
- `bin/groups add <email> [--role "<Role>"] [--group <addr>]` — add a person to a
  role's full bundle (or one group), idempotently.

### Offboard a departing employee

```sh
bin/offboard --email <addr>
# or
bin/offboard --first <First> --last <Last>
```

Mirror of onboard. Tears down Phenix (via Remix `setAgentInactive` mutation), Twilio worker and SIP credential, Amberjack `locked = true`, then Google: GYB mailbox backup → user delete with Drive transfer to manager → recreate address as an archive Group → load mail archive back into the group.

Flags:
- `--manager <addr>` — skip the interactive manager picker and use this address as the Drive transfer target.
- `--dry-run` — run every `check()` without executing destructive operations.
- `--skip <step,step>` — comma-separated step names to skip (`phenix`, `twilio`, `amberjack`, `google`).

Prerequisites: `gyb` installed on PATH, `REMIX_GRAPHQL_URL` + `REMIX_API_KEY` env vars set (see `docs/remix-offboard-api-handoff.md` for the Remix-side endpoints this depends on).
