# gateway-job-runner

Runner image for the gateway's scheduled jobs. See the gateway repository's docs/jobs.md section 7.

The gateway starts one container per job run from this image. The container
runs the job's script once and its exit code is the run's result.

## Env contract

The gateway passes only environment variables; nothing is mounted.

| Variable | Meaning |
| --- | --- |
| `GATEWAY_JOB_NAME` | Name of the job. |
| `GATEWAY_JOB_RUN_ID` | Id of this run. |
| `GATEWAY_JOB_TRIGGER` | What started the run. |
| `GATEWAY_JOB_SCRIPT` | The script body, base64 of UTF-8. |
| everything else | The job's secret, flattened into env. |

The entrypoint (`entrypoint.sh`, installed as
`/usr/local/bin/gateway-job-entrypoint`):

1. exits 64 with a message on stderr when `GATEWAY_JOB_SCRIPT` is missing,
   empty, not valid base64 or decodes to nothing;
2. decodes it to `/job/script.sh` with mode 0700 and removes
   `GATEWAY_JOB_SCRIPT` from the environment;
3. prints one line, `gateway-job: name=<GATEWAY_JOB_NAME> run_id=<GATEWAY_JOB_RUN_ID>`,
   and no other variable;
4. execs `bash -e /job/script.sh`, so the script's exit code is the
   container's.

The container runs as the non-root user `job` with home and working
directory `/job`.

## Writing a job script

- The script runs under `bash -e`: any failing command ends the run with that
  command's exit code. Use `|| true` or an `if` where a failure is expected.
  Add `set -o pipefail` and `set -u` at the top if the job wants them.
- Exit 0 for success and a non-zero code for failure; the gateway records the
  code. Avoid 64, which the entrypoint uses for a missing or broken script.
- Never print secrets. Output is captured by the gateway; do not echo env
  values, run `env` or `set -x`, or pass secrets as command arguments where
  a tool might log them. Prefer variables the tools read themselves, such as
  `PGPASSWORD` for psql or the `AWS_*` variables for the AWS CLI.

Example:

```bash
#!/usr/bin/env bash
set -o pipefail
echo "dumping $PGDATABASE"
pg_dump --format=custom "$PGDATABASE" | aws s3 cp - "s3://example-bucket/$GATEWAY_JOB_RUN_ID.dump"
```

## Tools

Installed from Alpine 3.21 packages, with no pins beyond the Alpine minor:
bash, coreutils, curl, jq, postgresql17-client (psql, pg_dump, pg_restore),
aws-cli, ca-certificates, tzdata and gettext (envsubst).

Case 3 of the smoke test prints `psql --version`, `aws --version` and
`jq --version` for the image it built. On Alpine 3.21 these are the
PostgreSQL 17 client, AWS CLI v2 and jq 1.7. Patch versions move with Alpine
3.21 package updates, so the smoke test log in CI is the authoritative list
for a published image.

## Build and test locally

Requires Docker with BuildKit.

```sh
docker build -t gateway-job-runner .
scripts/smoke.sh
```

`scripts/smoke.sh` builds the image (tag `gateway-job-runner:smoke`, override
with `IMAGE`) and checks three runs: a script that echoes a line and exits 3
gives exit code 3 and the line in the output; no script gives exit code 64;
a script calling `psql --version`, `aws --version` and `jq --version` gives
exit code 0. It exits non-zero if any check fails.

To run a script by hand:

```sh
docker run --rm \
  -e GATEWAY_JOB_NAME=demo -e GATEWAY_JOB_RUN_ID=1 -e GATEWAY_JOB_TRIGGER=manual \
  -e GATEWAY_JOB_SCRIPT="$(printf 'echo hi\n' | base64 | tr -d '\n')" \
  gateway-job-runner
```

## CI and publishing

`.github/workflows/ci.yml` runs `scripts/smoke.sh` on every push and pull
request.

On a push to `main`, after the smoke test passes, the `publish` job assumes
the role in the `AWS_ROLE_ARN` secret through GitHub OIDC
(`aws-actions/configure-aws-credentials`), logs in to ECR and uses buildx to
push a linux/amd64 and linux/arm64 image to the repository URI in the
`ECR_REPOSITORY` secret, tagged with the commit sha and `latest`. The region
comes from the `AWS_REGION` repository variable.

| Setting | Kind | Example |
| --- | --- | --- |
| `AWS_ROLE_ARN` | secret | `arn:aws:iam::123456789012:role/example-ci` |
| `ECR_REPOSITORY` | secret | `123456789012.dkr.ecr.us-east-1.amazonaws.com/gateway-job-runner` |
| `AWS_REGION` | variable | `us-east-1` |

When any of the three is unset, as in a fork, the publish steps are skipped
with a notice and the workflow still passes on the build and smoke test.
