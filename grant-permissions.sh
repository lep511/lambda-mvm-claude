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
      }
    ]
  }"

echo "Done. ${ROLE_NAME} can now list, read and write under ${PREFIX}/,"
echo "and terminate the MicroVM it runs in."
echo ""
echo "Verify:"
echo "  aws iam get-role-policy --role-name ${ROLE_NAME} --policy-name ${POLICY_NAME}"
