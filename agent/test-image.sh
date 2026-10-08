#!/usr/bin/env bash
# Smoke test for the claude-agent image.
#
# Launches a MicroVM from the built image, exercises every leg run-agent.sh
# depends on, then terminates it. Run this after build-image.sh and before the
# first real run — it catches the failures that otherwise surface as a job that
# never writes a _status.json, where the only evidence is buried in the
# MicroVM's log group.
#
# The check that matters most here is claude_version_as_agent. If the CLI
# starts as the unprivileged `agent` user then getuid() != 0, and the root
# gate on --dangerously-skip-permissions cannot fire. That gate is the one new
# way this lab breaks compared to module-2.1's reviewer, and it costs no
# Bedrock tokens to rule out.
#
# NOTE on the execution role: the agent needs bedrock:InvokeModel* and S3
# access to the artifacts bucket. Only Module2ReviewerBuildRole-workshop
# carries the first — the generic LambdaMicroVMExecutionRole-workshop does not,
# and yields a 403 from Bedrock partway through a run. S3 list/write comes from
# ../grant-permissions.sh.
#
# Usage:
#   ./test-image.sh            # contract checks only, no Bedrock spend
#   ./test-image.sh --full     # also runs the real task over ../input/
#   ./test-image.sh --keep     # leave the MicroVM running for poking at
set -euo pipefail

cd "$(dirname "$0")"

# Args are parsed before the env-var checks so --help works in a bare shell.
FULL=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --full) FULL=1 ;;
    --keep) KEEP=1 ;;
    # basename, not $0: the cd above invalidates a relative $0.
    -h|--help) sed -n '2,25p' "$(basename "$0")"; exit 0 ;;
    *) echo "unknown flag: $arg (try --help)"; exit 2 ;;
  esac
done

: "${AWS_REGION:?AWS_REGION must be set (should be pre-populated by the workshop bootstrap)}"
: "${AWS_ACCOUNTID:?AWS_ACCOUNTID must be set (should be pre-populated by the workshop bootstrap)}"

# Pull in AGENT_IMAGE_ARN if this shell was open before build-image.sh ran.
if [[ -f /etc/profile.d/claude-agent-image.sh ]]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/claude-agent-image.sh
fi
: "${AGENT_IMAGE_ARN:?AGENT_IMAGE_ARN not set. Run ./build-image.sh first.}"

MVM_EXECUTION_ROLE_ARN="${MVM_EXECUTION_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/Module2ReviewerBuildRole-workshop}"
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-workshop-artifacts-${AWS_ACCOUNTID}}"
# What build-image.sh last built wins over an ambient IMAGE_VERSION; see
# run-agent.sh for the full reason. Testing the previous version while believing
# you tested the new one is the failure this ordering prevents.
IMAGE_VERSION_PINNED="${IMAGE_VERSION:-}"
IMAGE_VERSION="${AGENT_IMAGE_VERSION:-${IMAGE_VERSION_PINNED:-1.0}}"
if [[ -n "${IMAGE_VERSION_PINNED}" && "${IMAGE_VERSION_PINNED}" != "${IMAGE_VERSION}" ]]; then
  echo "NOTE: ignoring a stale IMAGE_VERSION=${IMAGE_VERSION_PINNED}; testing ${IMAGE_VERSION}"
fi
IMAGE_NAME="${IMAGE_NAME:-mvm-claude-agent}"
LOG_GROUP="/aws/lambda-microvms/${IMAGE_NAME}"
PORT=9000

PASS=0
FAIL=0
pass() { echo "    [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "    [FAIL] $1"; FAIL=$((FAIL + 1)); }

MVM_ID=""
cleanup() {
  if [[ -n "${MVM_ID}" && "${KEEP}" -eq 0 ]]; then
    echo "==> terminating ${MVM_ID}"
    aws lambda-microvms terminate-microvm \
      --microvm-identifier "${MVM_ID}" \
      --region "${AWS_REGION}" >/dev/null 2>&1 || true
  elif [[ -n "${MVM_ID}" ]]; then
    echo "==> leaving ${MVM_ID} running (--keep); it self-terminates after 300s idle"
  fi
}
trap cleanup EXIT

echo "==> image      ${AGENT_IMAGE_ARN}"
echo "    version    ${IMAGE_VERSION}"
echo "    exec role  ${MVM_EXECUTION_ROLE_ARN}"

# ── 1. launch ────────────────────────────────────────────────────────────────
echo "==> running microvm"
RUN=$(aws lambda-microvms run-microvm \
  --region "${AWS_REGION}" \
  --image-identifier "${AGENT_IMAGE_ARN}" \
  --image-version "${IMAGE_VERSION}" \
  --ingress-network-connectors \
    "arn:aws:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:HTTP_INGRESS" \
  --egress-network-connectors \
    "arn:aws:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS" \
  --execution-role-arn "${MVM_EXECUTION_ROLE_ARN}" \
  --idle-policy '{"maxIdleDurationSeconds":300,"suspendedDurationSeconds":60,"autoResumeEnabled":false}' \
  --output json)

MVM_ID=$(jq -r '.microvmId' <<<"${RUN}")
ENDPOINT=$(jq -r '.endpoint' <<<"${RUN}")
if [[ -z "${MVM_ID}" || "${MVM_ID}" == "null" ]]; then
  echo "ERROR: run-microvm returned no microvmId"; echo "${RUN}"; exit 1
fi
echo "    microvmId=${MVM_ID}"
echo "    endpoint=${ENDPOINT}"

# ── 2. wait for RUNNING ──────────────────────────────────────────────────────
echo "==> waiting for RUNNING (snapshot restore, usually <10s)"
STATE=""
for i in $(seq 1 60); do
  STATE=$(aws lambda-microvms get-microvm \
    --microvm-identifier "${MVM_ID}" --region "${AWS_REGION}" \
    --query 'state' --output text 2>/dev/null || echo "PENDING")
  case "${STATE}" in
    RUNNING) pass "reached RUNNING after ${i} poll(s)"; break ;;
    FAILED|TERMINATED)
      fail "state=${STATE}"
      aws lambda-microvms get-microvm --microvm-identifier "${MVM_ID}" --region "${AWS_REGION}"
      exit 1 ;;
    *) sleep 2 ;;
  esac
done
if [[ "${STATE}" != "RUNNING" ]]; then
  fail "never reached RUNNING (last state=${STATE})"; exit 1
fi

# ── 3. auth token ────────────────────────────────────────────────────────────
echo "==> creating auth token for port ${PORT}"
TOKEN=$(aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier "${MVM_ID}" \
  --expiration-in-minutes 60 \
  --allowed-ports "[{\"port\":${PORT}}]" \
  --region "${AWS_REGION}" \
  --query 'authToken."X-aws-proxy-auth"' --output text)
[[ -n "${TOKEN}" && "${TOKEN}" != "None" ]] \
  && pass "auth token issued (${#TOKEN} chars)" \
  || { fail "no auth token"; exit 1; }

# Both headers are required; X-aws-proxy-port must be in the token's allowedPorts.
mvm_curl() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -m 90 -w '\n%{http_code}'
    -H "X-aws-proxy-auth: ${TOKEN}" -H "X-aws-proxy-port: ${PORT}")
  [[ -n "${data}" ]] && args+=(-H 'Content-Type: application/json' -d "${data}")
  curl -X "${method}" "${args[@]}" "https://${ENDPOINT}${path}"
}

# ── 4. health ────────────────────────────────────────────────────────────────
# Generous timeout: the first /health runs `claude --version` and `uv --version`
# as the agent user, which spawns a process each (both are cached afterwards).
echo "==> GET /health"
RESP=$(mvm_curl GET /health)
CODE=$(tail -n1 <<<"${RESP}")
BODY=$(sed '$d' <<<"${RESP}")
echo "    ${CODE} ${BODY}"
[[ "${CODE}" == "200" ]] && pass "health returns 200" || fail "health returned ${CODE}"

jqf() { jq -r "$1" <<<"${BODY}" 2>/dev/null; }

[[ "$(jqf '.status')" == "healthy" ]] \
  && pass "app reports healthy" || fail "app did not report healthy"

# bedrock_enabled proves CLAUDE_CODE_USE_BEDROCK=1 was baked in at image build.
[[ "$(jqf '.bedrock_enabled')" == "true" ]] \
  && pass "bedrock_enabled (CLAUDE_CODE_USE_BEDROCK baked into image)" \
  || fail "bedrock_enabled false — rebuild with --environment-variables"

# The fallback task. A job that passes no prompt_uri has nothing to do without it.
[[ "$(jqf '.prompt_baked')" == "true" ]] \
  && pass "fallback agent-prompt.md baked into the image" \
  || fail "no baked agent-prompt.md — build-image.sh did not zip it"

# Toolbox. uv is asserted because the image ships NO Python libraries — every
# task installs its own at run time — so a missing uv is not a degraded toolbox,
# it is every task failing on its first import. pdftotext is asserted because it
# is the one tool every version of this image has carried, and OCR-less PDF
# reading cannot be installed around (apt, and the agent is not root). Whether
# the ACTIVE task needs either depends on which prompt is in play, so the rest
# are reported and left to the eye; the full dict is echoed above.
[[ "$(jqf '.tools.uv')" == "true" && "$(jqf '.tools.uvx')" == "true" ]] \
  && pass "uv and uvx present (the agent can install its own libraries)" \
  || fail "uv missing — no task can install a Python library; rebuild the image"

[[ "$(jqf '.tools.pdftotext')" == "true" ]] \
  && pass "pdftotext present (poppler-utils installed)" \
  || fail "pdftotext missing — prompts/summary-docs.md cannot read any PDF"

[[ "$(jqf '.agent_user_exists')" == "true" ]] \
  && pass "non-root 'agent' user exists" \
  || fail "'agent' user missing — Dockerfile useradd did not run"

# The decisive one: the CLI must start as the unprivileged user. A version
# string means getuid() != 0, so --dangerously-skip-permissions is usable.
CLAUDE_VER="$(jqf '.claude_version_as_agent')"
case "${CLAUDE_VER}" in
  error:*|exit\ *|""|null)
    fail "claude did not start as the agent user: ${CLAUDE_VER}" ;;
  *)
    pass "claude runs as the agent user (${CLAUDE_VER})" ;;
esac

# Same question for uv, and not redundant with .tools.uv above: that one only
# says the binary exists for root. This says the user that does the installing
# can execute it — the failure mode when uv lands somewhere root-only.
UV_VER="$(jqf '.uv_version_as_agent')"
case "${UV_VER}" in
  error:*|exit\ *|""|null)
    fail "uv did not run as the agent user: ${UV_VER}" ;;
  *)
    pass "uv runs as the agent user (${UV_VER})" ;;
esac

# Tracing (../TELEMETRY.md). Checked here because a missing collector or a
# half-set pair of Claude Code switches changes nothing a run can observe: the
# job succeeds, the artifacts arrive, and the trace simply never exists. Both
# are image facts, so a failure means rebuild — or AGENT_TRACING=0 on purpose,
# which turns both of these into an expected "off".
TRACING="$(jqf '.tracing_enabled')"
if [[ "${TRACING}" == "true" ]]; then
  pass "tracing enabled (both Claude Code telemetry switches baked in)"
  [[ "$(jqf '.tools["otelcol-contrib"]')" == "true" ]] \
    && pass "otelcol-contrib present (spans can be signed and forwarded)" \
    || fail "otelcol-contrib missing — every run would lose its trace; rebuild"

  # All three signals, because they are independent and each one's absence is
  # invisible in a successful run: no metrics exporter means no cost data ever,
  # and nothing anywhere says so.
  EXPORTERS="$(jqf '[.telemetry_config.exporters.traces, .telemetry_config.exporters.metrics, .telemetry_config.exporters.logs] | join(",")')"
  [[ "${EXPORTERS}" == "otlp,otlp,otlp" ]] \
    && pass "all three signals exported (traces, metrics, events)" \
    || fail "exporters are ${EXPORTERS}, expected otlp,otlp,otlp — rebuild"

  # The content gates. Without them the telemetry still flows and says nothing
  # about what the agent actually did, which is the point of collecting it here.
  GATES="$(jqf '[.telemetry_config.content | to_entries[] | select(.value == false) | .key] | join(", ")')"
  [[ -z "${GATES}" ]] \
    && pass "content gates on (prompts, responses, tool inputs and tool output)" \
    || fail "content gates off: ${GATES} — rebuild, or accept redacted telemetry"

  # The beta pair, which is only ever coherent as a pair.
  DETAILED="$(jqf '.telemetry_config.detailed.enabled')"
  DETAILED_EP="$(jqf '.telemetry_config.detailed.endpoint')"
  if [[ "${DETAILED}" == "true" ]]; then
    [[ -n "${DETAILED_EP}" && "${DETAILED_EP}" != "null" ]] \
      && pass "detailed beta tracing on, delivering to ${DETAILED_EP}" \
      || fail "ENABLE_BETA_TRACING_DETAILED without BETA_TRACING_ENDPOINT — logs and traces would go nowhere"
  elif [[ -n "${DETAILED_EP}" && "${DETAILED_EP}" != "null" ]]; then
    fail "BETA_TRACING_ENDPOINT set without ENABLE_BETA_TRACING_DETAILED — no detailed spans, and a confusing config"
  fi
else
  echo "    NOTE: tracing_enabled=false — built with AGENT_TRACING=0, so no"
  echo "          spans will reach CloudWatch (see ../TELEMETRY.md)"
fi

echo "    model=$(jqf '.model')  default_language=$(jqf '.default_language')"

# ── 5. hook endpoint ─────────────────────────────────────────────────────────
echo "==> POST lifecycle hook path"
CODE=$(tail -n1 <<<"$(mvm_curl POST /aws/lambda-microvms/runtime/v1/resume '{}')")
[[ "${CODE}" == "200" ]] && pass "hook path returns 200" || fail "hook path returned ${CODE}"

# ── 6. /run contract ─────────────────────────────────────────────────────────
echo "==> POST /run (validation)"
CODE=$(tail -n1 <<<"$(mvm_curl POST /run '{}')")
[[ "${CODE}" == "400" ]] && pass "empty body rejected with 400" || fail "empty body returned ${CODE}"

CODE=$(tail -n1 <<<"$(mvm_curl POST /run \
  "{\"run_id\":\"t\",\"input_uri\":\"s3://x/y\",\"region\":\"${AWS_REGION}\"}")")
[[ "${CODE}" == "400" ]] && pass "missing output_uri rejected with 400" || fail "missing output_uri returned ${CODE}"

# run_id is a path component in both the workspace and S3, so a traversal
# attempt has to be refused rather than joined.
CODE=$(tail -n1 <<<"$(mvm_curl POST /run \
  "{\"run_id\":\"../escape\",\"input_uri\":\"s3://x/y\",\"output_uri\":\"s3://x/z\",\"region\":\"${AWS_REGION}\"}")")
[[ "${CODE}" == "400" ]] && pass "path-traversal run_id rejected with 400" || fail "bad run_id returned ${CODE}"

if [[ "${FULL}" -eq 0 ]]; then
  echo ""
  echo "==> ${PASS} passed, ${FAIL} failed (contract only; --full runs the real task)"
  [[ "${FAIL}" -eq 0 ]] || exit 1
  exit 0
fi

# ── 7. real run over ../input/ ───────────────────────────────────────────────
# Exercises the whole chain for real: prompt download, input download, the
# toolbox, Bedrock, artifact upload, and self-termination. microvm_id is passed
# unless --keep, so the agent shuts this VM down itself — which also means
# --full is the only way to test that grant-permissions.sh granted
# lambda:TerminateMicrovm.
mapfile -t INPUTS < <(find ../input -type f -not -name '.*' -printf '%P\n' 2>/dev/null | sort)
if [[ "${#INPUTS[@]}" -eq 0 ]]; then
  fail "--full needs at least one file in ../input/ (it is empty)"
  echo ""
  echo "==> ${PASS} passed, ${FAIL} failed"
  exit 1
fi
if [[ ! -f ../agent-prompt.md ]]; then
  fail "--full needs ../agent-prompt.md (the task definition)"
  exit 1
fi

RUN_ID="smoke-$(date +%Y%m%d-%H%M%S)"
PREFIX="s3://${ARTIFACTS_BUCKET}/claude-agent/runs/${RUN_ID}"
echo "==> uploading the prompt and ${#INPUTS[@]} input file(s) to ${PREFIX}/"
aws s3 cp ../agent-prompt.md "${PREFIX}/agent-prompt.md" \
  --region "${AWS_REGION}" --only-show-errors
aws s3 cp ../input/ "${PREFIX}/input/" --recursive \
  --exclude '.*' --exclude '*/.*' \
  --region "${AWS_REGION}" --only-show-errors

# With --keep the id is withheld so the VM survives for poking at; the
# idlePolicy still reaps it.
SELF_TERM_ID="${MVM_ID}"
[[ "${KEEP}" -eq 1 ]] && SELF_TERM_ID=""

echo "==> POST /run (run_id=${RUN_ID})"
CODE=$(tail -n1 <<<"$(mvm_curl POST /run "{
  \"run_id\":\"${RUN_ID}\",
  \"input_uri\":\"${PREFIX}/input\",
  \"output_uri\":\"${PREFIX}/output\",
  \"prompt_uri\":\"${PREFIX}/agent-prompt.md\",
  \"region\":\"${AWS_REGION}\",
  \"microvm_id\":\"${SELF_TERM_ID}\"}")")
[[ "${CODE}" == "202" ]] \
  && pass "/run accepted with 202 (returns before the work starts)" \
  || fail "/run returned ${CODE}"

# The VM logs to CloudWatch, not the response. An agentic run over a few PDFs
# is a couple of minutes.
echo "==> waiting for s3://.../${RUN_ID}/output/_status.json (up to 10 min)"
STATUS_JSON=""
for _ in $(seq 1 60); do
  if STATUS_JSON=$(aws s3 cp "${PREFIX}/output/_status.json" - \
      --region "${AWS_REGION}" 2>/dev/null); then
    break
  fi
  STATUS_JSON=""
  sleep 10
done

if [[ -z "${STATUS_JSON}" ]]; then
  fail "no _status.json after 10 min — check the log group below"
else
  echo "${STATUS_JSON}"
  if [[ "$(jq -r '.success' <<<"${STATUS_JSON}")" == "true" ]]; then
    pass "agent produced $(jq -r '.artifact_count' <<<"${STATUS_JSON}") artifact(s)"
    # Proves the per-run prompt was the one that ran, not the baked fallback.
    [[ "$(jq -r '.prompt_source' <<<"${STATUS_JSON}")" == "${PREFIX}/agent-prompt.md" ]] \
      && pass "the uploaded prompt was used (not the baked fallback)" \
      || fail "prompt came from $(jq -r '.prompt_source' <<<"${STATUS_JSON}")"
  else
    fail "agent reported failure: $(jq -r '.error' <<<"${STATUS_JSON}")"
  fi
fi

# ── 8. self-termination ──────────────────────────────────────────────────────
# The status file is written before the agent terminates itself, so give the
# shutdown a moment to land before asserting on it.
if [[ -n "${SELF_TERM_ID}" && -n "${STATUS_JSON}" ]]; then
  echo "==> checking the agent shut its own VM down"
  FINAL=""
  for _ in $(seq 1 12); do
    FINAL=$(aws lambda-microvms get-microvm \
      --microvm-identifier "${MVM_ID}" --region "${AWS_REGION}" \
      --query 'state' --output text 2>/dev/null || echo "GONE")
    case "${FINAL}" in
      TERMINATED|TERMINATING|GONE) break ;;
      *) sleep 5 ;;
    esac
  done
  case "${FINAL}" in
    TERMINATED|TERMINATING|GONE)
      pass "agent self-terminated (state=${FINAL})" ;;
    *)
      fail "still ${FINAL} — execution role is probably missing lambda:TerminateMicrovm (run ../grant-permissions.sh)" ;;
  esac
fi

echo ""
echo "==> ${PASS} passed, ${FAIL} failed"
echo "    logs: aws logs tail ${LOG_GROUP} --since 15m"
# The run's own verdict on its telemetry: app.py logs "telemetry drained:"
# right before it terminates the VM. Zero, or an absent line, is the thing to
# chase in ../TELEMETRY.md rather than hunting an empty console.
echo "    spans: aws logs filter-log-events --log-group-name ${LOG_GROUP} \\"
echo "             --filter-pattern 'telemetry drained' --region ${AWS_REGION}"
[[ "${FAIL}" -eq 0 ]] || exit 1
