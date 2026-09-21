#!/usr/bin/env bash
# Guard: refuse to promote a candidate image that was not scanned.
#
# The scan job lives in the caller's workflow, not in this one, so the promote
# job has no `needs` edge it could depend on and nothing structurally stops a
# vulnerable image from being retagged as the release. The caller has to hand
# the scan job's `result` in through the `scan-result` input, and this guard is
# what makes forgetting to do so loud instead of silent: an empty result is
# treated as a refusal, not as permission.
#
# Exit codes: 0 the candidate may be promoted (scan passed, or the caller
# opted out with require-scan), 1 promotion refused.
#
# Env:
#   REQUIRE_SCAN  "true" demands a successful scan verdict; anything else
#                 promotes without one
#   SCAN_RESULT   the caller's scan job result; empty means none was passed
#
# Runner-provided: GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${REQUIRE_SCAN?REQUIRE_SCAN must be set}"
: "${SCAN_RESULT?SCAN_RESULT must be set}"

if [[ "${REQUIRE_SCAN}" != "true" ]]; then
  echo "::notice title=Promotion::require-scan is off; promoting without a scan verdict."
  exit 0
fi

if [[ "${SCAN_RESULT}" == "success" ]]; then
  echo "Candidate was scanned and the scan passed."
  exit 0
fi

if [[ -z "${SCAN_RESULT}" ]]; then
  echo "::error title=Promotion refused::No scan result was passed. The scan runs in your workflow, so this one cannot depend on it directly — pass the scan job's result through the 'scan-result' input, or set 'require-scan: false' if this artifact has no scan."
  REASON="no \`scan-result\` was passed. The scan runs in your workflow, so this one cannot depend on it directly — pass the scan job's \`result\` through the \`scan-result\` input, or set \`require-scan: false\` if this artifact has no scan."
else
  echo "::error title=Promotion refused::The scan did not succeed (result: ${SCAN_RESULT}). Refusing to promote an image that failed or skipped its scan."
  REASON="the scan job reported \`${SCAN_RESULT}\`, not \`success\`. Fix the scan, or justify its findings in \`ignored-cves.yml\`, before promoting."
fi
{
  echo "### 🚫 Promotion refused"
  echo ""
  echo "The candidate image has not been promoted: ${REASON}"
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
exit 1
