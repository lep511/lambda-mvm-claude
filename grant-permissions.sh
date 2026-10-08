#!/usr/bin/env bash
# Lets the claude-agent MicroVM read the job's documents, write back the
# summary, and shut itself down.
#
# The workshop's execution role (Module2ReviewerBuildRole-workshop) is
# provisioned with s3:GetObject on the artifacts bucket and nothing else,
# because its original job was to let the image build pull a source zip by
# exact key. This lab needs three more things:
#
#   s3:ListBucket          — the agent is handed a PREFIX, not a key list, so
#                            it has to enumerate it. Without this, listing
#                            fails with AccessDenied and the run ends with
#                            "no documents found".
#   s3:PutObject           — SUMMARY.md and _status.json are the only
#                            artifacts that leave the VM. Without this the
#                            agent does all the work and cannot deliver it.
#   lambda:TerminateMicrovm — there is no orchestrator to stop the VM, so the
#                            agent terminates itself when the job is done.
#                            Without this it stays up until the idlePolicy
#                            window expires and the account pays for the gap.
#   xray:PutTraceSegments   — the in-VM OTel collector SigV4-signs Claude
#   xray:PutTelemetryRecords  Code's spans to CloudWatch as this role. These
#                            are the two actions the OTLP traces endpoint
#                            authorizes against (AWS's managed equivalent is
#                            AWSXrayWriteOnlyPolicy). Without them every run
#                            still succeeds and delivers its artifacts, and
#                            the collector logs "Exporting failed ... 403"
#                            while no trace ever appears. See ./TELEMETRY.md.
#   logs:* (4 actions)      — the other two signals. Claude Code's metrics go
#                            to CloudWatch as embedded metric format and its
#                            events go to a log group, and BOTH exporters write
#                            through CloudWatch Logs — so cost, tokens and the
#                            event stream all depend on these, scoped to the
#                            two /aws/claude-agent/* groups.
#
# Additive and idempotent: it puts one inline policy on the role and touches
# nothing common.yml manages. Remove it with
#   aws iam delete-role-policy --role-name <role> --policy-name MicroVMClaudeAgentS3-workshop
#
# Run once per workshop account, before agent/build-image.sh.
set -euo pipefail

: "${AWS_ACCOUNTID:?AWS_ACCOUNTID must be set (should be pre-populated by the workshop bootstrap)}"

ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-lambda-mvm-workshop-artifacts-${AWS_ACCOUNTID}}"
MVM_EXECUTION_ROLE_ARN="${MVM_EXECUTION_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNTID}:role/Module2ReviewerBuildRole-workshop}"

ROLE_NAME="${MVM_EXECUTION_ROLE_ARN##*/}"
POLICY_NAME="MicroVMClaudeAgentS3-workshop"
PREFIX="claude-agent"

echo "==> granting ${POLICY_NAME} to ${ROLE_NAME}"
echo "    bucket s3://${ARTIFACTS_BUCKET}/${PREFIX}/*"

# ListBucket is condition-scoped to the lab's prefix so the role cannot
# enumerate the rest of the artifacts bucket. If a future change moves the job
# layout out from under claude-agent/, this condition is what will start
# denying listings.
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"ListJobPrefix\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:ListBucket\"],
        \"Resource\": \"arn:aws:s3:::${ARTIFACTS_BUCKET}\",
        \"Condition\": {
          \"StringLike\": {\"s3:prefix\": [\"${PREFIX}/*\"]}
        }
      },
      {
        \"Sid\": \"ReadWriteJobObjects\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:PutObject\"],
        \"Resource\": \"arn:aws:s3:::${ARTIFACTS_BUCKET}/${PREFIX}/*\"
      },
      {
        \"Sid\": \"SelfTerminate\",
        \"Effect\": \"Allow\",
        \"Action\": [\"lambda:TerminateMicrovm\"],
        \"Resource\": \"*\"
      },
      {
        \"Sid\": \"ExportSpans\",
        \"Effect\": \"Allow\",
        \"Action\": [\"xray:PutTraceSegments\", \"xray:PutTelemetryRecords\"],
        \"Resource\": \"*\"
      },
      {
        \"Sid\": \"ExportMetricsAndEvents\",
        \"Effect\": \"Allow\",
        \"Action\": [
          \"logs:CreateLogGroup\",
          \"logs:CreateLogStream\",
          \"logs:PutLogEvents\",
          \"logs:DescribeLogStreams\"
        ],
        \"Resource\": [
          \"arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/claude-agent/*\",
          \"arn:aws:logs:*:${AWS_ACCOUNTID}:log-group:/aws/claude-agent/*:*\"
        ]
      }
    ]
  }"

echo "Done. ${ROLE_NAME} can now list, read and write under ${PREFIX}/,"
echo "terminate the MicroVM it runs in, and export traces, metrics and events"
echo "to CloudWatch."
echo ""
echo "Verify:"
echo "  aws iam get-role-policy --role-name ${ROLE_NAME} --policy-name ${POLICY_NAME}"
echo ""
echo "Spans also need Transaction Search enabled once per account/region,"
echo "which is an account setting rather than a role grant:"
echo "  aws xray get-trace-segment-destination --region ${AWS_REGION:-<region>}"
echo "See ./TELEMETRY.md for turning it on."
