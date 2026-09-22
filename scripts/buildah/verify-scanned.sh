#!/usr/bin/env bash
# Guard: refuse to promote a candidate image that was not scanned clean.
#
# The scan job lives in the caller's workflow, not this one, so the promote job
# cannot list it under `needs` and cannot be skipped by its result. A skipped
# job reads as success to the caller's graph, so an `if:` condition here would
# wave a vulnerable image through silently. This runs as an ordinary step and
# fails the job instead, and treats a missing verdict the same as a bad one --
# a caller that simply forgot to wire `scan-result` must not get a free pass.
#
# Env:
#   REQUIRE_SCAN  "true" demands a successful scan verdict; anything else
#                 promotes without one
#   SCAN_RESULT   the scan job's `result`, passed through by the caller
#                 (default: empty, which is refused when REQUIRE_SCAN is true)
#
# Exit codes: 0 promotion may proceed, 1 promotion refused.
set -euo pipefail

# Unset-only guard (`?`, not `:?`): an empty REQUIRE_SCAN must keep falling
# through to the "not true" branch exactly as it did inline.
: "${REQUIRE_SCAN?REQUIRE_SCAN must be set}"
# An empty SCAN_RESULT is meaningful -- it is the "no verdict passed" case.
: "${SCAN_RESULT:=}"

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
