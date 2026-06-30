# AWS SSM Agent (hybrid) — workstation remote command / debug

Registers an on-prem Windows workstation as an **AWS SSM managed instance** so we can
run commands on it and get output back — the same `aws ssm send-command` flow used on
the EC2 boxes — **reachable over the internet even when the tailnet is down**. This is a
targeted debug channel that complements the Action1 agent (fleet management/patching).

**Opt-in by design:** unlike the Action1 agent, the SSM agent is **not** folded into the
full "Set up workstation" run. You install it deliberately on boxes you want remote
debug on, via the `bin/copy` entry below.

## Prerequisites (`.env`)

The install reads these (real values in `.env`, gitignored — see `.env.example`):

| Key | Value |
|---|---|
| `SSM_ACTIVATION_ID` | hybrid activation id |
| `SSM_ACTIVATION_CODE` | hybrid activation code (secret) |
| `SSM_REGION` | e.g. `us-east-1` |

Driving SSM from the Mac uses the `ag-aws` / `ag-aws-admin` AWS CLI profiles (the default
profile is DigitalOcean, so **always pass `--profile ag-aws…`**).

## Install the agent on a workstation

The box needs internet (no tailnet required).

1. `./bin/copy` -> **"SSM agent - install (hybrid, remote debug, only)..."** -> paste the
   one-liner into an **elevated** PowerShell on the target box.
2. Within a minute it registers and appears as an `mi-...` managed instance:
   ```
   aws ssm describe-instance-information --profile ag-aws --region us-east-1 \
     --filters Key=ResourceType,Values=ManagedInstance
   ```

Idempotent — re-running on a box that already has the `AmazonSSMAgent` service skips.

**Catch-up enroll via Action1** (for a box that has the Action1 agent but not the SSM
agent): run the **"Install SSM Agent (hybrid)"** library script on it. That script is
**parameterized** — it takes `ActivationId` / `ActivationCode` / `Region`; pass the current
values straight from `.env` at run time, so **nothing secret is stored in Action1**.
Easiest from here is `mcp__action1__run_script` with those three `script_params` (or the
console's Run Script dialog). It registers within ~a minute (verify with the
describe-instance-information call above). Note: the library script can only be **edited in
the Action1 web console** — the `.env` API credential reads `/endpoints` fine but 403s on
`/scripts`.

## Run a command on a box

```
CMD=$(aws ssm send-command --profile ag-aws-admin --region us-east-1 \
  --instance-ids mi-xxxxxxxx \
  --document-name AWS-RunPowerShellScript \
  --parameters 'commands=["hostname; Get-Service Tailscale"]' \
  --query 'Command.CommandId' --output text)
aws ssm get-command-invocation --profile ag-aws-admin --region us-east-1 \
  --command-id "$CMD" --instance-id mi-xxxxxxxx \
  --query '{Status:Status,Output:StandardOutputContent}' --output json
```

## Rotation (automated)

Activations expire after at most 30 days, so the activation used to enroll new boxes must
be refreshed regularly. Both consumers read it from `.env` at run time — `setup-workstation.ps1
-Only ssm` and the parameterized Action1 "Install SSM Agent (hybrid)" script — so rotating
`.env` is all that's needed; **no Action1 edit on rotation.** **`bin/rotate-ssm-activation`**
does this: mints a fresh activation,
rewrites `SSM_ACTIVATION_ID/CODE` in this `.env` and every peer `.env` in `SSM_ROTATE_PEERS`
(updated over ssh+sudo), then deletes the previous one. A **launchd job runs it on the 1st
and 15th** of each month (`~/Library/LaunchAgents/com.ameriglide.ssm-rotate.plist`, logs to
`~/Library/Logs/ssm-rotate.log`). Run it by hand anytime: `./bin/rotate-ssm-activation`.

## Mint an activation manually

To create one directly (the rotation script does this for you; IAM role `ssm-hybrid-role`
trusts `ssm.amazonaws.com` + has `AmazonSSMManagedInstanceCore`):

```
aws ssm create-activation --profile ag-aws-admin --region us-east-1 \
  --iam-role ssm-hybrid-role --registration-limit <N> \
  --default-instance-name amg-workstation \
  --description "AmeriGlide workstations"
```

Then update `SSM_ACTIVATION_ID` / `SSM_ACTIVATION_CODE` in `.env`. Already-registered
instances keep working when an activation is deleted/expired; the code just can't enroll
new boxes. Delete a spent one with `aws ssm delete-activation --activation-id <id>`.
