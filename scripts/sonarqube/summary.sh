#!/usr/bin/env bash
# Write the SonarQube step summary: outcome, project key, quality gate lines.
#
# This runs on every outcome, including the one where the scanner never started,
# so each read is defensive: the scanner log may not exist, and
# SONAR_PROJECT_KEY only reaches the environment once the analysis step has
# derived it. When the gate lines cannot be found but the job failed, the tail
# of the log is emitted instead, so the summary is never empty on a failure.
#
# Exit codes: 0.
#
# Env:
#   OUTCOME             job status so far ("success", "failure", ...)
#   DASHBOARD           public SonarQube URL used to link the key (default: empty)
#   SONAR_PROJECT_KEY   key exported by the analysis step (default: unset)
set -euo pipefail

# This script only reports, and its step runs under `if: always()`. The guards
# below use `${VAR?...}` (unset only), not the house `${VAR:?...}` (unset or
# empty): `steps.<id>.outcome` is an EMPTY string when the step never ran, and
# aborting there would turn an otherwise-green job red. The inline block this
# replaced ran under `set -u`, which also tolerated empty.
: "${OUTCOME?OUTCOME must be set}"
: "${DASHBOARD:=}"

LOG="${RUNNER_TEMP}/sonar-scanner.log"
GATE="$(grep -aE 'QUALITY GATE STATUS|^\s*-\s' "${LOG}" 2>/dev/null | tail -n 12 || true)"
{
  echo "### 🔍 SonarQube"
  echo ""
  case "${OUTCOME}" in
    success)
      echo "✅ Analysis complete and the quality gate passed."
      ;;
    failure)
      echo "❌ Analysis failed or the quality gate was not met."
      ;;
    *)
      echo "Status: ${OUTCOME}"
      ;;
  esac
  echo ""
  # Unset when the run never got past configuration validation.
  if [[ -n "${SONAR_PROJECT_KEY:-}" ]]; then
    KEY_CELL="\`${SONAR_PROJECT_KEY}\`"
    if [[ -n "${DASHBOARD}" ]]; then
      KEY_CELL="[${KEY_CELL}](${DASHBOARD}/dashboard?id=${SONAR_PROJECT_KEY})"
    fi
    echo "| Property | Value |"
    echo "|---|---|"
    echo "| **Project key** | ${KEY_CELL} |"
  fi
  if [[ -n "${GATE}" ]]; then
    echo ""
    echo '```'
    echo "${GATE}"
    echo '```'
  elif [[ "${OUTCOME}" != "success" && -s "${LOG}" ]]; then
    echo ""
    echo '```'
    tail -n 30 "${LOG}"
    echo '```'
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
