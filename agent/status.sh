#!/usr/bin/env bash
# What is this run doing right now?
#
# A run is silent while it works: app.py logs when it starts `claude` and then
# nothing until the agent exits, so "is it stuck or is it thinking?" cannot be
# answered from the log group alone. This script answers it from the places
# that do know — the MicroVM's state, this run's own log lines, the spans the
# agent is emitting (../TELEMETRY.md), and what has landed in S3 — and it
# prints the one number that actually decides the outcome: how long is left
# before CLAUDE_TIMEOUT kills the attempt.
#
# It also answers the two questions that cost the most time to answer by hand:
# WHICH task is running, which the run's own record cannot say (every prompt is
# staged under the same key), and whether the telemetry is reaching CloudWatch
# — which fails silently by construction, so nothing else ever mentions it.
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
    -h|--help) sed -n '2,28p' "$(basename "$0")" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $arg (try --help)"; exit 2 ;;
    *) RUN_ID="$arg" ;;
  esac
done

: "${AWS_REGION:?AWS_REGION must be set. Copy ../.env.example to ../.env, fill it in, then: set -a; source .env; set +a}"
: "${AWS_ACCOUNTID:?AWS_ACCOUNTID must be set. Copy ../.env.example to ../.env, fill it in, then: set -a; source .env; set +a}"

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-claude-artifacts-${AWS_ACCOUNTID}}"
IMAGE_NAME="${IMAGE_NAME:-mvm-claude-agent}"
LOG_GROUP="/aws/lambda-microvms/${IMAGE_NAME}"
RUNS_PREFIX="claude-agent/runs"
# Same default as build-image.sh bakes in. Only used to work out the deadline,
# so a mismatch misreports the countdown and nothing else.
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1500}"
SPANS_LOG_GROUP="aws/spans"

now_ms() { echo $(( $(date +%s) * 1000 )); }
# UTC, because every other timestamp on screen (the log group, the run id) is
# in the VM's clock, which is UTC. Mixing the two is how a run looks like it
# started hours ago.
fmt_ms() { date -u -d "@$(( $1 / 1000 ))" +"%H:%M:%S"; }

# ── 1. which run ─────────────────────────────────────────────────────────────
# The VM list comes first because it decides what "in flight" can even mean: a
# pending run with no VM alive is not running, it is abandoned.
VMS="$(aws lambda-microvms list-microvms --region "${AWS_REGION}" --output json 2>/dev/null || echo '{}')"
RUNNING="$(jq -r '[.items[]? | select(.state == "RUNNING" or .state == "STARTING")]' <<<"${VMS}")"
RUNNING_N="$(jq 'length' <<<"${RUNNING}")"

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
  PENDING="$(jq -r '.pending | sort | last // empty' <<<"${RUN_SUMMARY}")"
  if [[ -n "${PENDING}" && "${RUNNING_N}" -gt 0 ]]; then
    RUN_ID="${PENDING}"
    echo "==> run in flight: ${RUN_ID} (newest without _status.json)"
  else
    # No VM alive, so nothing is in flight whatever S3 looks like. Show the
    # most recent run instead — and name the abandoned one, because a run that
    # died before writing _status.json would otherwise shadow every later run
    # here for as long as it sits in the bucket.
    RUN_ID="$(jq -r '.all | sort | last // empty' <<<"${RUN_SUMMARY}")"
    [[ -n "${RUN_ID}" ]] || { echo "no runs under s3://${ARTIFACTS_BUCKET}/${RUNS_PREFIX}/"; exit 1; }
    echo "==> no run in flight; showing the most recent one: ${RUN_ID}"
    [[ -n "${PENDING}" ]] && echo "    note: ${PENDING} has no _status.json and no VM — it never finished"
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

# Which task is this run doing? Nothing in the run's own record answers that:
# run-agent.sh stages every prompt under the same key, `agent-prompt.md`, so
# the log line and _status.json's `prompt_source` both read
# ".../runs/<id>/agent-prompt.md" whichever file in prompts/ it came from. The
# staged copy itself does answer it — its first `# ` heading is the task's
# name — and it is a few KB away. `|| true` because a run launched before the
# prompt was staged has no object here yet, and that is not an error.
TASK="$(aws s3 cp "${PREFIX}/agent-prompt.md" - --region "${AWS_REGION}" 2>/dev/null \
  | awk '/^# /{sub(/^# /, ""); print; exit}' || true)"
[[ -n "${TASK}" ]] && echo "    task       ${TASK}"

# ── 2. the MicroVM ───────────────────────────────────────────────────────────
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
# Two hours is more than CLAUDE_TIMEOUT allows a run to last, so it always
# covers a run in flight — which is what this script is for. It does not cover
# yesterday's run, and the sections below are the ones that notice: no log
# lines means no timeline, no drain line and no collector errors, i.e. silence
# about the very thing you came to ask. Hence the knob, and the hint printed
# when a run falls outside the window. Widening it costs one longer
# filter-log-events call and nothing else.
LOG_WINDOW_MIN="${STATUS_LOG_WINDOW_MIN:-120}"
LOG_START="$(( $(now_ms) - LOG_WINDOW_MIN * 60000 ))"
EVENTS="$(aws logs filter-log-events \
  --log-group-name "${LOG_GROUP}" --start-time "${LOG_START}" \
  --region "${AWS_REGION}" --output json 2>/dev/null || echo '{}')"

# The log group belongs to the IMAGE, not to a run, so everything below has to
# be narrowed to this run before it is read — two runs half an hour apart both
# land in that two-hour window. Unscoped, the timeline interleaves them and the
# deadline further down is computed from whichever `claude attempt` is newest,
# which can belong to a different run entirely.
#
# The anchor is the one line that names a run id — "downloading input from
# s3://.../runs/<id>/input". Its log stream is the VM that served this run and
# its timestamp is where the run starts; the run's own `terminating` line, when
# it has one, closes the window so a finished run cannot absorb the next one's
# output. Nothing here assumes how the service names streams: the stream
# filter narrows when there is one stream per VM, and the timestamps narrow
# either way.
ANCHOR="$(jq -c --arg r "/runs/${RUN_ID}/input" '
  [.events[]? | select(.message | contains($r)) | {stream: .logStreamName, ts: .timestamp}]
  | first // {}' <<<"${EVENTS}")"
RUN_STREAM="$(jq -r '.stream // empty' <<<"${ANCHOR}")"
RUN_FROM_MS="$(jq -r '.ts // empty' <<<"${ANCHOR}")"

RUN_EVENTS='{"events":[]}'
WINDOW_EVENTS='{"events":[]}'
if [[ -n "${RUN_FROM_MS}" ]]; then
  RUN_TO_MS="$(jq -r --argjson from "${RUN_FROM_MS}" '
    [.events[]? | select(.timestamp >= $from)
     | select(.message | test("terminating microvm")) | .timestamp] | first // empty' <<<"${EVENTS}")"
  # +10s so the lines app.py emits while shutting down stay inside the window.
  RUN_EVENTS="$(jq -c --argjson from "${RUN_FROM_MS}" --arg to "${RUN_TO_MS:-}" --arg s "${RUN_STREAM}" '
    (if $to == "" then null else ($to | tonumber) + 10000 end) as $end
    | {events: [.events[]? | select(.logStreamName == $s and .timestamp >= $from
        and ($end == null or .timestamp <= $end))]}' <<<"${EVENTS}")"
  # The collector writes to the VM's stderr, and whether that shares app.py's
  # stream is the service's business — so its lines are narrowed by time only.
  # Correct unless two runs genuinely overlap, which this lab cannot do.
  WINDOW_EVENTS="$(jq -c --argjson from "${RUN_FROM_MS}" --arg to "${RUN_TO_MS:-}" '
    (if $to == "" then null else ($to | tonumber) + 10000 end) as $end
    | {events: [.events[]? | select(.timestamp >= $from
        and ($end == null or .timestamp <= $end))]}' <<<"${EVENTS}")"
fi

echo "==> timeline"
# Only the handful app.py emits around the agent: the rest of the group is the
# collector's startup chatter and HTTP noise, which is not progress. The
# telemetry lines are deliberately not here — section 5 reads them properly,
# and a raw drain line says nothing to anyone who has not memorised it.
jq -r --argjson finished "${FINISHED}" --arg win "${LOG_WINDOW_MIN}" '
  [.events[]? | select(.message
     | test("claude attempt|collector listening|collector did not open|downloading input|input file\\(s\\)|uploaded [0-9]+ artifact|wrote _status|terminating"))]
  | if length == 0 then
      if $finished == 1 then
        "    (nothing in the last \($win)m — widen it: STATUS_LOG_WINDOW_MIN=480 ./status.sh <run-id>)"
      else "    (nothing yet — the VM may still be booting)" end
    else .[] | "    " + ((.timestamp / 1000) | strftime("%H:%M:%S")) + "  "
      + ((.message | fromjson? | .message) // (.message | gsub("\n$"; "") | .[0:120]))
    end' <<<"${RUN_EVENTS}"

# The deadline, from the attempt that is actually running — this run's latest,
# which is what the scoping above buys: read from the whole window it would be
# a newer run's attempt, and the countdown would be wrong in the reassuring
# direction. A timeout is terminal in run_claude (not retried), so this number
# is the difference between "artifacts delivered" and "CSVs but no report".
CLAUDE_MS="$(jq -r '[.events[]? | select(.message | test("claude attempt")) | .timestamp] | last // empty' <<<"${RUN_EVENTS}")"
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
  # It used to list the three possible causes here and leave the operator to
  # work out which one it was. The next section settles it instead, from the
  # run's own drain line and the collector's errors, so this one only has to
  # name the case those cannot see: spans that shipped but are not searchable
  # yet.
  echo "    either they shipped and are not searchable yet (a minute, or up to"
  echo "    10 if Transaction Search was only just enabled), or they never"
  echo "    shipped — the telemetry section below says which"
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

# ── 5. did the telemetry actually get out? ───────────────────────────────────
# Telemetry fails silently by construction (../TELEMETRY.md): four independent
# things have to be true — the image built with AGENT_TRACING=1, the xray
# actions on the role, the CloudWatch Logs actions on the role, and Transaction
# Search in this region — and not one of them is on the path of a successful
# run. The symptom is always the same, artifacts delivered and nothing to look
# at, so the section above can only ever report the absence. These two sources
# name the cause, and neither needs anything from the VM:
#
#   app.py's drain line            how much of each signal left the machine
#   the collector's own            why an exporter was refused, in the API's
#   "Exporting failed" lines       own words
#
# Whatever is still queued when the VM terminates dies with it and nothing
# retries it, which is why "sent < accepted" is not a delay to wait out — it is
# a permanent loss, and this is the only place that ever says so.
echo "==> telemetry"
TELEM_LINE="$(jq -r '
  [.events[]? | ((.message | fromjson? | .message) // .message)
   | select(test("telemetry drained|no telemetry was produced|telemetry flush timed out|collector telemetry endpoint unreachable"))]
  | last // empty' <<<"${RUN_EVENTS}")"

TRACES_LOST=0
TRACES_SHIPPED=0
TELEM_NONE=0
if [[ -z "${TELEM_LINE}" ]]; then
  if [[ -z "${RUN_FROM_MS}" ]]; then
    # No lines for this run at all, so this says nothing about its telemetry.
    echo "    unknown — no log lines for this run in the last ${LOG_WINDOW_MIN}m, so this"
    echo "    says nothing either way: STATUS_LOG_WINDOW_MIN=480 ./status.sh ${RUN_ID}"
  elif [[ "${FINISHED}" -eq 1 ]]; then
    echo "    no drain line, though the run logged — an image built with"
    echo "    AGENT_TRACING=0 leaves no collector to drain (../TELEMETRY.md)"
  else
    echo "    nothing yet — app.py drains the collector just before it terminates the VM"
  fi
else
  # "drained" is a claim about what left the machine, so only the line that
  # actually reports a drain gets to wear that label. The other three — a
  # flush that timed out, a collector that was unreachable, a run with nothing
  # to flush — are printed as they came.
  case "${TELEM_LINE}" in
    "telemetry drained: "*)
      echo "    drained    ${TELEM_LINE#telemetry drained: }" ;;
    "no telemetry was produced"*)
      TELEM_NONE=1
      echo "    flush      ${TELEM_LINE}"
      echo "               nothing was emitted, so there is nothing to chase in the"
      echo "               account: look at AGENT_TRACING in the image, or at a job"
      echo "               that failed before \`claude\` ran at all" ;;
    *)
      echo "    flush      ${TELEM_LINE}" ;;
  esac
  # Each pair is sent/accepted. A `?` for sent means that exporter publishes no
  # counter of its own, which is not evidence either way — reporting it as a
  # loss would cry wolf on every run.
  while read -r signal sent accepted; do
    [[ "${sent}" == "?" ]] && continue
    if [[ "${sent}" -lt "${accepted}" ]]; then
      printf "               %s: %d of %d never left the VM — gone with it\n" \
        "${signal}" "$(( accepted - sent ))" "${accepted}"
      [[ "${signal}" == "spans" ]] && TRACES_LOST=1
    elif [[ "${signal}" == "spans" && "${accepted}" -gt 0 ]]; then
      # Shipped in full. Remembered because it is the difference between "the
      # spans are missing" and "the spans are not searchable yet", and the
      # section above cannot tell those apart on its own.
      TRACES_SHIPPED=1
    fi
  done < <(grep -oE '[a-z]+ [0-9?]+/[0-9]+' <<<"${TELEM_LINE}" | tr '/' ' ')
fi

# The collector's refusals, grouped. One failing export writes a dozen lines —
# the message, then a Go stack trace — and a run that cannot export at all
# writes hundreds, so the raw lines are unreadable and the distinct reason is
# the only part that matters. The signal name comes from the collector's own
# `otelcol.signal` field, so a traces problem is never confused with the EMF
# metrics exporter failing for a completely different reason.
COLLECTOR_ERRS="$(jq -r '
  [.events[]? | .message | select(test("Exporting failed"))
   | { sig: (try (capture("\"otelcol.signal\": \"(?<s>[a-z]+)\"").s) catch "?"),
       why: (try (capture("Message=(?<m>[^,]{0,110})").m)
             catch (try (capture("\"error\": \"(?<e>[^\"]{0,110})").e) catch "unknown")) }]
  | group_by(.sig + .why)
  | map("    collector  \(.[0].sig): \(.[0].why) (×\(length))") | .[]' <<<"${WINDOW_EVENTS}" 2>/dev/null || true)"
[[ -n "${COLLECTOR_ERRS}" ]] && echo "${COLLECTOR_ERRS}"

# The account setting behind traces, checked only when traces are actually
# implicated — one read-only call, and asking about it on a healthy run would
# just be noise.
#
# Status=ACTIVE is NOT the thing to look at: a run in this lab lost all 159 of
# its spans to Destination=XRay with Status=ACTIVE, which reads like a healthy
# setting right up to the point you notice it names the other destination. The
# X-Ray OTLP endpoint refuses every span with an HTTP 400 while it says that,
# and the only trace of the refusal is in the collector's stderr.
TRACE_TROUBLE=0
[[ "${TRACES_LOST}" -eq 1 ]] && TRACE_TROUBLE=1
grep -q 'collector  traces:' <<<"${COLLECTOR_ERRS}" && TRACE_TROUBLE=1
# A finished run with no spans to show and no explanation above: worth the
# call. The three exclusions each mean this cannot be the account's fault —
# spans that drained in full are only waiting on ingestion (which lags, by up
# to 10 minutes right after Transaction Search is switched on); a run that
# produced no telemetry at all never reached an exporter; and a run whose log
# lines have aged out tells us nothing either way.
if [[ "${SPAN_N}" -eq 0 && "${FINISHED}" -eq 1 && "${TRACES_SHIPPED}" -eq 0 \
      && "${TELEM_NONE}" -eq 0 && -n "${RUN_FROM_MS}" ]]; then
  TRACE_TROUBLE=1
fi
if [[ "${TRACE_TROUBLE}" -eq 1 ]]; then
  XRAY_DEST="$(aws xray get-trace-segment-destination \
    --region "${AWS_REGION}" --output json 2>/dev/null || echo '{}')"
  DEST="$(jq -r '.Destination // "?"' <<<"${XRAY_DEST}")"
  DEST_STATUS="$(jq -r '.Status // "?"' <<<"${XRAY_DEST}")"
  if [[ "${DEST}" == "CloudWatchLogs" && "${DEST_STATUS}" == "ACTIVE" ]]; then
    echo "    account    trace destination CloudWatchLogs/ACTIVE — spans can be ingested"
    echo "               in ${AWS_REGION}, so the cause is on the role or in the image:"
    echo "               xray:PutTraceSegments, then AGENT_TRACING — ../TELEMETRY.md"
  else
    echo "    account    trace destination ${DEST}/${DEST_STATUS} in ${AWS_REGION} — spans"
    echo "               cannot be ingested until it is CloudWatchLogs/ACTIVE."
    # Switching the destination has a prerequisite that is easy to miss,
    # because its error names a service nobody mentioned: with no CloudWatch
    # Logs resource policy letting xray.amazonaws.com write to aws/spans,
    # update-trace-segment-destination answers "AccessDeniedException: XRay
    # does not have permission to call PutLogEvents on the aws/spans Log
    # Group". Printing the destination call on its own sends the operator
    # straight into that. One read-only call says which of the two steps is
    # actually missing; if the caller may not read resource policies, the
    # answer is unknown and both steps are the honest reply.
    POLICIES="$(aws logs describe-resource-policies \
      --region "${AWS_REGION}" --output json 2>/dev/null || echo '{}')"
    if jq -e '[.resourcePolicies[]?.policyDocument
               | select(contains("xray.amazonaws.com") and contains("aws/spans"))]
              | length > 0' <<<"${POLICIES}" >/dev/null 2>&1; then
      echo "               X-Ray may already write to aws/spans, so this is the only"
      echo "               call left:"
      echo "               aws xray update-trace-segment-destination \\"
      echo "                 --destination CloudWatchLogs --region ${AWS_REGION}"
    else
      echo "               That switch is two calls, not one: on its own it fails with"
      echo "               AccessDeniedException until a CloudWatch Logs resource policy"
      echo "               lets xray.amazonaws.com PutLogEvents into aws/spans."
      echo "               ../TELEMETRY.md step 2 has both, put-resource-policy first."
    fi
    echo "               (it bills span ingestion — ../TELEMETRY.md has the costs)"
  fi
fi

# ── 6. what it has cost so far ───────────────────────────────────────────────
# Claude Code's own cost and token counters, which reach CloudWatch as EMF
# metrics (../TELEMETRY.md). Readable mid-run: they are exported every
# OTEL_METRIC_EXPORT_INTERVAL, so this number grows while the agent works.
#
# Metrics Insights (a SELECT expression) and NOT get-metric-statistics: Claude
# Code publishes each datapoint with its full attribute set, 17 dimensions
# here, and get-metric-statistics matches only a complete dimension set —
# given `agent.run_id` alone it returns zero datapoints and no error, which
# reads exactly like telemetry that never arrived.
#
# The window is anchored on the run id rather than on "the last N hours",
# because a run id IS a timestamp (run-agent.sh uses date +%Y%m%d-%H%M%S) and
# that keeps the query small for a run from days ago.
echo "==> cost"
WINDOW_FROM=""
if [[ "${RUN_ID}" =~ ([0-9]{8})-([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
  RUN_EPOCH="$(date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}" +%s 2>/dev/null || true)"
  if [[ -n "${RUN_EPOCH:-}" ]]; then
    WINDOW_FROM="$(date -u -d "@$(( RUN_EPOCH - 300 ))" +%FT%TZ)"
    # Six hours is far more than CLAUDE_TIMEOUT allows a run to last, and
    # capping at "now" keeps an in-flight run's window honest.
    WINDOW_END_EPOCH=$(( RUN_EPOCH + 21600 ))
    [[ "${WINDOW_END_EPOCH}" -gt "$(date +%s)" ]] && WINDOW_END_EPOCH="$(date +%s)"
    WINDOW_TO="$(date -u -d "@${WINDOW_END_EPOCH}" +%FT%TZ)"
  fi
fi
if [[ -z "${WINDOW_FROM}" ]]; then
  # A run id that is not a timestamp (the smoke test's, for instance).
  WINDOW_FROM="$(date -u -d '3 hours ago' +%FT%TZ)"
  WINDOW_TO="$(date -u +%FT%TZ)"
fi

# One call per expression, and that is not a style choice: GetMetricData
# accepts exactly ONE Metrics Insights query per request and answers a second
# one with "Maximum number of queries (1) exceeded". Batching the two reads
# into a single call fails every time, while each read on its own works.
#
# bash quotes the SQL, jq builds the JSON — the two never have to agree about
# escaping, which is what makes this readable at all.
insights_sum() {
  local sql="$1" queries
  queries="$(jq -n --arg q "${sql}" '[{Id:"q", Period:300, Expression:$q}]')"
  aws cloudwatch get-metric-data \
    --start-time "${WINDOW_FROM}" --end-time "${WINDOW_TO}" \
    --metric-data-queries "${queries}" \
    --region "${AWS_REGION}" --output json 2>/dev/null \
    | jq -r '[.MetricDataResults[]?.Values[]?] | add // 0' 2>/dev/null \
    || echo 0
}

USD="$(insights_sum "SELECT SUM(\"claude_code.cost.usage\") FROM \"ClaudeCodeAgent\" WHERE \"agent.run_id\" = '${RUN_ID}'")"
TOKENS="$(insights_sum "SELECT SUM(\"claude_code.token.usage\") FROM \"ClaudeCodeAgent\" WHERE \"agent.run_id\" = '${RUN_ID}'")"
if [[ "$(jq -r 'if (. | tonumber) > 0 then "yes" else "no" end' <<<"${USD:-0}" 2>/dev/null)" == "yes" ]]; then
  printf "    spend      \$%.4f USD%s\n" "${USD}" \
    "$([[ "${FINISHED}" -eq 1 ]] && echo "" || echo " so far")"
  printf "    tokens     %.0f (all types; the span figures above are per-request)\n" "${TOKENS}"
else
  echo "    no cost metrics for this run id in namespace ClaudeCodeAgent"
  echo "    an image built before metrics were exported, AGENT_TRACING=0, or a"
  echo "    run that has not yet crossed one export interval — ../TELEMETRY.md"
fi

# ── 7. what has actually been delivered ──────────────────────────────────────
# app.py uploads output/ in one go after `claude` exits, so an empty list
# mid-run is normal and not a warning sign.
#
# The reverse is no longer a contradiction either: a task is free to put its
# own objects here while it works, and prompts/pdf-to-markdown.md does exactly
# that — it uploads each converted file itself so the SQS message it sends can
# name an object that already exists. For that kind of task this listing is
# live progress mid-run, not the final set, which is worth saying out loud
# rather than leaving an operator to wonder why a "pending" run has artifacts.
echo "==> artifacts"
OUT="$(aws s3 ls "${PREFIX}/output/" --recursive --region "${AWS_REGION}" 2>/dev/null || true)"
if [[ -z "${OUT}" ]]; then
  echo "    nothing in output/ yet (app.py uploads it when the agent exits)"
else
  awk '{ printf "    %10s  %s\n", $3, $4 }' <<<"${OUT}"
  [[ "${FINISHED}" -eq 0 ]] && \
    echo "    (still in flight: a task that delivers as it goes puts objects here early)"
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
