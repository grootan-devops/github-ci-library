#!/usr/bin/env bash
# Ask Komodo to redeploy the stack and hand the execution id to the poller.
#
# By the time this runs the GitOps commit is already pushed, so every failure
# path here leaves the compose file naming an image the running stack is not
# using. That is why each one writes its own step-summary section saying so
# explicitly rather than only failing the step -- whoever reads the run needs
# to know the repository and the cluster have drifted apart, not just that a
# request returned non-2xx.
#
# curl is asked for the body and the status code separately: the body goes to
# a file so the non-2xx branch can quote what Komodo actually said, and the
# status code comes back on stdout so a 4xx is caught here rather than being
# parsed as if it were a successful response.
#
# Komodo does not always return an execution id. An accepted request without
# one is treated as asynchronous and left unverified, which is why the empty
# id is passed through as an output instead of failing.
#
# Exit codes: 0 accepted, 1 credentials absent or Komodo rejected the request.
#
# Env:
#   KOMODO_SERVER      Komodo server URL
#   STACK_NAME         Komodo stack name to redeploy
#   KOMODO_API_KEY     Komodo API key (default: empty, checked below)
#   KOMODO_API_SECRET  Komodo API secret (default: empty, checked below)
#
# Runner-provided: GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, RUNNER_TEMP.
#
# Outputs: execution_id  Komodo execution id, empty when Komodo did not give one
set -euo pipefail

# Nothing is guarded with `:?`. The validate job proves all four are present
# before this job runs, and the credential check below must stay the first
# thing that can fail: it is the one failure here that explains, in the step
# summary, that the GitOps commit is already pushed.
: "${KOMODO_SERVER:=}"
: "${STACK_NAME:=}"
: "${KOMODO_API_KEY:=}"
: "${KOMODO_API_SECRET:=}"

if [[ -z "${KOMODO_API_KEY:-}" || -z "${KOMODO_API_SECRET:-}" ]]; then
  echo "::error::KOMODO_API_KEY and KOMODO_API_SECRET are required to trigger deployment."
  {
    echo "## 🦎 Komodo GitOps Deployment Summary"
    echo ""
    echo "❌ \`KOMODO_API_KEY\` / \`KOMODO_API_SECRET\` are not configured, so \`${STACK_NAME}\` was never told to redeploy — but the GitOps commit has already been pushed, so the compose file now names an image the running stack is not using."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

echo "Triggering redeployment for Komodo stack '${STACK_NAME}'..."

BODY_FILE="${RUNNER_TEMP}/komodo-update-stack.json"
HTTP_CODE="$(curl -sSL --location \
  --output "${BODY_FILE}" --write-out '%{http_code}' \
  --request POST "${KOMODO_SERVER}/api/v1/update-stack" \
  --header "Content-Type: application/json" \
  --header "x-api-key: ${KOMODO_API_KEY}" \
  --header "x-api-secret: ${KOMODO_API_SECRET}" \
  --data "{\"name\": \"${STACK_NAME}\"}")"

RESPONSE="$(cat "${BODY_FILE}" 2>/dev/null || echo "")"
echo "Komodo update-stack response (HTTP ${HTTP_CODE}): ${RESPONSE}"

if [[ ! "${HTTP_CODE}" =~ ^2[0-9][0-9]$ ]]; then
  echo "::error::Komodo rejected the redeployment request for stack '${STACK_NAME}' (HTTP ${HTTP_CODE})."
  {
    echo "## 🦎 Komodo GitOps Deployment Summary"
    echo ""
    echo "❌ Komodo refused to redeploy \`${STACK_NAME}\` with HTTP ${HTTP_CODE}. The GitOps commit is already pushed, so the compose file names an image the running stack is not using. Komodo replied:"
    echo ""
    echo '```'
    head -c 2000 "${BODY_FILE}" 2>/dev/null || echo "(empty response body)"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

EXEC_ID="$(jq -r '.execution_id // .id // .data.execution_id // empty' <<<"${RESPONSE}" 2>/dev/null || echo "")"
if [[ -z "${EXEC_ID}" ]]; then
  echo "::notice::Komodo accepted the request (HTTP ${HTTP_CODE}) without an execution id; it will be treated as asynchronous."
fi

echo "execution_id=${EXEC_ID}" >> "${GITHUB_OUTPUT}"
