#!/usr/bin/env bash
# Write the Biome step summary: outcome, tally line, and diagnostics on a failure.
#
# The step runs with `if: always()`, so it is also reached when an earlier step
# blew up and Biome never started. In that case there is nothing to report and
# a "lint failed" heading would be a lie, so anything other than a real Biome
# success or failure exits without writing. When Biome did run, the tally line
# it prints plus the tail of the report is enough to see from the run page what
# broke, without downloading the artifact.
#
# Exit codes: 0 — reporting only, it never fails the job.
#
# Env:
#   OUTCOME              outcome of the Biome step ("success", "failure", ...)
#   BIOME_REPORT         Biome report path, relative to the project root
#   GITHUB_STEP_SUMMARY  GitHub-provided; appended to
set -euo pipefail

# This script only reports, and its step runs under `if: always()`. The guards
# below use `${VAR?...}` (unset only), not the house `${VAR:?...}` (unset or
# empty): `steps.<id>.outcome` is an EMPTY string when the step never ran, and
# aborting there would turn an otherwise-green job red. The inline block this
# replaced ran under `set -u`, which also tolerated empty.
: "${OUTCOME?OUTCOME must be set}"
: "${BIOME_REPORT?BIOME_REPORT must be set}"

# Anything else means an earlier step failed and Biome never ran.
if [[ ! "${OUTCOME}" =~ ^(success|failure)$ ]]; then
  exit 0
fi
TALLY="$(grep -E '^(Checked|Found|Fixed|Skipped) ' "${BIOME_REPORT}" 2>/dev/null | tail -n 5 || true)"
{
  echo "### 📗 Node lint: biome"
  echo ""
  if [[ "${OUTCOME}" == "success" ]]; then
    echo "✅ No diagnostics."
  elif [[ -s "${BIOME_REPORT}" ]]; then
    echo "❌ Biome reported diagnostics."
  else
    echo "❌ Biome exited \`${OUTCOME}\` without writing a report — it did not get as far as checking anything."
  fi
  if [[ -n "${TALLY}" ]]; then
    echo ""
    echo '```'
    echo "${TALLY}"
    echo '```'
  fi
  if [[ "${OUTCOME}" != "success" && -s "${BIOME_REPORT}" ]]; then
    echo ""
    echo "<details><summary>Biome diagnostics</summary>"
    echo ""
    echo '```'
    tail -c 60000 "${BIOME_REPORT}"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
    echo "Every diagnostic is in the \`node-biome-report\` artifact."
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
