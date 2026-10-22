#!/bin/sh
# Entrypoint of the gateway job runner image.
#
# GATEWAY_JOB_SCRIPT holds the job's script body as base64 of UTF-8. It is
# decoded to /job/script.sh and run with bash -e, so the script's exit code
# becomes the container's. A missing or undecodable script exits 64 (EX_USAGE).
set -u

script_path=/job/script.sh

fail() {
    printf 'gateway-job-entrypoint: %s\n' "$1" >&2
    exit 64
}

if [ -z "${GATEWAY_JOB_SCRIPT:-}" ]; then
    fail "GATEWAY_JOB_SCRIPT is missing or empty"
fi

umask 077
rm -f "$script_path"
if ! printf '%s' "$GATEWAY_JOB_SCRIPT" | base64 -d > "$script_path" 2>/dev/null; then
    rm -f "$script_path"
    fail "GATEWAY_JOB_SCRIPT is not valid base64"
fi
if [ ! -s "$script_path" ]; then
    rm -f "$script_path"
    fail "GATEWAY_JOB_SCRIPT decodes to an empty script"
fi
chmod 0700 "$script_path"

# The script body is on disk now; keep it out of the job's environment.
unset GATEWAY_JOB_SCRIPT

printf 'gateway-job: name=%s run_id=%s\n' "${GATEWAY_JOB_NAME:-unknown}" "${GATEWAY_JOB_RUN_ID:-unknown}"

exec bash -e "$script_path"
