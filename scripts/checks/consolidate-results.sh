#!/usr/bin/env bash
# Turn the guard matrix's aggregate result into the release verdict.
#
# The guard job runs `fail-fast: false`, and discovery can legitimately emit a
# matrix that leaves it skipped. Neither outcome fails the calling workflow by
# itself, so this is the single place that decides whether the release may go
# ahead: a failed or cancelled guard job, or a discovery that did not succeed,
# stops it here. Discovery is checked separately because a broken discover step
# produces no guards at all, which otherwise looks the same as "nothing to do".
#
# The step summary is written before the exit so the reason is visible on the
# run even though the job ends red.
#
# Exit codes: 0 every applicable guard passed; 1 discovery did not succeed, or
# at least one guard failed or was cancelled.
#
# Env:
#   RESULT               needs.guard.result -- success, failure, cancelled or skipped
#   DISCOVER_RESULT      needs.discover.result
#   GITHUB_STEP_SUMMARY  runner-provided; the verdict section is appended to it
#
# The `?` guards below deliberately fire on an UNSET variable only. An empty
# value is passed through to the reporting below exactly as the inline block
# rendered it, rather than turned into a new failure mode.
set -euo pipefail

: "${RESULT?RESULT must be set}"
: "${DISCOVER_RESULT?DISCOVER_RESULT must be set}"

if [[ "${RESULT}" != "success" ]]; then
  {
    echo "## 🚦 Release Prerequisites"
    echo ""
    case "${RESULT}" in
      failure)
        echo "❌ At least one guard failed. Open the failed **Check:** job for the exact remedy."
        ;;
      cancelled)
        echo "🚫 The guards were cancelled."
        ;;
      skipped)
        echo "⏭️ No guards ran."
        ;;
      *)
        echo "Status: ${RESULT}"
        ;;
    esac
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ "${DISCOVER_RESULT}" != "success" ]]; then
  echo "::error title=Release prerequisites::Guard discovery did not succeed (${DISCOVER_RESULT})."
  exit 1
fi

if [[ "${RESULT}" == "failure" || "${RESULT}" == "cancelled" ]]; then
  echo "::error title=Release prerequisites::Not met. Open each failed guard job for the exact remedy."
  exit 1
fi

echo "All applicable guards passed."
