#!/usr/bin/env bash
# Render the secret scan's step summary.
#
# This runs with `if: always()`, so it has to cope with the scan step having
# died before it scanned anything: SCAN_SCOPE only reaches the environment
# once the scan resolved its range, and the log may not exist at all. The
# findings excerpt is quoted only on a failure, and only from the redacted
# log -- a run summary is visible to everyone who can see the run.
#
# Env:
#   OUTCOME  the job status at this point: success, failure or cancelled
#
# Optional, exported by the scan step through GITHUB_ENV:
#   SCAN_SCOPE    what was scanned; unset means the scan never got that far
#   SCAN_COMMITS  how many commits were in scope
#
# Runner-provided: RUNNER_TEMP, GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${OUTCOME?OUTCOME must be set}"

LOG="${RUNNER_TEMP}/betterleaks.log"
FOUND="$(grep -aoE 'leaks found: [0-9]+' "${LOG}" 2>/dev/null | tail -n 1 || true)"
{
  echo "### 🔐 Secret scan"
  echo ""
  case "${OUTCOME}" in
    success)
      echo "✅ No secrets detected."
      ;;
    failure)
      echo "❌ Potential secrets detected. Rotate anything real before removing it from history — a redacted finding is still a live credential."
      ;;
    *)
      echo "Status: ${OUTCOME}"
      ;;
  esac
  echo ""
  # Exported by the scan step; unset means it died before scanning.
  if [[ -n "${SCAN_SCOPE:-}" ]]; then
    echo "| Property | Value |"
    echo "|---|---|"
    echo "| **Scope** | ${SCAN_SCOPE} |"
    if [[ -n "${SCAN_COMMITS:-}" ]]; then
      echo "| **Commits scanned** | ${SCAN_COMMITS} |"
    fi
    if [[ -n "${FOUND}" ]]; then
      echo "| **Findings** | ${FOUND} |"
    fi
    echo ""
  fi
  if [[ "${OUTCOME}" == "failure" && -s "${LOG}" ]]; then
    echo "<details><summary>Redacted findings</summary>"
    echo ""
    echo '```'
    tail -n 60 "${LOG}"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
  fi
} >> "${GITHUB_STEP_SUMMARY}"
