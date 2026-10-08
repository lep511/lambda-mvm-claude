#!/usr/bin/env bash
# One-command image build for the claude-agent runtime.
#
# The image is task-agnostic: Claude Code plus a toolbox, with ../agent-prompt.md
# baked in as the FALLBACK task. run-agent.sh uploads the live prompt with every
# run, so changing what the agent does needs no rebuild — only changing the
# toolbox (new apt package), the model, or a default below does.
#
# Prereqs (all pre-populated by the workshop's code editor bootstrap):
#   AWS_REGION, AWS_ACCOUNTID, ARTIFACTS_BUCKET, MODULE2_REVIEWER_BUILD_ROLE_ARN
#
# On success, persists AGENT_IMAGE_ARN to /etc/profile.d/claude-agent-image.sh
# so every subsequent shell (and ../run-agent.sh) picks it up.
set -euo pipefail

cd "$(dirname "$0")"

: "${AWS_REGION:?AWS_REGION must be set (should be pre-populated by the workshop bootstrap)}"
: "${AWS_ACCOUNTID:?AWS_ACCOUNTID must be set (should be pre-populated by the workshop bootstrap)}"
: "${MODULE2_REVIEWER_BUILD_ROLE_ARN:?MODULE2_REVIEWER_BUILD_ROLE_ARN must be set (should be pre-populated by the workshop bootstrap)}"

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-workshop-artifacts-${AWS_ACCOUNTID}}"
IMAGE_NAME="${IMAGE_NAME:-mvm-claude-agent}"

# The version is NOT an input here: the service assigns it — 1.0 for a new
# image, and the next major for each update (the first rebuild yields 2.0, not
# 1.1, so do not assume the scheme). This script discovers it from the API
# response and persists it, which is what keeps a rebuild from being deployed
# as "1.0" while the new code sits in a later version.
IMAGE_ID_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNTID}:microvm-image:${IMAGE_NAME}"

# Task baked into the image as the fallback. Same default AND same base
# directory as run-agent.sh: PROMPT_FILE is interpreted relative to the lab
# root (claude-agent/), never to this script's directory.
#
# That is not pedantry. .env is meant to be sourced with `set -a`, so a
# PROMPT_FILE line there is exported into the shell and read by both scripts —
# but run-agent.sh cd's to the lab root while this script cd's to agent/, so a
# bare relative path would resolve to two different files and one of them would
# not exist. One variable, one meaning.
LAB_ROOT="$(cd .. && pwd)"
PROMPT_FILE="${PROMPT_FILE:-agent-prompt.md}"

# Claude Code uses Bedrock via IAM role credentials — no API key needed.
# The execution role attached to the MicroVM has bedrock:InvokeModel*.
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-opus-5}"

# Default for the prompt's {{LANGUAGE}} placeholder. A run can override it
# without rebuilding: ../run-agent.sh --var LANGUAGE=en
AGENT_LANGUAGE="${AGENT_LANGUAGE:-es}"

# 2048 MiB is the value every other lab in this workshop runs on. Node plus a
# large input set can want more; raise this if the agent dies mid-run. Both
# prompts in prompts/ work one file at a time, so their peak stays bounded.
MVM_MEMORY_MIB="${MVM_MEMORY_MIB:-2048}"

# Seconds for one `claude -p` run, and how many times to retry a non-zero exit
# (transient Bedrock errors). app.py reads both from its own environment, so
# they have to be baked in below — setting them in the shell that runs this
# script would otherwise have no effect inside the VM.
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1500}"
CLAUDE_MAX_ATTEMPTS="${CLAUDE_MAX_ATTEMPTS:-3}"

# Claude Code session tracing -> in-VM otelcol -> CloudWatch (../TELEMETRY.md).
# AGENT_TRACING=0 builds an untraced image: both Claude Code switches go off
# together, which is also how app.py knows not to start the collector. One knob
# rather than two, because one of the two on its own is the silent-failure
# shape — instrumented-looking image, no spans.
AGENT_TRACING="${AGENT_TRACING:-1}"

# Detailed beta tracing, off by default. It adds the request's new context, the
# system prompt preview and the model's output to the spans, and for `claude -p`
# sessions it needs no org allowlisting — but it is a PAIR of variables, and
# setting it moves delivery of logs AND traces to BETA_TRACING_ENDPOINT instead
# of the configured exporters. That is why the endpoint is hard-coded to the
# in-VM collector here rather than left to the caller: anywhere else and both
# signals disappear with no error.
AGENT_TRACING_DETAILED="${AGENT_TRACING_DETAILED:-0}"
if [[ "${AGENT_TRACING_DETAILED}" == "1" && "${AGENT_TRACING}" != "1" ]]; then
  echo "NOTE: ignoring AGENT_TRACING_DETAILED=1 because AGENT_TRACING=${AGENT_TRACING}"
  echo "      (detailed tracing is an addition to telemetry, not a substitute)"
  AGENT_TRACING_DETAILED=0
fi

# --environment-variables is a map, so it takes ONE comma-separated argument.
MVM_ENV_VARS="CLAUDE_CODE_USE_BEDROCK=1"
MVM_ENV_VARS+=",ANTHROPIC_MODEL=${ANTHROPIC_MODEL}"
MVM_ENV_VARS+=",AGENT_LANGUAGE=${AGENT_LANGUAGE}"
MVM_ENV_VARS+=",CLAUDE_TIMEOUT=${CLAUDE_TIMEOUT}"
MVM_ENV_VARS+=",CLAUDE_MAX_ATTEMPTS=${CLAUDE_MAX_ATTEMPTS}"
MVM_ENV_VARS+=",CLAUDE_CODE_ENABLE_TELEMETRY=${AGENT_TRACING}"
MVM_ENV_VARS+=",CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=${AGENT_TRACING}"
if [[ "${AGENT_TRACING_DETAILED}" == "1" ]]; then
  MVM_ENV_VARS+=",ENABLE_BETA_TRACING_DETAILED=1"
  MVM_ENV_VARS+=",BETA_TRACING_ENDPOINT=http://127.0.0.1:4318"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
S3_KEY="deployments/${IMAGE_NAME}-${TIMESTAMP}.zip"

case "${PROMPT_FILE}" in
  /*) CANDIDATES=("${PROMPT_FILE}") ;;
  # Lab root first — that is the canonical meaning. This script's own directory
  # second, so an older exported '../agent-prompt.md' still resolves instead of
  # becoming a confusing failure.
  *)  CANDIDATES=("${LAB_ROOT}/${PROMPT_FILE}" "${PROMPT_FILE}") ;;
esac

PROMPT_PATH=""
for candidate in "${CANDIDATES[@]}"; do
  if [[ -f "${candidate}" ]]; then PROMPT_PATH="${candidate}"; break; fi
done

if [[ -z "${PROMPT_PATH}" ]]; then
  echo "ERROR: no prompt file for PROMPT_FILE=${PROMPT_FILE}"
  echo "Looked in:"
  for candidate in "${CANDIDATES[@]}"; do echo "    ${candidate}"; done
  echo "PROMPT_FILE is relative to the lab root (claude-agent/), the same as it"
  echo "is for run-agent.sh. For example:"
  echo "    PROMPT_FILE=prompts/xls-analysis.md ./build-image.sh"
  exit 1
fi

# Checked here rather than left to the build: the Dockerfile COPYs this file, so
# its absence fails server-side as a generic "Build workflow was interrupted by
# an exception" with no log — two minutes spent to learn nothing.
if [[ ! -f requirements.txt ]]; then
  echo "ERROR: no requirements.txt next to the Dockerfile"
  echo "It declares app.py's own dependencies, i.e. boto3>=1.43.0, without which"
  echo "the runtime cannot upload artifacts or terminate its own VM. (The agent's"
  echo "libraries are not in here — it installs those itself with uv, per run.)"
  exit 1
fi

# Same reasoning for the collector config: the Dockerfile COPYs it, and without
# it every run would succeed and silently lose its trace.
if [[ ! -f otel-collector.yaml ]]; then
  echo "ERROR: no otel-collector.yaml next to the Dockerfile"
  echo "app.py starts otelcol-contrib with it to SigV4-forward Claude Code's"
  echo "spans to CloudWatch. See ../TELEMETRY.md, or build without tracing:"
  echo "    AGENT_TRACING=0 ./build-image.sh"
  exit 1
fi

echo "==> model      ${ANTHROPIC_MODEL}"
echo "    language   ${AGENT_LANGUAGE} (default; overridable per run)"
echo "    memory     ${MVM_MEMORY_MIB} MiB"
echo "    timeout    ${CLAUDE_TIMEOUT}s (max ${CLAUDE_MAX_ATTEMPTS} attempts)"
# The resolved path, not the raw value: which file actually got baked in is the
# thing you want in the log when a fallback task turns out to be the wrong one.
echo "    prompt     ${PROMPT_PATH} (baked in as the fallback task)"
# The runtime's dependencies only, installed into the /opt/agent-runtime venv.
# The agent's own libraries are not counted here and never were baked: it
# installs them with uv during the run, which is why this number stays at 1.
echo "    runtime    $(grep -cvE '^\s*(#|$)' requirements.txt) package(s) from requirements.txt (app.py's own; the agent installs its own with uv)"
if [[ "${AGENT_TRACING}" == "1" ]]; then
  if [[ "${AGENT_TRACING_DETAILED}" == "1" ]]; then
    echo "    telemetry  traces + metrics + events, DETAILED spans (see ../TELEMETRY.md)"
  else
    echo "    telemetry  traces + metrics + events (see ../TELEMETRY.md)"
  fi
else
  echo "    telemetry  OFF (AGENT_TRACING=${AGENT_TRACING}) — no signals, no collector"
fi

# The Dockerfile COPYs the prompt by a fixed name, so a PROMPT_FILE with any
# other name is staged under that name rather than renamed in place.
echo "==> zipping source"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp "${PROMPT_PATH}" "${STAGE}/agent-prompt.md"

rm -f claude-agent.zip
zip -qr claude-agent.zip app.py Dockerfile requirements.txt otel-collector.yaml
zip -qj claude-agent.zip "${STAGE}/agent-prompt.md"

echo "==> uploading to s3://${ARTIFACTS_BUCKET}/${S3_KEY}"
aws s3 cp claude-agent.zip "s3://${ARTIFACTS_BUCKET}/${S3_KEY}" \
  --region "${AWS_REGION}"

# create-microvm-image refuses a name that already exists, so a rebuild has to
# go through update-microvm-image, which adds a new VERSION to the same image.
# Every other argument is identical between the two calls, hence one array.
IMAGE_ARGS=(
  --code-artifact "uri=s3://${ARTIFACTS_BUCKET}/${S3_KEY}"
  --base-image-arn "arn:aws:lambda:${AWS_REGION}:aws:microvm-image:al2023-1"
  --build-role-arn "${MODULE2_REVIEWER_BUILD_ROLE_ARN}"
  --environment-variables "${MVM_ENV_VARS}"
  --region "${AWS_REGION}"
  --hooks '{"port":9000,"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":5,"terminate":"ENABLED","terminateTimeoutInSeconds":5},"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":60}}'
  --egress-network-connectors "arn:aws:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
  --resources "[{\"minimumMemoryInMiB\":${MVM_MEMORY_MIB}}]"
  --logging "{\"cloudWatch\":{\"logGroup\":\"/aws/lambda-microvms/${IMAGE_NAME}\"}}"
)

# Empty when the image does not exist yet — that is the create case.
image_state() {
  aws lambda-microvms get-microvm-image \
    --image-identifier "${IMAGE_ID_ARN}" --region "${AWS_REGION}" \
    --query 'state' --output text 2>/dev/null || true
}

# An update is only accepted from a settled state; mid-transition it fails with
# "Cannot update MicroVM Image in its current state". Waiting is better than
# handing that error to a participant who just edited a Dockerfile. Note that a
# *create* that collides on the name has been seen to leave the existing image
# in DELETING, which is the other reason not to call create blindly.
STATE_NOW="$(image_state)"
for _ in $(seq 1 30); do
  case "${STATE_NOW}" in
    ""|None|CREATED|UPDATED|CREATE_FAILED|UPDATE_FAILED|DELETE_FAILED) break ;;
    *) echo "    image is ${STATE_NOW}; waiting for it to settle"
       sleep 10
       STATE_NOW="$(image_state)" ;;
  esac
done

if [[ -n "${STATE_NOW}" && "${STATE_NOW}" != "None" ]]; then
  echo "==> image exists (${STATE_NOW}); adding a new version"
  RESP=$(aws lambda-microvms update-microvm-image \
    --image-identifier "${IMAGE_ID_ARN}" "${IMAGE_ARGS[@]}")
  ACTION="update-microvm-image"
else
  echo "==> creating microvm image"
  RESP=$(aws lambda-microvms create-microvm-image \
    --name "${IMAGE_NAME}" "${IMAGE_ARGS[@]}")
  ACTION="create-microvm-image"
fi

IMAGE_ARN=$(jq -r '.imageArn' <<<"${RESP}")
if [[ -z "${IMAGE_ARN}" || "${IMAGE_ARN}" == "null" ]]; then
  echo "ERROR: ${ACTION} returned no imageArn"
  echo "Response: $RESP"
  exit 1
fi

# The version this build produced. Everything downstream must poll and run
# THIS one — an update leaves the previous version in place and still
# SUCCESSFUL, so defaulting to 1.0 would quietly keep running the old code.
BUILT_VERSION=$(jq -r '.imageVersion // empty' <<<"${RESP}")
if [[ -z "${BUILT_VERSION}" ]]; then
  echo "ERROR: ${ACTION} returned no imageVersion"
  echo "Response: $RESP"
  exit 1
fi
echo "    imageArn=${IMAGE_ARN}"
echo "    version=${BUILT_VERSION}"

echo "==> waiting for build to complete (typically 90-120s)"
while true; do
  STATE=$(aws lambda-microvms get-microvm-image-version \
    --image-identifier "${IMAGE_ARN}" \
    --image-version "${BUILT_VERSION}" \
    --region "${AWS_REGION}" \
    --query 'state' --output text 2>/dev/null || echo "PENDING")
  echo "    state=${STATE}"
  case "${STATE}" in
    SUCCESSFUL) break ;;
    FAILED)
      # The bare state is not enough to act on, and the service deletes the
      # image resource on failure — so grab the reason while it is still
      # readable by exact version. Build output goes to the log group below
      # when the build gets far enough to produce any.
      echo ""
      echo "Image build FAILED. Reason:"
      aws lambda-microvms get-microvm-image-version \
        --image-identifier "${IMAGE_ARN}" \
        --image-version "${BUILT_VERSION}" \
        --region "${AWS_REGION}" \
        --query 'stateReason' --output text 2>/dev/null \
        | sed 's/^/    /' || echo "    (no stateReason available)"
      echo ""
      echo "Per-chipset builds:"
      aws lambda-microvms list-microvm-image-builds \
        --image-identifier "${IMAGE_ARN}" \
        --image-version "${BUILT_VERSION}" \
        --region "${AWS_REGION}" \
        --query 'items[].[chipsetGeneration,buildState,stateReason]' \
        --output text 2>/dev/null | sed 's/^/    /' || true
      echo ""
      echo "Build output, if the build produced any:"
      echo "    aws logs tail /aws/lambda-microvms/${IMAGE_NAME} --since 30m"
      echo ""
      echo "A generic \"interrupted by an exception\" with no log group usually"
      echo "means a step in the Dockerfile hung rather than failed."
      exit 1 ;;
    *)          sleep 10 ;;
  esac
done

# Persist for downstream scripts and future shells. The version goes with the
# ARN: test-image.sh and run-agent.sh default to it, so the thing just built is
# the thing that runs.
sudo tee /etc/profile.d/claude-agent-image.sh >/dev/null <<EOF
export AGENT_IMAGE_ARN="${IMAGE_ARN}"
export AGENT_IMAGE_VERSION="${BUILT_VERSION}"
EOF
sudo chmod 644 /etc/profile.d/claude-agent-image.sh
export AGENT_IMAGE_ARN="${IMAGE_ARN}"
export AGENT_IMAGE_VERSION="${BUILT_VERSION}"

echo ""
echo "Agent image built: ${IMAGE_ARN} (version ${BUILT_VERSION})"
echo "Persisted to /etc/profile.d/claude-agent-image.sh for future shells."
echo ""
echo "Next: ./test-image.sh   (smoke test, no Bedrock tokens spent)"
echo "Editing ../agent-prompt.md does NOT need another build — it is uploaded per run."
