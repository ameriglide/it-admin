# ssm-rotate CronJob

Rotates the AWS SSM hybrid activations on the 1st and 15th, writing the result
to the 1Password item `ag-admin-runtime`. Replaces the
`com.ameriglide.ssm-rotate` LaunchAgent that used to run on a laptop.

## Why it moved

The LaunchAgent ran in a GUI session, so it only fired when the machine was
awake and logged in. It missed 2026-08-15 entirely, and on 2026-08-01 it ran
with 1Password locked: every value from the `.env` FIFO came back empty, each
had a silent fallback, and it did a partial rotation and exited 0. That left an
expired activation live on a teammate's machine for three weeks.

## Secrets

Not in git. Create the Secret from values already in 1Password:

```bash
source ~/Projects/ag-admin/load-env.sh   # AG_AWS_ADMIN_* from the Environment

OP_TOKEN=$(op item get "ag-admin-rotate service account token" \
             --vault IT --account ameriglide.1password.com \
             --fields credential --reveal)

kubectl create namespace ssm-rotate --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic ssm-rotate-secrets -n ssm-rotate \
  --from-literal=AWS_ACCESS_KEY_ID="$AG_AWS_ADMIN_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AG_AWS_ADMIN_SECRET_ACCESS_KEY" \
  --from-literal=OP_SERVICE_ACCOUNT_TOKEN="$OP_TOKEN" \
  --from-literal=HEARTBEAT_URL="<heartbeat url>"

unset OP_TOKEN
```

`HEARTBEAT_URL` is the Better Stack heartbeat for this job (id **484856**,
"ssm-rotate (k8s CronJob)", escalation policy 114897). It is in the Secret and
not in the manifest because this repo is public and anyone able to read that
URL could beat the heartbeat and hide a real failure. Get it from Better Stack
> Heartbeats, or from the `ssm-rotate-secrets` Secret.

The service account `ag-admin-rotate` can reach the `ag-admin-runtime` vault
and nothing else. Its own token lives in `IT`, which that token cannot read.

## Deploy

```bash
kubectl apply -f ops/k8s/ssm-rotate/cronjob.yaml
```

## Run it now

```bash
kubectl create job -n ssm-rotate --from=cronjob/ssm-rotate manual-$(date +%s)
kubectl logs -n ssm-rotate -l job-name=<job> --follow
```

## Verifying a run

```bash
aws ssm describe-activations --profile ag-aws --region us-east-1 \
  --query 'ActivationList[].{Id:ActivationId,Name:DefaultInstanceName,Expired:Expired}' \
  --output table
```

Expect exactly two unexpired activations, `amg-workstation` and
`personal-machine`. More than two means a previous run failed to delete its
predecessor; the script warns when it has no previous id to delete.

## Known gaps

- **No peer sync.** A pod cannot ssh to a laptop, so `SSM_ROTATE_PEERS` is
  empty and nothing is written outside 1Password. Anyone still reading a plain
  `.env` for `SSM_ACTIVATION_ID` will go stale. The script prints
  "no peers configured for this fleet" on every run rather than skipping in
  silence.
- **Tracks `main`.** The script is fetched by raw URL at run time, so a broken
  commit on `main` breaks the next rotation. Deliberate — it also means a fix
  needs no redeploy — but pin a tag if that trade stops being worth it.
