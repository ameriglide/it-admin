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

## Standard App Installer

Installs Chrome, Adobe Acrobat Reader DC, Slack, Tailscale, Google Drive, and Zoiper 5 Free via Chocolatey. Skips anything already installed. Also joins the Tailscale/Headscale network using the provided auth key.

Generate a pre-auth key from your Headscale admin console first, then:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/install-apps.ps1 -OutFile $env:TEMP\install-apps.ps1; & $env:TEMP\install-apps.ps1 -TailscaleAuthKey "tskey-auth-..."
```

If you omit `-TailscaleAuthKey`, the script will prompt for it and refuse to continue without one.

## Employee Provisioning

### Onboard a new employee

```sh
bin/onboard --first <First> --last <Last>
```

Walks through Google Workspace user creation, Amberjack employee row, Phenix agent, Twilio worker + SIP credential, optional direct line, and Zoiper config. Idempotent — re-run to resume after a failure.

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
