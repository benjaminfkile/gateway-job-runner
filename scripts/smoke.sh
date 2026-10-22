#!/usr/bin/env bash
# Smoke test of the job runner image: builds it locally and proves the
# entrypoint contract with three runs.
#   1. a two-line script (echo plus exit 3) exits 3 and its line is printed
#   2. no script exits 64
#   3. psql, aws and jq are present and the script exits 0
# IMAGE overrides the local tag the image is built as.
set -euo pipefail

cd "$(dirname "$0")/.."

image="${IMAGE:-gateway-job-runner:smoke}"
failures=0

b64() {
    printf '%s' "$1" | base64 | tr -d '\n'
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

if [ "$failures" -ne 0 ]; then
    echo "smoke: $failures check(s) failed"
    exit 1
fi
echo "smoke: all checks passed"
