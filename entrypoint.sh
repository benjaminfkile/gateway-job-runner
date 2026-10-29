#!/bin/sh
# Entrypoint of the gateway job runner image.
#
# Job mode (GATEWAY_LOAD_RUN_ID unset or empty): GATEWAY_JOB_SCRIPT holds the
# job's script body as base64 of UTF-8. It is decoded to /job/script.sh and
# run with bash -e, so the script's exit code becomes the container's. A
# missing or undecodable script exits 64 (EX_USAGE).
#
# Load mode (GATEWAY_LOAD_RUN_ID set): GATEWAY_LOAD_SCRIPT holds a k6 scenario
# as base64 of UTF-8. It is decoded to /job/scenario.js and run with k6, and a
# stats line built from k6's REST API is posted to GATEWAY_LOAD_STATS_URL (or
# printed when that is empty) every 5 seconds until k6 ends or the gateway
# answers stop. See README.md, "Load mode".
set -u

script_path=/job/script.sh
scenario_path=/job/scenario.js
load_state_dir=/job/.gateway-load
k6_address=127.0.0.1:6565
report_interval=5

fail() {
    printf 'gateway-job-entrypoint: %s\n' "$1" >&2
    exit 64
}

# Prints one load mode log line on stderr.
load_log() {
    printf 'gateway-load: %s\n' "$1" >&2
}

# Decodes base64 value $2 (from variable $1) to file $3 with mode $4; exits
# 64 when the value is missing, empty, not valid base64 or decodes to nothing.
decode_script() {
    if [ -z "$2" ]; then
        fail "$1 is missing or empty"
    fi
    umask 077
    rm -f "$3"
    if ! printf '%s' "$2" | base64 -d > "$3" 2>/dev/null; then
        rm -f "$3"
        fail "$1 is not valid base64"
    fi
    if [ ! -s "$3" ]; then
        rm -f "$3"
        fail "$1 decodes to an empty script"
    fi
    chmod "$4" "$3"
}

# Exits 64 unless value $2 (from variable $1) is a non-negative integer.
require_integer() {
    case "$2" in
        '' | *[!0-9]*) fail "$1 must be a non-negative integer" ;;
    esac
}

# Load mode, first pass: decodes the scenario, checks the numeric ids, then
# re-executes this script without GATEWAY_LOAD_SCRIPT and GATEWAY_LOAD_TOKEN
# in its environment. The token goes to the new process on file descriptor 3
# (a here-document), so it is in neither /proc/1/environ nor any argument list.
load_prepare() {
    decode_script GATEWAY_LOAD_SCRIPT "${GATEWAY_LOAD_SCRIPT:-}" "$scenario_path" 0600
    unset GATEWAY_LOAD_SCRIPT
    require_integer GATEWAY_LOAD_RUN_ID "$GATEWAY_LOAD_RUN_ID"
    require_integer GATEWAY_LOAD_INDEX "${GATEWAY_LOAD_INDEX:-}"
    load_token="${GATEWAY_LOAD_TOKEN:-}"
    unset GATEWAY_LOAD_TOKEN
    exec "$0" --load-run 3<<EOF
$load_token
EOF
}

# Load mode, second pass: reads the token from file descriptor 3, prints the
# banner, starts k6 in the background and runs the reporter until the end.
load_run() {
    stop_requested=0
    trap 'stop_requested=1' TERM INT

    load_token=
    IFS= read -r load_token <&3 || true
    exec 3<&-
    # Curl reads the token header from its config on stdin; escape it for a
    # double-quoted config value.
    load_token_conf="$(printf '%s' "$load_token" | sed 's/[\\"]/\\&/g')"
    load_token=

    umask 077
    mkdir -p "$load_state_dir"
    rm -f "$load_state_dir"/*

    printf 'gateway-load: run_id=%s scenario=%s index=%s count=%s vus=%s\n' \
        "$GATEWAY_LOAD_RUN_ID" "${GATEWAY_LOAD_SCENARIO:-unknown}" \
        "${GATEWAY_LOAD_INDEX:-unknown}" "${GATEWAY_LOAD_COUNT:-unknown}" \
        "${GATEWAY_LOAD_VUS:-unknown}"

    k6 run --address "$k6_address" --no-usage-report --quiet \
        --summary-trend-stats "avg,min,med,max,p(95),p(99)" "$scenario_path" &
    k6_pid=$!

    report_loop
}

# Saves k6's current metrics to the snapshot file; fails when the REST API
# does not answer (k6 not up yet or already gone).
fetch_metrics() {
    curl -q -sf --max-time 2 -o "$load_state_dir/metrics.tmp" \
        "http://$k6_address/v1/metrics" || return 1
    mv "$load_state_dir/metrics.tmp" "$load_state_dir/metrics.json"
}

# Prints one stats line (compact JSON) built from the latest metrics snapshot,
# or from no metrics at all when k6 never answered.
build_line() {
    snapshot="$load_state_dir/metrics.json"
    if [ ! -s "$snapshot" ]; then
        printf '{"data":[]}' > "$snapshot"
    fi
    jq -c --arg runId "$GATEWAY_LOAD_RUN_ID" --arg index "$GATEWAY_LOAD_INDEX" '
        def num: if type == "string" then (tonumber? // .) else . end;
        {
            runId: ($runId | tonumber),
            index: ($index | tonumber),
            at: (now | floor | todate),
            vus: ([.data[]? | select(.id == "vus") | .attributes.sample.value | num
                   | select(type == "number")] | first // 0),
            metrics: ([.data[]? | {
                key: .id,
                value: ({type: .attributes.type}
                    + ((.attributes.sample // {})
                       | map_values(num) | with_entries(select(.value | type == "number"))))
            }] | sort_by(.key) | from_entries)
        }' "$snapshot"
}

# Posts stats line file $1 to GATEWAY_LOAD_STATS_URL, or prints it when the
# URL is empty. Returns 0 to continue and 1 when the gateway answers stop.
deliver_line() {
    if [ -z "${GATEWAY_LOAD_STATS_URL:-}" ]; then
        cat "$1"
        return 0
    fi
    body="$load_state_dir/response.json"
    rm -f "$body"
    status="$(printf 'header = "X-Gateway-Load-Token: %s"\n' "$load_token_conf" |
        curl -q -s --max-time 10 -K - -o "$body" -w '%{http_code}' \
            -H 'Content-Type: application/json' --data-binary "@$1" \
            -- "$GATEWAY_LOAD_STATS_URL")"
    curl_code=$?
    if [ "$curl_code" -ne 0 ]; then
        load_log "stats post failed: curl exit $curl_code"
        return 0
    fi
    case "$status" in
        409) return 1 ;;
        2??)
            if jq -e '.action == "stop"' "$body" >/dev/null 2>&1; then
                return 1
            fi
            return 0
            ;;
        *)
            load_log "stats post failed: HTTP $status"
            return 0
            ;;
    esac
}

# Builds a stats line from the latest snapshot and delivers it; returns 1
# when the gateway answers stop.
report_once() {
    line="$load_state_dir/line.json"
    if ! build_line > "$line"; then
        load_log "could not build the stats line; skipped"
        return 0
    fi
    deliver_line "$line"
}

# Returns 0 while k6 has not exited.
k6_running() {
    kill -0 "$k6_pid" 2>/dev/null
}

# Waits until k6 has exited and sets k6_code to its exit code. A trapped
# signal interrupts wait early, so it is repeated while k6 still runs.
wait_k6() {
    while :; do
        wait "$k6_pid"
        k6_code=$?
        if ! k6_running; then
            return 0
        fi
    done
}

# Ends a run on a stop answer, a 409 or a signal: sends k6 SIGTERM, waits for
# it, delivers one final line and exits 0.
stop_run() {
    fetch_metrics || true
    kill -TERM "$k6_pid" 2>/dev/null || true
    wait_k6
    report_once || true
    exit 0
}

# Ends a run when k6 exits on its own: delivers one final line and exits with
# k6's exit code.
finish_run() {
    wait_k6
    report_once || true
    exit "$k6_code"
}

# Every second, handles a stop signal or the end of k6 and refreshes the
# metrics snapshot; every report_interval seconds, delivers a stats line,
# skipping that tick when the metrics GET failed.
report_loop() {
    next_report=$(($(date +%s) + report_interval))
    while :; do
        sleep 1
        if [ "$stop_requested" -eq 1 ]; then
            stop_run
        fi
        if ! k6_running; then
            finish_run
        fi
        fetched=0
        if fetch_metrics; then
            fetched=1
        fi
        now=$(date +%s)
        if [ "$now" -ge "$next_report" ]; then
            next_report=$((now + report_interval))
            if [ "$fetched" -eq 1 ] && ! report_once; then
                stop_run
            fi
        fi
    done
}

if [ -n "${GATEWAY_LOAD_RUN_ID:-}" ]; then
    if [ "${1:-}" = "--load-run" ]; then
        load_run
    fi
    load_prepare
fi

decode_script GATEWAY_JOB_SCRIPT "${GATEWAY_JOB_SCRIPT:-}" "$script_path" 0700

# The script body is on disk now; keep it out of the job's environment.
unset GATEWAY_JOB_SCRIPT

printf 'gateway-job: name=%s run_id=%s\n' "${GATEWAY_JOB_NAME:-unknown}" "${GATEWAY_JOB_RUN_ID:-unknown}"

exec bash -e "$script_path"
