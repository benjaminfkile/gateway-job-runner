#!/usr/bin/env bash
# Smoke test of the job runner image: builds it locally and proves the
# entrypoint contract with five runs.
#   1. a two-line script (echo plus exit 3) exits 3 and its line is printed
#   2. no script exits 64
#   3. psql, aws and jq are present and the script exits 0
#   4. load mode runs a 12 s k6 scenario and prints its banner and stats lines
#   5. load mode without a scenario exits 64
# IMAGE overrides the local tag the image is built as.
set -euo pipefail

cd "$(dirname "$0")/.."

image="${IMAGE:-gateway-job-runner:smoke}"
failures=0

b64() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

# Runs jq from the image under test, so the host needs no jq.
image_jq() {
    docker run --rm -i --entrypoint jq "$image" "$@"
}

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: want $want, got $got"
        failures=$((failures + 1))
    fi
}

job_env=(-e GATEWAY_JOB_NAME=smoke -e GATEWAY_JOB_RUN_ID=run-1 -e GATEWAY_JOB_TRIGGER=manual)

echo "building $image"
docker build -t "$image" .

echo "case 1: script exit code is the container's"
script=$'echo "hello from the smoke job"\nexit 3'
set +e
out="$(docker run --rm "${job_env[@]}" -e GATEWAY_JOB_SCRIPT="$(b64 "$script")" "$image" 2>&1)"
code=$?
set -e
printf '%s\n' "$out"
check "exit code" 3 "$code"
if grep -qx 'hello from the smoke job' <<<"$out"; then
    echo "ok   echoed line"
else
    echo "FAIL echoed line missing"
    failures=$((failures + 1))
fi
if grep -qx 'gateway-job: name=smoke run_id=run-1' <<<"$out"; then
    echo "ok   banner line"
else
    echo "FAIL banner line missing"
    failures=$((failures + 1))
fi

echo "case 2: no script exits 64"
set +e
out="$(docker run --rm "${job_env[@]}" "$image" 2>&1)"
code=$?
set -e
printf '%s\n' "$out"
check "exit code" 64 "$code"

echo "case 3: tools are present"
script=$'psql --version\naws --version\njq --version'
set +e
out="$(docker run --rm "${job_env[@]}" -e GATEWAY_JOB_SCRIPT="$(b64 "$script")" "$image" 2>&1)"
code=$?
set -e
printf '%s\n' "$out"
check "exit code" 0 "$code"

load_env=(-e GATEWAY_LOAD_RUN_ID=1 -e GATEWAY_LOAD_SCENARIO=smoke -e GATEWAY_LOAD_INDEX=0
    -e GATEWAY_LOAD_COUNT=1 -e GATEWAY_LOAD_VUS=1 -e GATEWAY_LOAD_STATS_URL=)

echo "case 4: load mode prints stats lines"
scenario="$(cat <<'SCENARIO'
import { sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const ticks = new Counter('smoke_ticks');
const ms = new Trend('smoke_ms');

export const options = {
    scenarios: {
        smoke: {
            executor: 'ramping-vus',
            startVUs: 1,
            stages: [{ duration: '12s', target: 1 }],
        },
    },
};

export default function () {
    ticks.add(1);
    ms.add(Math.random() * 10);
    sleep(1);
}
SCENARIO
)"
set +e
out="$(docker run --rm "${load_env[@]}" -e GATEWAY_LOAD_SCRIPT="$(b64 "$scenario")" "$image" 2>&1)"
code=$?
set -e
printf '%s\n' "$out"
check "exit code" 0 "$code"
if grep -qx 'gateway-load: run_id=1 scenario=smoke index=0 count=1 vus=1' <<<"$out"; then
    echo "ok   banner line"
else
    echo "FAIL banner line missing"
    failures=$((failures + 1))
fi
stats="$(grep '^{"runId"' <<<"$out" || true)"
lines="$(grep -c . <<<"$stats" || true)"
if [ "$lines" -ge 2 ]; then
    echo "ok   $lines stats lines"
else
    echo "FAIL want at least 2 stats lines, got $lines"
    failures=$((failures + 1))
fi
bad=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! image_jq -e '.runId == 1 and .index == 0 and (.vus | type) == "number"' <<<"$line" >/dev/null 2>&1; then
        bad=$((bad + 1))
    fi
done <<<"$stats"
check "stats lines with runId 1, index 0 and numeric vus" "$lines" "$((lines - bad))"
last="$(tail -n 1 <<<"$stats")"
if image_jq -e '.metrics.smoke_ticks.count > 0 and .metrics.smoke_ms.type == "trend"' <<<"$last" >/dev/null 2>&1; then
    echo "ok   last line carries smoke_ticks and smoke_ms"
else
    echo "FAIL last line lacks smoke_ticks.count > 0 or smoke_ms.type trend"
    failures=$((failures + 1))
fi

echo "case 5: load mode without a scenario exits 64"
set +e
out="$(docker run --rm "${load_env[@]}" "$image" 2>&1)"
code=$?
set -e
printf '%s\n' "$out"
check "exit code" 64 "$code"

if [ "$failures" -ne 0 ]; then
    echo "smoke: $failures check(s) failed"
    exit 1
fi
echo "smoke: all checks passed"
