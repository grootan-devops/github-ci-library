#!/usr/bin/env bash
# Runs a linter, and on failure puts the linter's own output in the job summary.
#
# "Process completed with exit code 1" tells the reader nothing — the sentence
# that explains the failure is the linter's, and it belongs where the failure is
# shown rather than buried in the raw log.
#
# Usage: run_linted "<summary heading>" <command> [args...]
run_linted() {
  local TITLE="${1}"; shift
  local OUTPUT RESULT

  set +e
  OUTPUT="$("$@" 2>&1)"
  RESULT=$?
  set -e

  [[ -n "${OUTPUT}" ]] && echo "${OUTPUT}"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### ${TITLE}"
      echo ""
      if [[ "${RESULT}" -eq 0 ]]; then
        echo "✅ No findings."
      else
        echo "❌ Failed (exit ${RESULT}). The linter reported:"
        echo ""
        echo '```'
        # Cap it: a summary has a 1MB budget and a wall of findings helps nobody.
        echo "${OUTPUT}" | tail -n 50
        echo '```'
      fi
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi

  return "${RESULT}"
}
