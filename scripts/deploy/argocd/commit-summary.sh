#!/usr/bin/env bash
# Reports what the GitOps commit step did to the deployment summary.
#
# Runs under `if: always()`, so it must render on the failure paths too --
# and stay silent when the update step already wrote its own refusal
# section, or the summary would carry the same heading twice.
#
# Guards use `${VAR?...}` (unset only) rather than `${VAR:?...}`: every
# value below is a step output or outcome that is legitimately EMPTY when
# the step it came from never ran, which is exactly when `always()` fires.
#
# Env:
#   OUTCOME         job status
#   UPDATE_OUTCOME  the update step's outcome
#   GITOPS_REPO     the repository that was (or was not) updated
#   BRANCH          branch committed to
#   SHA             commit SHA; empty when no change was required
#   VERSION         version the manifests were pointed at
#   PREVIOUS        version before the change (may be empty)
#   CURRENT         version after the change
#   ENVIRONMENT     inherited from the workflow-level env:, as the inline
#                   block it replaced also did
set -euo pipefail

: "${OUTCOME?OUTCOME must be set}"
: "${UPDATE_OUTCOME?UPDATE_OUTCOME must be set}"
: "${GITOPS_REPO?GITOPS_REPO must be set}"
: "${ENVIRONMENT:=}"
: "${BRANCH:=}"
: "${SHA:=}"
: "${VERSION:=}"
: "${PREVIOUS:=}"
: "${CURRENT:=}"

set -euo pipefail
# The update step already wrote its own section on a refusal.
{
  echo "### 🚢 GitOps commit"
  echo ""
  if [[ "${OUTCOME}" != "success" && "${UPDATE_OUTCOME}" == "failure" ]]; then
    exit 0
  elif [[ "${OUTCOME}" != "success" ]]; then
    echo "❌ \`${GITOPS_REPO}\` was not updated — the checkout or the push failed, so **${ENVIRONMENT} is still on \`${PREVIOUS:-its previous version}\`**. The failing step in the log says which."
  elif [[ -z "${SHA}" ]]; then
    echo "ℹ️ No change required — \`${GITOPS_REPO}\` already targets \`${VERSION}\`."
  else
    echo "| Property | Value |"
    echo "|---|---|"
    echo "| **Repository** | \`${GITOPS_REPO}\` |"
    echo "| **Branch** | \`${BRANCH}\` |"
    echo "| **Commit** | \`${SHA}\` |"
    if [[ -n "${PREVIOUS}" ]]; then
      echo "| **Previous** | \`${PREVIOUS}\` |"
    fi
    echo "| **Now** | \`${CURRENT}\` |"
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
