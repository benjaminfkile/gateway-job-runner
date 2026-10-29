# gateway-job-runner

Runner image for the gateway's scheduled jobs. See the gateway repository's docs/jobs.md section 7.

The gateway starts one container per job run from this image. The container
runs the job's script once and its exit code is the run's result. The same
image is also the load generator for the gateway's load runs; see
[Load mode](#load-mode).

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

Job mode is the default: it applies whenever `GATEWAY_LOAD_RUN_ID` is unset
or empty.

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

## Load mode

When `GATEWAY_LOAD_RUN_ID` is set and non-empty, the container is one load
generator of a gateway load run: it runs a k6 scenario script and reports
k6's stats back to the gateway every 5 seconds.

### Env contract

| Variable | Meaning |
| --- | --- |
| `GATEWAY_LOAD_RUN_ID` | Id of the load run, a non-negative integer. Selects load mode. |
| `GATEWAY_LOAD_SCENARIO` | Name of the scenario, for the banner and the script. |
| `GATEWAY_LOAD_SCRIPT` | The k6 scenario script, base64 of UTF-8. |
| `GATEWAY_LOAD_INDEX` | Index of this generator in the run, a non-negative integer starting at 0. |
| `GATEWAY_LOAD_COUNT` | Number of generators in the run. |
| `GATEWAY_LOAD_VUS` | Virtual users this generator should run. |
| `GATEWAY_LOAD_RAMP_SECONDS` | Seconds to ramp up to `GATEWAY_LOAD_VUS`. |
| `GATEWAY_LOAD_HOLD_SECONDS` | Seconds to hold at `GATEWAY_LOAD_VUS` after the ramp. |
| `GATEWAY_LOAD_TARGET` | What the scenario sends load to, such as `<target-base-url>`. |
| `GATEWAY_LOAD_PARAMS` | Scenario specific parameters, usually JSON. |
| `GATEWAY_LOAD_STATS_URL` | Where stats lines are posted. Empty means print them to stdout. |
| `GATEWAY_LOAD_TOKEN` | Value of the `X-Gateway-Load-Token` header on each post. |

The entrypoint reads only `GATEWAY_LOAD_RUN_ID`, `GATEWAY_LOAD_SCRIPT`,
`GATEWAY_LOAD_INDEX`, `GATEWAY_LOAD_STATS_URL` and `GATEWAY_LOAD_TOKEN`
itself, and the other banner variables for the banner. Every variable except
`GATEWAY_LOAD_SCRIPT` and `GATEWAY_LOAD_TOKEN` reaches k6, so the scenario
reads them with `__ENV`, for example `__ENV.GATEWAY_LOAD_VUS` and
`JSON.parse(__ENV.GATEWAY_LOAD_PARAMS || '{}')`. Shaping the load (VUs, ramp,
hold) is the scenario's job.

The entrypoint:

1. exits 64 with a message on stderr when `GATEWAY_LOAD_SCRIPT` is missing,
   empty, not valid base64 or decodes to nothing, or when
   `GATEWAY_LOAD_RUN_ID` or `GATEWAY_LOAD_INDEX` is not a non-negative
   integer;
2. decodes the script to `/job/scenario.js` with mode 0600 and removes
   `GATEWAY_LOAD_SCRIPT` from the environment;
3. reads `GATEWAY_LOAD_TOKEN` and removes it from the environment, then
   re-executes itself with the token on a file descriptor, so neither k6, the
   scenario nor the process environment of the container's main process holds
   it; curl reads it from a config on stdin, never from its arguments;
4. prints one line,
   `gateway-load: run_id=<GATEWAY_LOAD_RUN_ID> scenario=<GATEWAY_LOAD_SCENARIO> index=<GATEWAY_LOAD_INDEX> count=<GATEWAY_LOAD_COUNT> vus=<GATEWAY_LOAD_VUS>`,
   and no other variable;
5. starts `k6 run --address 127.0.0.1:6565 --no-usage-report --quiet --summary-trend-stats "avg,min,med,max,p(95),p(99)" /job/scenario.js`
   in the background; k6's own output (log lines, end of test summary) goes
   to the container's stdout and stderr untouched;
6. every 5 seconds while k6 runs, reads k6's REST API
   (`http://127.0.0.1:6565/v1/metrics`), builds a stats line and posts it
   (or prints it). A tick where the metrics read fails (k6 not up yet or
   already gone) is skipped.

Entrypoint log lines (failed posts) go to stderr, prefixed `gateway-load: `.

### Stats line

One compact JSON object per line:

| Field | Meaning |
| --- | --- |
| `runId` | `GATEWAY_LOAD_RUN_ID` as a number. |
| `index` | `GATEWAY_LOAD_INDEX` as a number. |
| `at` | When the line was built, RFC 3339 UTC with seconds. |
| `vus` | Current value of k6's `vus` gauge, 0 before k6 reports it. |
| `metrics` | Every k6 metric by id: `type` (`counter`, `gauge`, `rate` or `trend`) plus every numeric field of k6's current sample for it. |

A counter carries `count` and `rate`, a gauge `value`, a rate `rate` and a
trend `avg`, `min`, `med`, `max` and k6's percentiles (the REST API reports
`p(90)` and `p(95)`). Counters and trends cover the run so far, not the last
5 seconds. Custom metrics of the scenario appear under their own names.
Example, wrapped here for reading:

```json
{"runId":1,"index":0,"at":"2026-01-01T12:00:05Z","vus":10,
 "metrics":{
  "http_req_duration":{"type":"trend","avg":41.2,"min":12.5,"med":38.9,"max":220.1,"p(90)":61.7,"p(95)":80.3},
  "http_req_failed":{"type":"rate","rate":0.002},
  "http_reqs":{"type":"counter","count":1530,"rate":306.1},
  "iterations":{"type":"counter","count":1530,"rate":306.1},
  "vus":{"type":"gauge","value":10},
  "vus_max":{"type":"gauge","value":10}}}
```

Each post is `POST <GATEWAY_LOAD_STATS_URL>` with
`Content-Type: application/json` and `X-Gateway-Load-Token: <token>`, a 10 s
timeout and no retry.

### Stop handshake

The gateway's answer to each post decides what happens next:

| Answer | Effect |
| --- | --- |
| 2xx with body `{ "action": "stop" }` | stop |
| 409 | stop |
| any other 2xx | continue |
| network failure, timeout or 5xx | one log line on stderr; the line is dropped and the run continues |
| any other status | one log line on stderr; the run continues |

Stop means: the entrypoint sends k6 SIGTERM (k6 aborts the test gracefully
and prints its summary), waits for it to exit, posts one final stats line
built from the last metrics it read, ignores the answer and exits 0. SIGTERM
or SIGINT to the container (`docker stop`, instance termination) is handled
the same way. `docker stop` waits 10 s before SIGKILL by default; give it
more (`docker stop -t 30`) when the final post must get through a slow
network.

When k6 exits on its own, the entrypoint posts (or prints) one final line
the same way and exits with k6's exit code.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | k6 finished with 0, or the run was stopped (stop answer, 409, SIGTERM, SIGINT). |
| 64 | Missing or broken `GATEWAY_LOAD_SCRIPT`, or a non-integer `GATEWAY_LOAD_RUN_ID` or `GATEWAY_LOAD_INDEX`. |
| other | k6's own exit code, for example 99 for failed thresholds or 107 for a script error. |

### Running a scenario by hand

With `GATEWAY_LOAD_STATS_URL` unset the stats lines are printed to stdout:

```sh
docker run --rm -e GATEWAY_LOAD_RUN_ID=1 -e GATEWAY_LOAD_INDEX=0 -e GATEWAY_LOAD_COUNT=1 -e GATEWAY_LOAD_VUS=1 -e GATEWAY_LOAD_SCRIPT="$(base64 -w0 scenario.js)" gateway-job-runner
```

(`base64 -w0` is GNU coreutils; on macOS use `base64 -i scenario.js`.) Add
`-e GATEWAY_LOAD_TARGET=<target-base-url>` and any other variable the
scenario reads.

### k6 version

k6 is pinned to v1.8.2 by the `K6_VERSION` build argument at the top of the
`Dockerfile`. The build downloads `k6-v<version>-linux-<arch>.tar.gz` for
the image's architecture (`TARGETARCH`, amd64 or arm64) and
`k6-v<version>-checksums.txt` from the same GitHub release of grafana/k6,
checks the tarball with `sha256sum -c` and fails on a mismatch. To move to
another k6 v1 release, change `K6_VERSION` and run the smoke test.

## Tools

Installed from Alpine 3.21 packages, with no pins beyond the Alpine minor:
bash, coreutils, curl, jq, postgresql17-client (psql, pg_dump, pg_restore),
aws-cli, ca-certificates, tzdata and gettext (envsubst).

k6 is installed from its GitHub release, pinned to one version and checked
against the release's sha256 checksums (see [k6 version](#k6-version)); it
is at `/usr/local/bin/k6`. The tarball's build needs BuildKit (the default
builder of current Docker and of buildx), which sets `TARGETARCH`.

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
with `IMAGE`) and checks five runs: a script that echoes a line and exits 3
gives exit code 3 and the line in the output; no script gives exit code 64;
a script calling `psql --version`, `aws --version` and `jq --version` gives
exit code 0; in load mode, a 12 s `ramping-vus` scenario with one VU and the
custom metrics `smoke_ticks` (counter) and `smoke_ms` (trend) gives exit code
0, the banner line and at least two printed stats lines with `runId` 1,
`index` 0 and a numeric `vus`, the last one with `smoke_ticks.count` above 0
and `smoke_ms` of type trend; load mode without `GATEWAY_LOAD_SCRIPT` gives
exit code 64. It checks the stats lines with the image's own jq, so the host
needs only Docker. It exits non-zero if any check fails.

To run a script by hand:

```sh
docker run --rm \
  -e GATEWAY_JOB_NAME=demo -e GATEWAY_JOB_RUN_ID=1 -e GATEWAY_JOB_TRIGGER=manual \
  -e GATEWAY_JOB_SCRIPT="$(printf 'echo hi\n' | base64 | tr -d '\n')" \
  gateway-job-runner
```

## CI and publishing

`.github/workflows/ci.yml` runs `scripts/smoke.sh` on every push and pull
request; it builds the runner's native platform (linux/amd64).

On a push to `main`, after the smoke test passes, the `publish` job assumes
the role in the `AWS_ROLE_ARN` secret through GitHub OIDC
(`aws-actions/configure-aws-credentials`), logs in to ECR and uses buildx to
push a linux/amd64 and linux/arm64 image to the repository URI in the
`ECR_REPOSITORY` secret, tagged with the commit sha and `latest`. Buildx sets
`TARGETARCH` per platform, so each image gets the k6 tarball of its own
architecture. The region
comes from the `AWS_REGION` repository variable.

| Setting | Kind | Example |
| --- | --- | --- |
| `AWS_ROLE_ARN` | secret | `arn:aws:iam::123456789012:role/example-ci` |
| `ECR_REPOSITORY` | secret | `123456789012.dkr.ecr.us-east-1.amazonaws.com/gateway-job-runner` |
| `AWS_REGION` | variable | `us-east-1` |

When any of the three is unset, as in a fork, the publish steps are skipped
with a notice and the workflow still passes on the build and smoke test.
