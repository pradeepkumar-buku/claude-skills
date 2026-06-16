---
name: create-ssm-parameter
description: Create AWS SSM Parameter Store entries in buku dev/staging environments, mirroring the tags of existing parameters in the same path. Use when asked to "create a parameter store variable", "add an SSM param", or set up config for a service that consumes SSM parameters via AWS Copilot manifests (e.g. app-gateway).
---

# Create SSM Parameter Store entries (buku dev/staging)

Workflow for adding new AWS SSM Parameter Store entries used by Copilot-deployed buku services. Buku services reference SSM ARNs from their `copilot/<svc>/manifest.yml` `secrets:` blocks — those parameters must exist before deploy or the ECS task fails to start.

## Environment

| Env | Account | Region | Path prefix |
|---|---|---|---|
| dev | `412701086342` | `ap-southeast-1` | `/dev/buku/<service>/<NAME>` |
| staging | `412701086342` | `ap-southeast-1` | `/staging/buku/<service>/<NAME>` |

## Loading AWS creds

**Canonical location:** `<repo-root>/.aws_env/.env`

Expected contents (SSO session creds — these expire, usually 1–12 hours):

```bash
export AWS_ACCESS_KEY_ID="ASIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
```

The assumed role is typically `AWSReservedSSO_AWS-dev-developer` for dev/staging writes.

Load and verify in one step:

```bash
if [ ! -f .aws_env/.env ]; then
  echo "ERROR: .aws_env/.env not found at repo root" >&2
  exit 1
fi
set -a && source .aws_env/.env && set +a
aws sts get-caller-identity --query 'Account' --output text 2>/dev/null | grep -q '^412701086342$' || {
  echo "ERROR: creds invalid, expired, or not for dev/staging account 412701086342" >&2
  aws sts get-caller-identity || true
  exit 1
}
```

### On any creds error — stop and ask the user

If **any** of these happen, pause and ask the user to refresh creds:

- `.aws_env/.env` is missing → ask them to create it at the repo root with the three `AWS_*` exports above.
- `aws sts get-caller-identity` returns `ExpiredToken`, `InvalidClientTokenId`, or `UnrecognizedClientException` → creds are stale; ask them to re-pull from SSO and overwrite `.aws_env/.env`.
- `Account` field returns something other than `412701086342` for dev/staging work → wrong profile loaded; ask them to confirm which account the creds are for.
- Any `put-parameter` / `list-tags-for-resource` call returns `AccessDeniedException` → the assumed role lacks the needed perms; ask the user to use a role with `ssm:PutParameter` + `ssm:AddTagsToResource` on the target path prefix.

Do **not** attempt to work around expired/missing creds by suggesting `aws configure`, IAM users, env-var inlining, or alternate creds files. The buku convention is the `.aws_env/.env` file — keep it there, ask the user to refresh it.

## Tag convention

Every SSM parameter under `/dev/...` or `/staging/...` carries **exactly two tags**:

| Key | Value |
|---|---|
| `copilot-application` | `buku` |
| `copilot-environment` | `dev` or `staging` (matches the path prefix) |

Do **not** invent extra tags — Copilot resource-tag-based IAM policies expect this exact shape.

## Steps

### 1. Load creds + confirm account

Run the load-and-verify block from the **Loading AWS creds** section above. The verify call:

```bash
aws sts get-caller-identity
```

Expected: `"Account": "412701086342"` for dev/staging. If it shows any other account, stop — those creds can't write to dev/staging SSM. If it errors at all, do not proceed: follow the **On any creds error** guidance and ask the user to fix `.aws_env/.env`.

### 2. Locate a sibling parameter to mirror

Before creating, list existing params under the same prefix and pick the closest analog (same service, similar nature — e.g. a version code if you're adding a version code).

```bash
aws ssm describe-parameters --region ap-southeast-1 \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/dev/buku/<service>/" \
  --query 'Parameters[].Name' --output text | tr '\t' '\n'
```

Good reference targets in `app-gateway`: `EVENT_TRACK_VERSION_CODE`, `FORCE_STOP_ENABLED`.

### 3. Read the reference's tags (sanity check)

```bash
aws ssm list-tags-for-resource --region ap-southeast-1 \
  --resource-type Parameter \
  --resource-id /dev/buku/<service>/<REFERENCE_PARAM>
```

Confirm it returns the two `copilot-*` tags. If it doesn't, ask the user before continuing — the convention may have shifted.

### 4. Review and create the parameter(s)

Before writing anything, review the full set of parameter paths, values, and types that will be created. Confirm the list with the user if it was not given explicitly.

Default to `--type String` for non-secret values (version codes, feature flags, numeric thresholds). Use `--type SecureString` only for credentials/tokens/keys.

```bash
aws ssm put-parameter --region ap-southeast-1 \
  --name "/dev/buku/<service>/<NAME>" \
  --value "<VALUE>" \
  --type String \
  --tags "Key=copilot-application,Value=buku" "Key=copilot-environment,Value=dev"
```

Loop pattern when creating the same param across both envs:

```bash
for env in dev staging; do
  aws ssm put-parameter --region ap-southeast-1 \
    --name "/${env}/buku/<service>/<NAME>" \
    --value "<VALUE>" \
    --type String \
    --tags "Key=copilot-application,Value=buku" "Key=copilot-environment,Value=${env}"
```

If you hit `command not found: aws` inside a shell loop after `source`-ing the env file, invoke the binary by absolute path (`/usr/local/bin/aws`) — the sourced env can clobber `PATH`.

### 5. Verify value + tags

```bash
aws ssm get-parameter --region ap-southeast-1 \
  --name "/dev/buku/<service>/<NAME>" \
  --query 'Parameter.[Name,Value,Type]' --output text

aws ssm list-tags-for-resource --region ap-southeast-1 \
  --resource-type Parameter \
  --resource-id "/dev/buku/<service>/<NAME>" \
  --query 'TagList' --output text
```

Both must succeed and tags must show the two `copilot-*` entries.

## Guardrails

- **Confirm before writing.** Creating SSM parameters is a shared-infra write. State the full list of paths + values you're about to create and get explicit user approval if it wasn't given upfront.
- **Match the value type to the Java/yml default.** If `application.yml` defaults `${X:5385}`, the SSM value should be `5385` (string), not formatted differently. Mismatched types cause runtime parse errors.
- **Never use these creds against non-dev/staging accounts.** Dev and staging SSM use the `412701086342` account in `ap-southeast-1`. If asked to add prod config, note that prod is handled separately and is not part of this dev/staging SSM workflow.
- **Don't update existing parameters silently.** If `put-parameter` returns version > 1, you overwrote a pre-existing value. Surface this to the user; they may have wanted to add, not overwrite. Pass `--no-overwrite` when in doubt, then re-run with explicit confirmation if it errors with `ParameterAlreadyExists`.
- **Throttling is normal.** `describe-parameters` is rate-limited; retry with smaller `--max-results` if you hit `ThrottlingException`.

## Common mistakes

- Forgetting tags → Copilot deploy may still work, but ownership/cost-allocation reports break.
- Using `--type SecureString` for non-secret values → forces consumers to decrypt and bloats audit logs.
- Creating only in one env → the next deploy of the other env fails. Always do dev **and** staging together unless explicitly told otherwise.
- Hardcoding `/usr/local/bin/aws` everywhere → fine as a fallback inside loops, but use plain `aws` in interactive commands so the skill stays portable.
