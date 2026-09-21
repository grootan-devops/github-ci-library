#!/usr/bin/env bash
# Render the helm-unittest result into the run's step summary.
#
# The JUnit artifact names the failing assertion, but nobody downloads an
# artifact to find out whether a chart's tests passed. The tally line that
# helm-unittest prints, plus the tail of its log on a failure, is enough to
# tell from the run page alone which suite broke and why.
#
# Env:
#   OUTCOME              outcome of the helm-unittest step ("success" or not).
#                        Empty when that step never ran -- the calling step is
#                        `if: always()`, so anything other than "success" is
#                        reported as a failure, exactly as an empty value was
#                        when this block was inline.
#   MOCK_CHART           mock consumer chart directory, relative to CHART_DIR
#   CHART_DIR            chart directory (default: ./chart)
#   RUNNER_TEMP          GitHub-provided; holds helm-unittest.log
#   GITHUB_STEP_SUMMARY  GitHub-provided; appended to
#
# Exit codes: 0 — reporting only, it never fails the job. No `:?` guard here
# for that reason: a summary that aborts is worse than a thin summary.
set -euo pipefail

: "${OUTCOME:=}"
: "${MOCK_CHART:=}"
: "${CHART_DIR:=./chart}"

TALLY="$(grep -E '^(Charts|Test Suites|Tests|Snapshot):' "${RUNNER_TEMP}/helm-unittest.log" 2>/dev/null || true)"
{
  echo "### 📘 Chart unit tests"
  echo ""
  if [[ "${OUTCOME}" == "success" ]]; then
    echo "✅ \`helm unittest --strict\` passed against \`${CHART_DIR}/${MOCK_CHART}\`."
  else
    echo "❌ \`helm unittest --strict\` failed against \`${CHART_DIR}/${MOCK_CHART}\`."
  fi
  if [[ -n "${TALLY}" ]]; then
    echo ""
    echo '```'
    echo "${TALLY}"
    echo '```'
  fi
  if [[ "${OUTCOME}" != "success" ]]; then
    echo ""
    echo "<details><summary>helm-unittest output</summary>"
    echo ""
    echo '```'
    tail -n 50 "${RUNNER_TEMP}/helm-unittest.log" 2>/dev/null || echo "(no output was captured)"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
    echo "Every assertion is in the \`chart-unittest-report\` artifact."
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
