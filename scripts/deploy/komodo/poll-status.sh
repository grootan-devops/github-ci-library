#!/usr/bin/env bash
# Poll a Komodo execution until it succeeds, fails, or the timeout expires.
#
# Without this the job would go green the moment Komodo accepted the request,
# which says only that the API call was received -- a stack that fails to pull
# the new image would still report a successful deployment. Polling turns the
# run's verdict into the stack's actual verdict.
#
# The timeout and interval are fixed at 300s and 10s, the same constants the
# inline block used. They are not inputs on purpose: a caller raising the
# timeout past the job's own `timeout-minutes` would only trade a clear
# TIMEOUT status for an opaque cancelled job.
#
# A status request that errors is swallowed into `{}` and read as UNKNOWN, so
# one flaky response keeps polling instead of failing the deployment; only the
# elapsed-time check ends an execution that never reaches a terminal status.
#
# An empty EXEC_ID means Komodo accepted the request asynchronously without
# giving anything to track. That is reported as ACCEPTED_ASYNC and exits 0 --
# unverified is not the same as failed, and the GitOps commit is already live.
#
# Exit codes: 0 succeeded or unverifiable, 1 Komodo reported a failure or the
# execution did not finish within the timeout.
#
# Env:
#   KOMODO_SERVER      Komodo server URL
#   STACK_NAME         Komodo stack name being deployed
#   KOMODO_API_KEY     Komodo API key (default: empty)
#   KOMODO_API_SECRET  Komodo API secret (default: empty)
#   EXEC_ID            Komodo execution id to track; empty when the trigger
#                      step did not get one (default: empty)
#
# Runner-provided: GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
#
# Outputs: status  SUCCESS, FAILED, TIMEOUT or ACCEPTED_ASYNC
set -euo pipefail

: "${KOMODO_SERVER:=}"
: "${STACK_NAME:=}"
: "${KOMODO_API_KEY:=}"
: "${KOMODO_API_SECRET:=}"
: "${EXEC_ID:=}"

if [[ -z "${EXEC_ID}" ]]; then
  echo "⚠️ Komodo accepted the request without an execution ID; completion cannot be verified."
  echo "status=ACCEPTED_ASYNC" >> "${GITHUB_OUTPUT}"
  exit 0
fi

SYNC_TIMEOUT=300
echo "Tracking Komodo execution: ${EXEC_ID} (timeout: ${SYNC_TIMEOUT}s)..."
START_TIME=$(date +%s)
POLL_INTERVAL=10
STATUS="UNKNOWN"

while true; do
  STATUS_RESP=$(curl -fsSL --location \
    --request GET "${KOMODO_SERVER}/api/v1/execution/${EXEC_ID}" \
    --header "x-api-key: ${KOMODO_API_KEY}" \
    --header "x-api-secret: ${KOMODO_API_SECRET}" 2>/dev/null || echo "{}")

  STATUS=$(echo "${STATUS_RESP}" | jq -r '.status // .data.status // empty' 2>/dev/null || echo "UNKNOWN")
  echo "Deployment status: ${STATUS}"

  case "${STATUS}" in
    SUCCESS|success|Completed|completed)
      echo "✅ Komodo stack '${STACK_NAME}' deployed successfully."
      echo "status=SUCCESS" >> "${GITHUB_OUTPUT}"
      break
      ;;
    FAILED|failed|Error|error)
      echo "::error::Komodo deployment failed. Response: ${STATUS_RESP}"
      echo "status=FAILED" >> "${GITHUB_OUTPUT}"
      {
        echo "## 🦎 Komodo GitOps Deployment Summary"
        echo ""
        echo "❌ Komodo execution \`${EXEC_ID}\` for \`${STACK_NAME}\` reported \`${STATUS}\`. Komodo replied:"
        echo ""
        echo '```json'
        head -c 2000 <<< "${STATUS_RESP}"
        echo '```'
        echo ""
      } >> "${GITHUB_STEP_SUMMARY}"
      exit 1
      ;;
    *)
      CURRENT_TIME=$(date +%s)
      ELAPSED=$((CURRENT_TIME - START_TIME))
      if [[ ${ELAPSED} -ge ${SYNC_TIMEOUT} ]]; then
        echo "::error::Komodo deployment timed out after ${SYNC_TIMEOUT}s."
        echo "status=TIMEOUT" >> "${GITHUB_OUTPUT}"
        exit 1
      fi
      echo "Waiting ${POLL_INTERVAL}s... (${ELAPSED}s elapsed)"
      sleep "${POLL_INTERVAL}"
      ;;
  esac
done
