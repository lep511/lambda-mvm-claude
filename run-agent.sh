#!/usr/bin/env bash
# Run the Claude Code agent over ./input/ inside a MicroVM.
#
# What the agent DOES is not in this script: it is in ./agent-prompt.md, which
# is uploaded with every run. Rewrite that file and the same image performs a
# different job — no rebuild. This script uploads the input and the prompt,
# launches the MicroVM, hands the agent the job, and then watches S3 for the
# result. The agent shuts its own VM down when it is done.
#
# Everything the agent leaves in its output/ directory comes back under
# ./output/<run-id>/. Nothing else leaves the VM.
#
# Prereqs:
#   AWS_REGION, AWS_ACCOUNTID            (workshop bootstrap)
#   ./grant-permissions.sh               (once per account)
#   agent/build-image.sh                 (the MicroVM image)
#
# Usage:
#   ./run-agent.sh                       # upload ./input/ + ./agent-prompt.md and run
#   ./run-agent.sh --prompt FILE         # use a different task definition
#   ./run-agent.sh --var KEY=VALUE       # fill a {{KEY}} placeholder (repeatable)
#   ./run-agent.sh --rerun <run-id>      # re-run over an earlier run's input
#   ./run-agent.sh --fetch <run-id>      # re-download a finished run's artifacts
#   ./run-agent.sh --keep                # do not reap the VM if the job fails
set -euo pipefail

cd "$(dirname "$0")"

# Args are parsed before the env-var checks so --help works in a bare shell.
UPLOAD=1
FETCH_ID=""
DOCS_RUN_ID=""
KEEP=0
PROMPT_FILE="${PROMPT_FILE:-agent-prompt.md}"
VARS_JSON='{}'
while [[ $# -gt 0 ]]; do
  case "$1" in
    # The task definition. A library of these is the point: --prompt
    # prompts/translate.md runs a different job against the same image.
    --prompt)    PROMPT_FILE="${2:?--prompt needs a file}"; shift 2 ;;
    # Placeholder value, e.g. --var LANGUAGE=en. Substituted into the prompt
    # as {{LANGUAGE}} by the runtime; unknown keys are harmless.
    --var)
      VAR_ARG="${2:?--var needs KEY=VALUE}"
      [[ "${VAR_ARG}" == *=* ]] || { echo "--var wants KEY=VALUE, got: ${VAR_ARG}"; exit 2; }
      VARS_JSON=$(jq --arg k "${VAR_ARG%%=*}" --arg v "${VAR_ARG#*=}" \
        '.[$k] = $v' <<<"${VARS_JSON}")
      shift 2 ;;
    # Reuse an earlier run's uploaded input. The output still goes to a fresh
    # run id: writing it back over the old one would leave the previous
    # _status.json in place, and the polling loop would return the stale
    # result before the new job had even started. The prompt is NOT reused —
    # the current one is uploaded, which is what makes "same input, new task"
    # a one-liner.
    --rerun)     DOCS_RUN_ID="${2:?--rerun needs a run id}"; UPLOAD=0; shift 2 ;;
    --fetch)     FETCH_ID="${2:?--fetch needs a run id}"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    # basename, not $0: the cd above invalidates a relative $0.
    -h|--help)   sed -n '2,24p' "$(basename "$0")" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)"; exit 2 ;;
  esac
done

: "${AWS_REGION:?AWS_REGION must be set (should be pre-populated by the workshop bootstrap)}"
: "${AWS_ACCOUNTID:?AWS_ACCOUNTID must be set (should be pre-populated by the workshop bootstrap)}"

# Pull in AGENT_IMAGE_ARN if this shell was open before build-image.sh ran.
if [[ -f /etc/profile.d/claude-agent-image.sh ]]; then
  # shellcheck disable=SC1091
  source /etc/profile.d/claude-agent-image.sh
fi

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-workshop-artifacts-${AWS_ACCOUNTID}}"
IMAGE_NAME="${IMAGE_NAME:-mvm-claude-agent}"

# What build-image.sh last built WINS over an ambient IMAGE_VERSION, and the
# ordering is the whole point. A rebuild bumps 1.0 → 2.0 and leaves the old
# version SUCCESSFUL, so running the wrong one is silent: the job works, it just
# runs yesterday's code. The README tells you to `set -a; source .env`, and any
# shell that did that while .env still carried IMAGE_VERSION=1.0 keeps
# exporting it for the rest of its life — which would pin every run to 1.0
# forever. To pin an old version deliberately, set AGENT_IMAGE_VERSION: it is
# the variable these scripts actually read.
# Captured before resolving, so a stale pin can be reported instead of silently
# dropped — being quiet about it is how you end up debugging the wrong code.
IMAGE_VERSION_PINNED="${IMAGE_VERSION:-}"
IMAGE_VERSION="${AGENT_IMAGE_VERSION:-${IMAGE_VERSION_PINNED:-1.0}}"
if [[ -n "${IMAGE_VERSION_PINNED}" && "${IMAGE_VERSION_PINNED}" != "${IMAGE_VERSION}" ]]; then
  echo "NOTE: ignoring IMAGE_VERSION=${IMAGE_VERSION_PINNED} from the environment"
  echo "      (stale export, probably from 'source .env'); using ${IMAGE_VERSION},"
  echo "      which is what build-image.sh last built. To pin on purpose:"
  echo "      AGENT_IMAGE_VERSION=${IMAGE_VERSION_PINNED} ./run-agent.sh"
fi
LOG_GROUP="/aws/lambda-microvms/${IMAGE_NAME}"
PORT=9000

# Default for the prompt's {{LANGUAGE}} placeholder. Launch-time, so switching
# language needs no rebuild; an explicit --var LANGUAGE= wins over it.
if [[ -n "${AGENT_LANGUAGE:-}" ]]; then
  VARS_JSON=$(jq --arg v "${AGENT_LANGUAGE}" \
    'if has("LANGUAGE") then . else .LANGUAGE = $v end' <<<"${VARS_JSON}")
fi

# The MicroVM runs as this role: the only workshop role with
# bedrock:InvokeModel*, and the one grant-permissions.sh adds S3 and
# TerminateMicrovm to.
MVM_EXECUTION_ROLE_ARN="${MVM_EXECUTION_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/Module2ReviewerBuildRole-workshop}"

# Backstop for a VM that crashes before it can terminate itself. The agent
# receives no inbound request while it works, so this window has to outlast a
# whole run or it would reap the VM mid-job.
MVM_MAX_IDLE_SECONDS="${MVM_MAX_IDLE_SECONDS:-1800}"

# How long to watch for a result, in 10-second polls (150 = 25 min).
POLL_ATTEMPTS="${POLL_ATTEMPTS:-150}"

# Local directories. Absolute, because the paths are printed for the
# participant to open or copy and the script has already cd'd into its own
# directory — a relative path would be wrong from wherever they invoked it.
INPUT_DIR="$(pwd)/input"
OUTPUT_DIR="$(pwd)/output"

# Set by fetch_result so the end of the script can report what landed where.
# Intentionally not `local` to that function.
RESULT_DIR=""
ARTIFACT_COUNT=0
SINGLE_ARTIFACT=""

run_prefix() { echo "s3://${ARTIFACTS_BUCKET}/claude-agent/runs/$1"; }

fetch_result() {
  # $1 = run id. Downloads every artifact and prints the status. Returns
  # non-zero if the run failed or has not produced a status yet.
  local rid="$1" prefix status preview
  prefix="$(run_prefix "${rid}")"
  if ! status=$(aws s3 cp "${prefix}/output/_status.json" - \
      --region "${AWS_REGION}" 2>/dev/null); then
    return 2
  fi
  if [[ "$(jq -r '.success' <<<"${status}")" != "true" ]]; then
    echo ""
    echo "ERROR: the agent reported a failure"
    jq . <<<"${status}"
    return 1
  fi

  RESULT_DIR="${OUTPUT_DIR}/${rid}"
  mkdir -p "${RESULT_DIR}"
  # _status.json is the plumbing's completion signal, not an artifact, so it
  # is left in S3 rather than cluttering the result directory.
  aws s3 cp "${prefix}/output/" "${RESULT_DIR}/" \
    --recursive --exclude '_status.json' \
    --region "${AWS_REGION}" --only-show-errors

  ARTIFACT_COUNT="$(jq -r '.artifact_count // 0' <<<"${status}")"
  SINGLE_ARTIFACT="$(jq -r '.artifacts[0].key // empty' <<<"${status}")"

  echo ""
  echo "==> done in $(jq -r '.duration_s' <<<"${status}")s"
  echo "    inputs     $(jq -r '.input_count' <<<"${status}")"
  echo "    model      $(jq -r '.model' <<<"${status}")"
  echo "    prompt     $(jq -r '.prompt_source' <<<"${status}")"
  echo "    artifacts  ${ARTIFACT_COUNT}"
  jq -r '.artifacts[]? | "      \(.key) (\(.bytes) bytes)"' <<<"${status}"
  # Both of these mean the run is worth looking at even though it succeeded.
  jq -r 'if .claude_error then "    NOTE: the CLI exited non-zero but still produced files: \(.claude_error)" else empty end' <<<"${status}"
  jq -r 'if .artifacts_skipped then "    NOTE: not returned: \(.artifacts_skipped | map("\(.key) (\(.reason))") | join(", "))" else empty end' <<<"${status}"

  # Preview the first text artifact, stopping before a markdown table starts:
  # a table cut mid-rows renders as a broken fragment, which reads like the
  # file itself is truncated.
  preview="$(jq -r '[.artifacts[]?.key | select(test("\\.(md|markdown|txt)$"))][0] // empty' <<<"${status}")"
  if [[ -n "${preview}" && -f "${RESULT_DIR}/${preview}" ]]; then
    echo ""
    head -n 25 "${RESULT_DIR}/${preview}" | awk '/^\|/{exit} {print}'
    echo "    [...]"
  fi
  return 0
}

report_path() {
  echo ""
  if [[ "${ARTIFACT_COUNT}" == "1" && -n "${SINGLE_ARTIFACT}" ]]; then
    echo "Result saved to:"
    echo "  ${RESULT_DIR}/${SINGLE_ARTIFACT}"
  else
    echo "Results saved to:"
    echo "  ${RESULT_DIR}/"
  fi
}

# ── --fetch: just re-download a finished run ─────────────────────────────────
if [[ -n "${FETCH_ID}" ]]; then
  echo "==> fetching run ${FETCH_ID}"
  rc=0; fetch_result "${FETCH_ID}" || rc=$?
  if [[ "${rc}" -eq 2 ]]; then
    echo "No _status.json for ${FETCH_ID} — it never finished, or the id is wrong."
    echo "  aws s3 ls $(run_prefix "${FETCH_ID}")/ --recursive"
    exit 1
  fi
  [[ "${rc}" -eq 0 ]] && report_path
  exit "${rc}"
fi

: "${AGENT_IMAGE_ARN:?AGENT_IMAGE_ARN not set. Run agent/build-image.sh first.}"

if [[ ! -f "${PROMPT_FILE}" ]]; then
  echo "ERROR: no prompt file at ${PROMPT_FILE}"
  echo "That file is the agent's task — it is what tells it what to do."
  echo "Restore ./agent-prompt.md, or point at another one:"
  echo "  ./run-agent.sh --prompt prompts/my-task.md"
  exit 1
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
PREFIX="$(run_prefix "${RUN_ID}")"

# Where the input comes from: this run by default, an earlier one with --rerun.
# The artifacts always land under this run's own prefix.
DOCS_PREFIX="$(run_prefix "${DOCS_RUN_ID:-$RUN_ID}")"

echo "==> run        ${RUN_ID}"
echo "    image      ${AGENT_IMAGE_ARN}"
# Printed because a run against the wrong version is otherwise invisible.
echo "    version    ${IMAGE_VERSION}"
echo "    exec role  ${MVM_EXECUTION_ROLE_ARN}"
echo "    prompt     ${PROMPT_FILE}"
echo "    vars       $(jq -c . <<<"${VARS_JSON}")"
echo "    input      ${DOCS_PREFIX}/input"
echo "    output     ${PREFIX}/output"

# Fail early rather than launching a VM that will find nothing to read.
# Tested on the output rather than the exit code: `aws s3 ls` on an empty
# prefix exits 1 on this CLI version, but that has not always been true.
if [[ -n "${DOCS_RUN_ID}" ]]; then
  if [[ -z "$(aws s3 ls "${DOCS_PREFIX}/input/" --region "${AWS_REGION}" 2>/dev/null)" ]]; then
    echo ""
    echo "ERROR: no input under ${DOCS_PREFIX}/input/"
    echo "Check the run id, or list what is there:"
    echo "  aws s3 ls s3://${ARTIFACTS_BUCKET}/claude-agent/runs/"
    exit 1
  fi
fi

# ── 1. upload the prompt and the input ───────────────────────────────────────
# The prompt goes up on every run, including --rerun: it is job input, not
# image content, so editing it and re-running is the whole edit loop.
echo "==> uploading the task prompt"
aws s3 cp "${PROMPT_FILE}" "${PREFIX}/agent-prompt.md" \
  --region "${AWS_REGION}" --only-show-errors

if [[ "${UPLOAD}" -eq 1 ]]; then
  # Every file, whatever it is: what the agent can read is the prompt's
  # business and the toolbox's, not this script's. Dotfiles (.gitkeep) are
  # skipped so an untouched directory still counts as empty.
  mapfile -t INPUTS < <(find "${INPUT_DIR}" -type f -not -name '.*' -printf '%P\n' 2>/dev/null | sort)
  if [[ "${#INPUTS[@]}" -eq 0 ]]; then
    echo ""
    echo "ERROR: no files in ./input/"
    echo "Put what you want the agent to work on there, then run this again:"
    echo "  cp /path/to/*.pdf ${INPUT_DIR}/"
    exit 1
  fi

  echo "==> uploading ${#INPUTS[@]} input file(s)"
  aws s3 cp "${INPUT_DIR}/" "${PREFIX}/input/" \
    --recursive \
    --exclude '.*' --exclude '*/.*' \
    --region "${AWS_REGION}" \
    --only-show-errors
  for f in "${INPUTS[@]}"; do echo "    ${f}"; done
fi

# ── 2. launch the MicroVM ────────────────────────────────────────────────────
# Once the job is dispatched the agent owns the VM's lifetime, so the trap
# below only cleans up VMs that never got a job — killing a dispatched one
# would abort a run that is working fine.
MVM_ID=""
DISPATCHED=0
cleanup() {
  if [[ -n "${MVM_ID}" && "${DISPATCHED}" -eq 0 && "${KEEP}" -eq 0 ]]; then
    echo "==> reaping un-dispatched ${MVM_ID}"
    aws lambda-microvms terminate-microvm \
      --microvm-identifier "${MVM_ID}" \
      --region "${AWS_REGION}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> launching microvm"
RUN=$(aws lambda-microvms run-microvm \
  --region "${AWS_REGION}" \
  --image-identifier "${AGENT_IMAGE_ARN}" \
  --image-version "${IMAGE_VERSION}" \
  --ingress-network-connectors \
    "arn:aws:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:HTTP_INGRESS" \
  --egress-network-connectors \
    "arn:aws:lambda:${AWS_REGION}:aws:network-connector:aws-network-connector:INTERNET_EGRESS" \
  --execution-role-arn "${MVM_EXECUTION_ROLE_ARN}" \
  --idle-policy "{\"maxIdleDurationSeconds\":${MVM_MAX_IDLE_SECONDS},\"suspendedDurationSeconds\":60,\"autoResumeEnabled\":false}" \
  --output json)

MVM_ID=$(jq -r '.microvmId' <<<"${RUN}")
ENDPOINT=$(jq -r '.endpoint' <<<"${RUN}")
if [[ -z "${MVM_ID}" || "${MVM_ID}" == "null" ]]; then
  echo "ERROR: run-microvm returned no microvmId"; echo "${RUN}"; exit 1
fi
echo "    microvmId  ${MVM_ID}"

# ── 3. wait for RUNNING ──────────────────────────────────────────────────────
echo "==> waiting for RUNNING (snapshot restore, usually <10s)"
STATE=""
for _ in $(seq 1 60); do
  STATE=$(aws lambda-microvms get-microvm \
    --microvm-identifier "${MVM_ID}" --region "${AWS_REGION}" \
    --query 'state' --output text 2>/dev/null || echo "PENDING")
  case "${STATE}" in
    RUNNING) break ;;
    FAILED|TERMINATED)
      echo "ERROR: microvm reached ${STATE}"
      aws lambda-microvms get-microvm --microvm-identifier "${MVM_ID}" --region "${AWS_REGION}"
      exit 1 ;;
    *) sleep 2 ;;
  esac
done
if [[ "${STATE}" != "RUNNING" ]]; then
  echo "ERROR: never reached RUNNING (last state=${STATE})"; exit 1
fi

# ── 4. auth token ────────────────────────────────────────────────────────────
TOKEN=$(aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier "${MVM_ID}" \
  --expiration-in-minutes 60 \
  --allowed-ports "[{\"port\":${PORT}}]" \
  --region "${AWS_REGION}" \
  --query 'authToken."X-aws-proxy-auth"' --output text)
if [[ -z "${TOKEN}" || "${TOKEN}" == "None" ]]; then
  echo "ERROR: no auth token issued"; exit 1
fi

# ── 5. dispatch the job ──────────────────────────────────────────────────────
# Both headers are required; X-aws-proxy-port must be in the token's
# allowedPorts. microvm_id is what lets the agent terminate itself afterwards.
# The payload is built with jq so a prompt path or a --var value containing
# quotes cannot break the JSON.
PAYLOAD=$(jq -n \
  --arg run_id     "${RUN_ID}" \
  --arg input_uri  "${DOCS_PREFIX}/input" \
  --arg output_uri "${PREFIX}/output" \
  --arg prompt_uri "${PREFIX}/agent-prompt.md" \
  --arg region     "${AWS_REGION}" \
  --arg microvm_id "${MVM_ID}" \
  --argjson vars   "${VARS_JSON}" \
  '{run_id:$run_id, input_uri:$input_uri, output_uri:$output_uri,
    prompt_uri:$prompt_uri, region:$region, microvm_id:$microvm_id, vars:$vars}')

echo "==> dispatching the job"
RESP=$(curl -X POST -sS -m 60 -w '\n%{http_code}' \
  -H "X-aws-proxy-auth: ${TOKEN}" \
  -H "X-aws-proxy-port: ${PORT}" \
  -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" \
  "https://${ENDPOINT}/run")

CODE=$(tail -n1 <<<"${RESP}")
BODY=$(sed '$d' <<<"${RESP}")
if [[ "${CODE}" != "202" ]]; then
  echo "ERROR: the agent did not accept the job (${CODE}): ${BODY}"
  exit 1
fi
DISPATCHED=1
echo "    accepted; the agent will terminate its own VM when finished"

# ── 6. watch for the result ──────────────────────────────────────────────────
# _status.json is the only completion signal, and the agent writes it before
# terminating itself — on the failure path too, so this loop ends on a real
# outcome rather than on its own timeout.
echo "==> waiting for the agent (usually 2-10 min)"
rc=2
for i in $(seq 1 "${POLL_ATTEMPTS}"); do
  rc=0; fetch_result "${RUN_ID}" || rc=$?
  [[ "${rc}" -ne 2 ]] && break
  if (( i % 6 == 0 )); then
    echo "    still working ($((i * 10))s)"
  fi
  sleep 10
done

if [[ "${rc}" -eq 2 ]]; then
  echo ""
  echo "ERROR: no result after $((POLL_ATTEMPTS * 10))s."
  echo "The agent's own logs are the place to look:"
  echo "  aws logs tail ${LOG_GROUP} --since 30m"
  echo "Re-check this run later with:  ./run-agent.sh --fetch ${RUN_ID}"
  echo "The VM reaps itself after ${MVM_MAX_IDLE_SECONDS}s idle; to stop it now:"
  echo "  aws lambda-microvms terminate-microvm --microvm-identifier ${MVM_ID}"
  exit 1
fi

# ── 7. confirm the VM is gone ────────────────────────────────────────────────
# The agent is supposed to have terminated itself. Verify rather than assume —
# a VM left running is a bill, and a silent self-termination failure is
# exactly the kind of thing that only shows up on the invoice.
FINAL=$(aws lambda-microvms get-microvm \
  --microvm-identifier "${MVM_ID}" --region "${AWS_REGION}" \
  --query 'state' --output text 2>/dev/null || echo "GONE")
case "${FINAL}" in
  TERMINATED|TERMINATING|GONE)
    echo "    microvm ${FINAL,,} (agent shut itself down)" ;;
  *)
    echo "    WARNING: microvm is still ${FINAL} — self-termination did not happen."
    echo "    Check that grant-permissions.sh granted lambda:TerminateMicrovm."
    if [[ "${KEEP}" -eq 0 ]]; then
      echo "    terminating it now"
      aws lambda-microvms terminate-microvm \
        --microvm-identifier "${MVM_ID}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
    fi ;;
esac

echo "    agent logs: aws logs tail ${LOG_GROUP} --since 30m"

if [[ "${rc}" -ne 0 ]]; then exit "${rc}"; fi

# Last line of a successful run: the thing the participant actually came for.
report_path
