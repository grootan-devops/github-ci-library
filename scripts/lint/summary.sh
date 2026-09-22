#!/usr/bin/env bash
# Runs a linter, and on failure puts the linter's own output in the job summary.
#
# Usage: run_linted "<summary heading>" <command> [args...]
run_linted() {
  local TITLE="${1}"; shift
  local OUTPUT RESULT

  set +e
  OUTPUT="$("$@" 2>&1)"
  RESULT=$?
  set -e

  if [[ -n "${OUTPUT}" ]]; then
    echo "${OUTPUT}"
  fi

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### ${TITLE}"
      echo ""
      if [[ "${RESULT}" -eq 0 ]]; then
        echo "✅ No findings."
      elif [[ -z "${OUTPUT}" ]]; then
        echo "❌ Failed (exit ${RESULT}) without printing anything. Check that \`${1}\` is installed in the job image and that its configuration is readable."
      else
        echo "❌ Failed (exit ${RESULT}). The linter reported:"
        echo ""
        echo '```'
        # GITHUB_STEP_SUMMARY has a 1MB budget.
        echo "${OUTPUT}" | tail -n 50
        echo '```'
      fi
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi

  return "${RESULT}"
}
