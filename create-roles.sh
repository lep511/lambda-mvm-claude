#!/usr/bin/env bash
# Creates everything this project needs in an AWS account that has nothing:
# the artifacts bucket, and the two IAM roles a Lambda MicroVM takes.
#
# A MicroVM takes TWO roles, for two different phases, and the split is not
# cosmetic — the docs are explicit that the build-time hooks (/ready, /validate)
# run under the build role while the runtime hooks (/run, /resume, /suspend,
# /terminate) run under the execution role. Everything app.py does happens
# inside /run, so Bedrock, S3, TerminateMicrovm and the telemetry exports all
# belong to the EXECUTION role; the build role only has to pull the source zip
# and write build logs.
#
#   build role       <- agent/build-image.sh --build-role-arn
#     s3:GetObject on deployments/*      the zip the server-side build unpacks
#     logs: 3 actions                    build logs, or the build is a black box
#
#   execution role   <- run-agent.sh / agent/test-image.sh --execution-role-arn
#     s3:ListBucket            the agent is handed a PREFIX, not a key list, so
#                              it has to enumerate it. Without this the run ends
#                              with "no input files found".
#     s3:GetObject/PutObject   the artifacts are the only thing that leaves the
#                              VM. Without Put the work happens and cannot be
#                              delivered.
#     lambda:TerminateMicrovm  there is no orchestrator, so the agent stops its
#                              own VM. Without it the VM idles until the
#                              idlePolicy window expires and the account pays
#                              for the gap.
#     bedrock:InvokeModel*     Claude Code reaches Bedrock with THIS role's
#                              credentials. Without it a run burns minutes and
#                              then 403s inside `claude -p`.
#     xray:Put*                the in-VM OTel collector SigV4-signs Claude
#                              Code's spans as this role. Without it every run
#                              still succeeds and the collector logs
#                              "Exporting failed ... 403" while no trace appears.
#     logs on /aws/claude-agent/*       cost metrics (EMF) and the event stream,
#                              the other two signals, both written through
#                              CloudWatch Logs. See ./TELEMETRY.md.
#     logs on /aws/lambda-microvms/*    the VM's own stdout — app.py's progress
#                              lines and the "telemetry drained" summary. Without
#                              it artifacts still arrive but agent/status.sh goes
#                              blind and there is nothing to tail.
#
# Both roles need a trust policy naming lambda.amazonaws.com with sts:AssumeRole
# AND sts:TagSession. Omitting TagSession is the failure that looks like a
# service bug: the role exists, the ARN is right, and the service still cannot
# assume it.
#
# Idempotent and additive: existing roles get their trust policy refreshed and
# their inline policy replaced, and an existing bucket is left alone. Undo the
# roles with --delete.
#
# Run once per account and region, before agent/build-image.sh.
set -euo pipefail

cd "$(dirname "$0")"

MODE="create"
for arg in "$@"; do
  case "${arg}" in
    --delete) MODE="delete" ;;
    -h|--help)
      cat <<'EOF'
Usage: ./create-roles.sh [--delete]

Creates the artifacts bucket and the two IAM roles this project needs:

  ClaudeAgentMicroVMBuildRole       assumed by the lambda-microvms service to
                                    build the image (reads the source zip,
                                    writes build logs)
  ClaudeAgentMicroVMExecutionRole   assumed by the running MicroVM (Bedrock, the
                                    job's S3 prefix, self-termination, the three
                                    telemetry signals)

Environment:
  AWS_ACCOUNTID            required
  AWS_REGION               required
  ARTIFACTS_BUCKET         default lambda-mvm-claude-artifacts-$AWS_ACCOUNTID
  MVM_BUILD_ROLE_ARN       default arn:...:role/ClaudeAgentMicroVMBuildRole
  MVM_EXECUTION_ROLE_ARN   default arn:...:role/ClaudeAgentMicroVMExecutionRole

The two role variables are read, not just written: set either one and this
script creates THAT role instead, so the names stay in one place (.env) for
every script in the project.

  --delete   Remove both roles and their inline policies. The bucket is left
             alone on purpose — it holds every run's input and artifacts. Empty
             and remove it deliberately with:
               aws s3 rb s3://$ARTIFACTS_BUCKET --force
EOF
      exit 0
      ;;
    *)
      echo "unknown option: ${arg}" >&2
      echo "  ./create-roles.sh --help" >&2
      exit 2
      ;;
  esac
done

: "${AWS_ACCOUNTID:?AWS_ACCOUNTID must be set. Copy .env.example to .env, fill it in, then: set -a; source .env; set +a}"
: "${AWS_REGION:?AWS_REGION must be set. Copy .env.example to .env, fill it in, then: set -a; source .env; set +a}"

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-claude-artifacts-${AWS_ACCOUNTID}}"

# Both role ARNs are inputs as well as outputs: the other scripts read the same
# two variables, so whatever .env says is what gets created. The role NAME is
# derived the same way everywhere — strip everything up to the last slash.
BUILD_ROLE_DEFAULT="arn:aws:iam::${AWS_ACCOUNTID}:role/ClaudeAgentMicroVMBuildRole"
EXEC_ROLE_DEFAULT="arn:aws:iam::${AWS_ACCOUNTID}:role/ClaudeAgentMicroVMExecutionRole"
MVM_BUILD_ROLE_ARN="${MVM_BUILD_ROLE_ARN:-${BUILD_ROLE_DEFAULT}}"
MVM_EXECUTION_ROLE_ARN="${MVM_EXECUTION_ROLE_ARN:-${EXEC_ROLE_DEFAULT}}"
BUILD_ROLE_NAME="${MVM_BUILD_ROLE_ARN##*/}"
EXEC_ROLE_NAME="${MVM_EXECUTION_ROLE_ARN##*/}"

BUILD_POLICY_NAME="ClaudeAgentBuildPolicy"
EXEC_POLICY_NAME="ClaudeAgentExecutionPolicy"

# The job layout under the bucket. ListBucket is condition-scoped to this
# prefix so the role cannot enumerate the rest of the bucket; if a future change
# moves the layout out from under claude-agent/, this condition is what starts
# denying listings.
PREFIX="claude-agent"

# An inherited value is worth saying out loud rather than silently honouring: a
# stale `export` from an earlier .env is exactly how this script would end up
# attaching its policy to somebody else's role.
if [[ "${MVM_BUILD_ROLE_ARN}" != "${BUILD_ROLE_DEFAULT}" ]]; then
  echo "NOTE: MVM_BUILD_ROLE_ARN comes from the environment, not the default."
  echo "      Acting on ${BUILD_ROLE_NAME}."
fi
if [[ "${MVM_EXECUTION_ROLE_ARN}" != "${EXEC_ROLE_DEFAULT}" ]]; then
  echo "NOTE: MVM_EXECUTION_ROLE_ARN comes from the environment, not the default."
  echo "      Acting on ${EXEC_ROLE_NAME}."
fi

# ─────────────────────────────────────────────────────────────────────────────
# --delete
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${MODE}" == "delete" ]]; then
  echo "==> deleting ${BUILD_ROLE_NAME} and ${EXEC_ROLE_NAME}"
  # An inline policy has to go before its role, and a role that is already gone
  # is a success here, not an error — --delete has to be safe to re-run after a
  # partial failure.
  aws iam delete-role-policy --role-name "${BUILD_ROLE_NAME}" \
    --policy-name "${BUILD_POLICY_NAME}" 2>/dev/null || true
  aws iam delete-role --role-name "${BUILD_ROLE_NAME}" 2>/dev/null || true
  aws iam delete-role-policy --role-name "${EXEC_ROLE_NAME}" \
    --policy-name "${EXEC_POLICY_NAME}" 2>/dev/null || true
  aws iam delete-role --role-name "${EXEC_ROLE_NAME}" 2>/dev/null || true
  echo "Done. The bucket was left alone — it holds every run's input and output:"
  echo "  aws s3 rb s3://${ARTIFACTS_BUCKET} --force"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. The bucket. First, because both role policies reference it by ARN.
# ─────────────────────────────────────────────────────────────────────────────

echo "==> bucket s3://${ARTIFACTS_BUCKET}"
if aws s3api head-bucket --bucket "${ARTIFACTS_BUCKET}" >/dev/null 2>&1; then
  echo "    already exists, leaving it alone"
else
  # us-east-1 is the one region create-bucket rejects a LocationConstraint for.
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "${ARTIFACTS_BUCKET}" \
      --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${ARTIFACTS_BUCKET}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  # Nothing here is ever served publicly: the only readers are the two roles
  # and the operator's own shell.
  aws s3api put-public-access-block \
    --bucket "${ARTIFACTS_BUCKET}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "    created"
fi

# No versioning on purpose. Every object here is disposable — a source zip named
# by timestamp, or a run's input and artifacts under its own run id — so
# versions would only accumulate storage cost for objects nothing overwrites.

# ─────────────────────────────────────────────────────────────────────────────
# 2. The roles.
# ─────────────────────────────────────────────────────────────────────────────

TRUST_POLICY="$(jq -n '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: { Service: "lambda.amazonaws.com" },
    Action: ["sts:AssumeRole", "sts:TagSession"]
  }]
}')"

ensure_role() {
  local name="$1" description="$2"
  if aws iam get-role --role-name "${name}" >/dev/null 2>&1; then
    # Refresh the trust policy rather than skipping: a role created by an
    # earlier version of this script, or by hand without sts:TagSession, looks
    # fine until the service tries to assume it.
    aws iam update-assume-role-policy \
      --role-name "${name}" \
      --policy-document "${TRUST_POLICY}"
    echo "    ${name}: exists, trust policy refreshed"
  else
    aws iam create-role \
      --role-name "${name}" \
      --description "${description}" \
      --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
    echo "    ${name}: created"
  fi
}

echo "==> roles"
ensure_role "${BUILD_ROLE_NAME}" \
  "Assumed by lambda-microvms to build the claude-agent MicroVM image"
ensure_role "${EXEC_ROLE_NAME}" \
  "Assumed by the claude-agent MicroVM at runtime"

# The build role reads one key shape and writes build logs, and that is all. The
# zip key is deployments/<image>-<timestamp>.zip (agent/build-image.sh), so the
# grant is scoped to that prefix rather than the whole bucket.
BUILD_POLICY="$(jq -n \
  --arg zips "arn:aws:s3:::${ARTIFACTS_BUCKET}/deployments/*" \
  --arg loggroups "arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/lambda-microvms/*" \
  --arg logstreams "arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/lambda-microvms/*:*" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "ReadSourceZip",
        Effect: "Allow",
        Action: ["s3:GetObject"],
        Resource: $zips
      },
      {
        Sid: "BuildLogs",
        Effect: "Allow",
        Action: ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Resource: [$loggroups, $logstreams]
      }
    ]
  }')"

# Bedrock is deliberately scoped to the model FAMILY rather than to one model
# id: ANTHROPIC_MODEL is a knob in .env, and pinning the policy to its current
# value would turn "try the cheaper model" into "re-run create-roles.sh or get a
# 403 halfway through a run". The two patterns cover both the regional profiles
# (us.anthropic.claude-*) and the global ones, whose underlying foundation-model
# ARNs carry no region at all — an IAM * matches the empty string, so
# bedrock:*::foundation-model/... matches bedrock:::foundation-model/... too.
EXEC_POLICY="$(jq -n \
  --arg bucket "arn:aws:s3:::${ARTIFACTS_BUCKET}" \
  --arg objects "arn:aws:s3:::${ARTIFACTS_BUCKET}/${PREFIX}/*" \
  --arg listprefix "${PREFIX}/*" \
  --arg profiles "arn:aws:bedrock:*:${AWS_ACCOUNTID}:inference-profile/*anthropic.claude-*" \
  --arg models "arn:aws:bedrock:*::foundation-model/anthropic.claude-*" \
  --arg agentgroups "arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/claude-agent/*" \
  --arg agentstreams "arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/claude-agent/*:*" \
  --arg vmgroups "arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/lambda-microvms/*" \
  --arg vmstreams "arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/lambda-microvms/*:*" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "ListJobPrefix",
        Effect: "Allow",
        Action: ["s3:ListBucket"],
        Resource: $bucket,
        Condition: { StringLike: { "s3:prefix": [$listprefix] } }
      },
      {
        Sid: "ReadWriteJobObjects",
        Effect: "Allow",
        Action: ["s3:GetObject", "s3:PutObject"],
        Resource: $objects
      },
      {
        Sid: "SelfTerminate",
        Effect: "Allow",
        Action: ["lambda:TerminateMicrovm"],
        Resource: "*"
      },
      {
        Sid: "InvokeClaudeModels",
        Effect: "Allow",
        Action: ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource: [$profiles, $models]
      },
      {
        Sid: "ExportSpans",
        Effect: "Allow",
        Action: ["xray:PutTraceSegments", "xray:PutTelemetryRecords"],
        Resource: "*"
      },
      {
        Sid: "ExportMetricsAndEvents",
        Effect: "Allow",
        Action: [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ],
        Resource: [$agentgroups, $agentstreams]
      },
      {
        Sid: "RuntimeLogs",
        Effect: "Allow",
        Action: [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ],
        Resource: [$vmgroups, $vmstreams]
      }
    ]
  }')"

echo "==> policies"
aws iam put-role-policy \
  --role-name "${BUILD_ROLE_NAME}" \
  --policy-name "${BUILD_POLICY_NAME}" \
  --policy-document "${BUILD_POLICY}"
echo "    ${BUILD_POLICY_NAME} on ${BUILD_ROLE_NAME}"

aws iam put-role-policy \
  --role-name "${EXEC_ROLE_NAME}" \
  --policy-name "${EXEC_POLICY_NAME}" \
  --policy-document "${EXEC_POLICY}"
echo "    ${EXEC_POLICY_NAME} on ${EXEC_ROLE_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
# 3. What the caller has to do next.
# ─────────────────────────────────────────────────────────────────────────────

cat <<EOF

Done.

  ARTIFACTS_BUCKET=${ARTIFACTS_BUCKET}
  MVM_BUILD_ROLE_ARN=${MVM_BUILD_ROLE_ARN}
  MVM_EXECUTION_ROLE_ARN=${MVM_EXECUTION_ROLE_ARN}

Those three have to be in the environment the other scripts run in. They are
the defaults, so an untouched .env needs nothing — but an .env that names
different ones, or a value still exported from an earlier shell, wins over the
default. Removing a line from .env does not unset it: check with

  echo "\${ARTIFACTS_BUCKET} | \${MVM_BUILD_ROLE_ARN} | \${MVM_EXECUTION_ROLE_ARN}"

Verify the grants:
  aws iam get-role-policy --role-name ${BUILD_ROLE_NAME} --policy-name ${BUILD_POLICY_NAME}
  aws iam get-role-policy --role-name ${EXEC_ROLE_NAME} --policy-name ${EXEC_POLICY_NAME}

Two things this script cannot do for you, both account-level and neither on the
path of a successful-looking run:

  1. Bedrock model access for \${ANTHROPIC_MODEL} in ${AWS_REGION}. IAM allows
     the call; the account still has to have the model enabled. The symptom is a
     run that works for minutes and then fails inside \`claude -p\`.
  2. Transaction Search, if you want traces. See ./TELEMETRY.md.
       aws xray get-trace-segment-destination --region ${AWS_REGION}

Then: agent/build-image.sh

A brand-new role takes a few seconds to propagate. If build-image.sh reports
that the service cannot assume it, wait and re-run — nothing is lost.
EOF
