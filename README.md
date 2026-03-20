# IT Admin

IT administration scripts for workstation and device management.

> **No secrets here.** This repo is intentionally public. Nothing in this repo should contain credentials, API keys, tokens, or domain-specific configuration. All sensitive values are passed as parameters at runtime.

## GCPW Deployment

Deploys [Google Credential Provider for Windows](https://support.google.com/a/answer/9250996) to replace JumpCloud for workstation access control.

### Quick Setup (new machine)

Open PowerShell **as Administrator** and paste:

```powershell
irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/deploy-gcpw.ps1 -OutFile $env:TEMP\deploy-gcpw.ps1; & $env:TEMP\deploy-gcpw.ps1 -NewMachine -Domain yourdomain.com
```

### JumpCloud Migration (existing machine)

**Phase 1** — Install GCPW alongside JumpCloud:
```powershell
irm https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/deploy-gcpw.ps1 -OutFile $env:TEMP\deploy-gcpw.ps1; & $env:TEMP\deploy-gcpw.ps1 -GoogleEmail user@yourdomain.com -Domain yourdomain.com -Phase 1
```

Reboot, verify Google login works and existing profile is intact, then:

**Phase 2** — Remove JumpCloud:
```powershell
& $env:TEMP\deploy-gcpw.ps1 -Phase 2
```

### Prerequisites

- Enable GCPW in Google Admin Console: **Devices > Mobile & endpoints > Settings > Windows > GCPW settings**
- Windows 10 or 11
- PowerShell run as Administrator
