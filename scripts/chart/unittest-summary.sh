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
#   MOCK_CHARTS          space-separated mock chart directories, relative to CHART_DIR
#   MOCK_CHART           legacy alias accepted for direct script callers
#   CHART_DIR            chart directory (default: ./chart)
#   RUNNER_TEMP          GitHub-provided; holds helm-unittest.log
#   GITHUB_STEP_SUMMARY  GitHub-provided; appended to
#
# Exit codes: 0 — reporting only, it never fails the job. No `:?` guard here
# for that reason: a summary that aborts is worse than a thin summary.
set -euo pipefail

: "${OUTCOME:=}"
: "${MOCK_CHARTS:=${MOCK_CHART:-}}"
: "${CHART_DIR:=./chart}"
read -r -a MOCK_CHART_LIST <<< "${MOCK_CHARTS}"

TALLY="$(grep -E '^(Charts|Test Suites|Tests|Snapshot):' "${RUNNER_TEMP}/helm-unittest.log" 2>/dev/null || true)"
{
  echo "### 📘 Chart unit tests"
  echo ""
  if [[ "${OUTCOME}" == "success" ]]; then
    echo "✅ \`helm unittest --strict\` passed against:"
  else
    echo "❌ \`helm unittest --strict\` failed against:"
  fi
  for mock_chart in "${MOCK_CHART_LIST[@]}"; do
    echo "- \`${CHART_DIR}/${mock_chart}\`"
  done
  if [[ ${#MOCK_CHART_LIST[@]} -eq 0 ]]; then
    echo "- (no mock chart was resolved)"
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
