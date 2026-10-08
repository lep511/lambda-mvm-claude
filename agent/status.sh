#!/usr/bin/env bash
# What is this run doing right now?
#
# A run is silent while it works: app.py logs when it starts `claude` and then
# nothing until the agent exits, so "is it stuck or is it thinking?" cannot be
# answered from the log group alone. This script answers it from the four
# places that do know — the MicroVM's state, the run's log group, the spans the
# agent is emitting (../TELEMETRY.md), and what has landed in S3 — and it
# prints the one number that actually decides the outcome: how long is left
# before CLAUDE_TIMEOUT kills the attempt.
#
# Read-only. It launches nothing, terminates nothing and writes nothing.
#
# Usage:
#   ./status.sh                  # the run still in flight (newest without _status.json)
#   ./status.sh 20261008-122452  # a specific run, finished or not
#   ./status.sh --help
#
# With no id it picks the newest run whose output/ has no _status.json, because
# that file is this lab's only completion signal — its absence IS "still
# running". A RUNNING MicroVM is reported alongside as corroboration, not as
# the source of truth: a VM can outlive its job (idlePolicy) and a job can
# outlive nothing at all.
set -euo pipefail

cd "$(dirname "$0")"

# Args before the env checks so --help works in a bare shell, like the other
# scripts in this lab.
RUN_ID=""
for arg in "$@"; do
  case "$arg" in
    # basename, not $0: the cd above invalidates a relative $0.
    -h|--help) sed -n '2,23p' "$(basename "$0")" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $arg (try --help)"; exit 2 ;;
    *) RUN_ID="$arg" ;;
  esac
done

: "${AWS_REGION:?AWS_REGION must be set (should be pre-populated by the workshop bootstrap)}"
: "${AWS_ACCOUNTID:?AWS_ACCOUNTID must be set (should be pre-populated by the workshop bootstrap)}"

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-workshop-artifacts-${AWS_ACCOUNTID}}"
IMAGE_NAME="${IMAGE_NAME:-mvm-claude-agent}"
LOG_GROUP="/aws/lambda-microvms/${IMAGE_NAME}"
RUNS_PREFIX="claude-agent/runs"
# Same default as build-image.sh bakes in. Only used to work out the deadline,
# so a mismatch misreports the countdown and nothing else.
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1500}"
SPANS_LOG_GROUP="aws/spans"

now_ms() { echo $(( $(date +%s) * 1000 )); }
# Local time, because every other timestamp a participant sees (the log group,
# the run id) is in the VM's clock, which is UTC in this workshop.
fmt_ms() { date -u -d "@$(( $1 / 1000 ))" +"%H:%M:%S"; }

# ── 1. which run ─────────────────────────────────────────────────────────────
# One listing, then everything is decided locally: the alternative is a
# head-object per candidate, which is slower and racier.
ALL_KEYS="$(aws s3api list-objects-v2 \
  --bucket "${ARTIFACTS_BUCKET}" --prefix "${RUNS_PREFIX}/" \
  --region "${AWS_REGION}" --query 'Contents[].Key' --output json 2>/dev/null || echo 'null')"

if [[ "${ALL_KEYS}" == "null" ]]; then
  echo "ERROR: cannot list s3://${ARTIFACTS_BUCKET}/${RUNS_PREFIX}/"
  echo "Check the bucket name and your credentials:"
  echo "  aws s3 ls s3://${ARTIFACTS_BUCKET}/${RUNS_PREFIX}/ --region ${AWS_REGION}"
  exit 1
fi

# Run ids are timestamps, so a lexicographic sort is chronological. "Finished"
# is defined exactly as run-agent.sh defines it: output/_status.json exists.
RUN_SUMMARY="$(jq -n --argjson keys "${ALL_KEYS}" --arg p "${RUNS_PREFIX}/" '
  ($keys // []) as $k
  | [$k[] | select(startswith($p)) | ltrimstr($p) | split("/")[0] | select(length > 0)] | unique as $all
  | [$k[] | select(endswith("/output/_status.json")) | ltrimstr($p) | split("/")[0]] | unique as $done
  | {all: $all, done: $done, pending: ($all - $done)}')"

if [[ -z "${RUN_ID}" ]]; then
  RUN_ID="$(jq -r '.pending | sort | last // empty' <<<"${RUN_SUMMARY}")"
  if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="$(jq -r '.all | sort | last // empty' <<<"${RUN_SUMMARY}")"
    [[ -n "${RUN_ID}" ]] || { echo "no runs under s3://${ARTIFACTS_BUCKET}/${RUNS_PREFIX}/"; exit 1; }
    echo "==> no run in flight; showing the most recent one: ${RUN_ID}"
  else
    echo "==> run in flight: ${RUN_ID} (newest without _status.json)"
  fi
else
  jq -e --arg r "${RUN_ID}" '.all | index($r)' <<<"${RUN_SUMMARY}" >/dev/null 2>&1 || {
    echo "ERROR: no run ${RUN_ID} under s3://${ARTIFACTS_BUCKET}/${RUNS_PREFIX}/"
    echo "Known runs:"
    jq -r '.all | sort | reverse | .[:10] | .[] | "  " + .' <<<"${RUN_SUMMARY}"
    exit 1
  }
  echo "==> run ${RUN_ID}"
fi

PREFIX="s3://${ARTIFACTS_BUCKET}/${RUNS_PREFIX}/${RUN_ID}"
FINISHED=0
jq -e --arg r "${RUN_ID}" '.done | index($r)' <<<"${RUN_SUMMARY}" >/dev/null 2>&1 && FINISHED=1

# Inputs, from S3 rather than from ../input/: the local directory may have
# moved on since the run was launched, and what matters is what the agent got.
INPUT_FILES="$(jq -n --argjson keys "${ALL_KEYS}" --arg p "${RUNS_PREFIX}/${RUN_ID}/input/" '
  [($keys // [])[] | select(startswith($p)) | ltrimstr($p) | select(length > 0)]')"
INPUT_COUNT="$(jq 'length' <<<"${INPUT_FILES}")"
echo "    input      ${INPUT_COUNT} file(s)"
echo "    s3         ${PREFIX}/"

# ── 2. the MicroVM ───────────────────────────────────────────────────────────
VMS="$(aws lambda-microvms list-microvms --region "${AWS_REGION}" --output json 2>/dev/null || echo '{}')"
RUNNING="$(jq -r '[.items[]? | select(.state == "RUNNING" or .state == "STARTING")]' <<<"${VMS}")"
RUNNING_N="$(jq 'length' <<<"${RUNNING}")"
if [[ "${RUNNING_N}" -gt 0 ]]; then
  # The age is computed with `date`, not jq's fromdate: startedAt comes back as
  # 2026-10-08T12:24:56.093000+00:00, and jq's ISO8601 parser rejects both the
  # fractional seconds and the offset — it would fail the whole line and print
  # a VM with no state at all.
  jq -r '.[] | [.microvmId, .state, (.imageVersion // "?"), .startedAt] | @tsv' <<<"${RUNNING}" \
  | while IFS=$'\t' read -r vm_id vm_state vm_image vm_started; do
      up="?"
      if started_epoch="$(date -u -d "${vm_started}" +%s 2>/dev/null)"; then
        up="$(( ( $(date +%s) - started_epoch ) / 60 ))m"
      fi
      printf "    vm         %s  state=%s  image=%s  up=%s\n" \
        "${vm_id}" "${vm_state}" "${vm_image}" "${up}"
    done
else
  echo "    vm         none running"
fi

# ── 3. the run's own log lines ───────────────────────────────────────────────
# Only the handful app.py emits around the agent: the rest of the group is the
# collector's startup chatter and HTTP noise, which is not progress.
LOG_START="$(( $(now_ms) - 7200000 ))"   # two hours is more than CLAUDE_TIMEOUT allows
EVENTS="$(aws logs filter-log-events \
  --log-group-name "${LOG_GROUP}" --start-time "${LOG_START}" \
  --region "${AWS_REGION}" --output json 2>/dev/null || echo '{}')"

echo "==> timeline"
jq -r '
  [.events[]? | select(.message
     | test("claude attempt|collector listening|collector did not open|telemetry drained|downloading input|input file\\(s\\)|uploaded [0-9]+ artifact|wrote _status|terminating|no telemetry was produced"))]
  | if length == 0 then "    (nothing yet — the VM may still be booting)"
    else .[] | "    " + ((.timestamp / 1000) | strftime("%H:%M:%S")) + "  "
      + ((.message | fromjson? | .message) // (.message | gsub("\n$"; "") | .[0:120]))
    end' <<<"${EVENTS}"

# The deadline, from the attempt that is actually running. A timeout is
# terminal in run_claude (not retried), so this number is the difference
# between "artifacts delivered" and "CSVs but no report".
CLAUDE_MS="$(jq -r '[.events[]? | select(.message | test("claude attempt")) | .timestamp] | last // empty' <<<"${EVENTS}")"
if [[ -n "${CLAUDE_MS}" && "${FINISHED}" -eq 0 ]]; then
  DEADLINE_MS=$(( CLAUDE_MS + CLAUDE_TIMEOUT * 1000 ))
  LEFT_S=$(( (DEADLINE_MS - $(now_ms)) / 1000 ))
  echo "==> clock"
  echo "    claude     running for $(( ( $(now_ms) - CLAUDE_MS ) / 60000 ))m (since $(fmt_ms "${CLAUDE_MS}") UTC)"
  if [[ "${LEFT_S}" -gt 0 ]]; then
    echo "    deadline   $(fmt_ms "${DEADLINE_MS}") UTC — $(( LEFT_S / 60 ))m $(( LEFT_S % 60 ))s left (CLAUDE_TIMEOUT=${CLAUDE_TIMEOUT}s)"
  else
    echo "    deadline   PASSED at $(fmt_ms "${DEADLINE_MS}") UTC — the attempt should have been killed"
    echo "               a timeout is terminal: whatever reached output/ is still uploaded"
  fi
fi

# ── 4. progress, from the agent's own spans ──────────────────────────────────
# This is the only view of what the agent is DOING mid-run. It needs tracing in
# the image and Transaction Search in the account; both are in ../TELEMETRY.md,
# and their absence is reported rather than treated as an error.
SPANS="$(aws logs filter-log-events \
  --log-group-name "${SPANS_LOG_GROUP}" --start-time "${LOG_START}" \
  --filter-pattern "\"${RUN_ID}\"" \
  --region "${AWS_REGION}" --output json 2>/dev/null || echo '{}')"

SPAN_N="$(jq '[.events[]?] | length' <<<"${SPANS}")"
echo "==> agent activity (spans)"
if [[ "${SPAN_N}" -eq 0 ]]; then
  echo "    none for this run id in ${SPANS_LOG_GROUP}"
  echo "    tracing off, Transaction Search not ACTIVE, or the first spans are"
  echo "    under a minute old — see ../TELEMETRY.md"
else
  jq -r --argjson inputs "${INPUT_FILES}" '
    [.events[]? | .message | (fromjson? // empty)] as $s
    | [$s[] | select(.name == "claude_code.llm_request")] as $llm
    | [$s[] | select(.name == "claude_code.tool")] as $tools
    | [$tools[] | .attributes.full_command // ""] as $cmds
    | ($inputs | map(select(. as $f | $cmds | any(contains($f))))) as $touched
    | "    turns      \($llm | length) LLM round trip(s), \($tools | length) tool call(s)",
      "    tools      " + ([$tools[] | .attributes.tool_name // "?"] | group_by(.) | map("\(.[0])×\(length)") | join(", ")),
      "    output     \([$llm[] | .attributes.output_tokens // 0] | add // 0) token(s), cache read \([$llm[] | .attributes.cache_read_tokens // 0] | add // 0)",
      "    files      \($touched | length)/\($inputs | length) touched" + (if (($inputs - $touched) | length) > 0 then "  pending: " + (($inputs - $touched) | join(", ")) else "" end),
      "    last call  " + (($tools | last | .attributes.full_command // .attributes.tool_name // "?") | gsub("\n"; " ") | .[0:110])
  ' <<<"${SPANS}"
fi

# ── 5. what has actually been delivered ──────────────────────────────────────
# Artifacts only exist in S3 after `claude` exits — app.py uploads output/ in
# one go — so an empty list mid-run is normal and not a warning sign.
echo "==> artifacts"
OUT="$(aws s3 ls "${PREFIX}/output/" --recursive --region "${AWS_REGION}" 2>/dev/null || true)"
if [[ -z "${OUT}" ]]; then
  echo "    nothing uploaded yet (output/ is uploaded when the agent exits)"
else
  awk '{ printf "    %10s  %s\n", $3, $4 }' <<<"${OUT}"
fi

if [[ "${FINISHED}" -eq 1 ]]; then
  echo "==> _status.json"
  aws s3 cp "${PREFIX}/output/_status.json" - --region "${AWS_REGION}" 2>/dev/null \
    | jq -r '"    success    \(.success)",
             "    duration   \((.duration_s // 0) / 60 | floor)m \(((.duration_s // 0) % 60) | floor)s",
             "    artifacts  \(.artifact_count // 0) from \(.artifacts_source // "?")",
             "    model      \(.model // "?")",
             (if .trace_id then "    trace      \(.trace_id)  (one trace per run; see ../TELEMETRY.md)" else empty end),
             (if .error then "    error      \(.error)" else empty end),
             (if .claude_error then "    claude     \(.claude_error)" else empty end)'
  echo ""
  echo "Fetch it with:  cd .. && ./run-agent.sh --fetch ${RUN_ID}"
else
  echo ""
  echo "Still working. Next:"
  echo "  ./status.sh ${RUN_ID}                  # run this again"
  echo "  aws logs tail ${LOG_GROUP} --since 15m --follow"
  echo "  cd .. && ./run-agent.sh --fetch ${RUN_ID}   # once _status.json exists"
fi
