#!/usr/bin/env bash
# Render the Terraform module test result into the run's step summary.
#
# The go test transcript only reaches an artifact, and nobody downloads one to
# find out whether the suite passed. A failed or cancelled module test also
# leaves provisioned infrastructure standing until the teardown job claims a
# runner, so the summary has to say plainly which of the two happened and that
# teardown is still owed. The tally lines and the tail of the transcript are
# enough to tell from the run page alone which test broke and why.
#
# Env:
#   OUTCOME              status of the test job -- "success", "failure",
#                        "cancelled", or whatever else the runner reports
#   TF_LOG_FILE_NAME     basename of the go test transcript inside tests/
#   GITHUB_STEP_SUMMARY  GitHub-provided; appended to
#
# Runs from the project working directory, so the transcript is read from
# tests/${TF_LOG_FILE_NAME} exactly as the inline step did.
#
# Exit codes: 0 -- reporting only, it never fails the job.
set -euo pipefail

# This script only reports, and its step runs under `if: always()`. The guards
# below use `${VAR?...}` (unset only), not the house `${VAR:?...}` (unset or
# empty): `steps.<id>.outcome` is an EMPTY string when the step never ran, and
# aborting there would turn an otherwise-green job red. The inline block this
# replaced ran under `set -u`, which also tolerated empty.
: "${OUTCOME?OUTCOME must be set}"
: "${TF_LOG_FILE_NAME?TF_LOG_FILE_NAME must be set}"

LOG="tests/${TF_LOG_FILE_NAME}"
TALLY="$(grep -aE '^(--- FAIL|--- PASS|FAIL|ok|PASS)' "${LOG}" 2>/dev/null | tail -n 15 || true)"
{
  echo "### 🌍 Terraform module test"
  echo ""
  if [[ "${OUTCOME}" == "success" ]]; then
    echo "✅ Passed."
  elif [[ "${OUTCOME}" == "failure" ]]; then
    echo "❌ Failed — the destroy job will tear down anything the test provisioned."
  elif [[ "${OUTCOME}" == "cancelled" ]]; then
    echo "🚫 Cancelled — the destroy job will tear down anything the test provisioned."
  else
    echo "Status: ${OUTCOME}"
  fi
  if [[ -n "${TALLY}" ]]; then
    echo ""
    echo '```'
    echo "${TALLY}"
    echo '```'
  fi
  if [[ "${OUTCOME}" != "success" && -s "${LOG}" ]]; then
    echo ""
    echo "<details><summary>Last of the test transcript</summary>"
    echo ""
    echo '```'
    tail -n 50 "${LOG}"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
    echo "The whole transcript is \`tf_test.log\` in the \`terraform-test-artifacts\` artifact."
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
