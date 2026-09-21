#!/usr/bin/env bash
# Sync every ArgoCD application and wait for it to report Synced and Healthy.
#
# A sync request that returns 200 says only that ArgoCD accepted the work, so
# the wait is what makes this step mean anything. The revision check matters
# just as much: ArgoCD can report Healthy against the commit it already had,
# which looks like a successful deploy of a change that never shipped. Each
# application is therefore checked against the SHA this run pushed, and every
# application is attempted before the step fails so one broken app does not
# hide the state of the others.
#
# Note on errexit: the workflow step this replaces was run by GitHub's default
# `bash --noprofile --norc -e -o pipefail`, so errexit was active even though
# the block itself wrote `set -uo pipefail`. `-e` is kept here to preserve
# that behaviour exactly.
#
# Exit codes: 0 all applications Synced and Healthy, 1 no auth token or at
# least one application failed to sync, went unhealthy, or landed on the
# wrong revision.
#
# Env:
#   ARGOCD_APP_NAME    space-separated ArgoCD application names
#   ARGOCD_AUTH_TOKEN  ArgoCD API token; empty refuses the sync
#   ARGOCD_SERVER      ArgoCD API server, read by the argocd CLI itself
#   ARGOCD_OPTS        extra argocd CLI options, read by the CLI itself
#   SYNC_TIMEOUT       seconds to wait per application
#   ENVIRONMENT        target environment, named in the refusal summary
#   EXPECTED_REVISION  GitOps SHA this run pushed; skipped when empty
set -euo pipefail

: "${ARGOCD_APP_NAME:=}"
: "${ARGOCD_AUTH_TOKEN:=}"
: "${SYNC_TIMEOUT:=600}"
: "${ENVIRONMENT:=}"
: "${EXPECTED_REVISION:=}"

if [[ -z "${ARGOCD_AUTH_TOKEN}" ]]; then
  echo "::error::ARGOCD_AUTH_TOKEN is not configured. Refusing to report a successful deployment without performing one."
  {
    echo "## 🚢 Deployment Summary"
    echo ""
    echo "❌ **${ENVIRONMENT} was not synced.** \`ARGOCD_AUTH_TOKEN\` is not configured, so no sync was attempted — but the GitOps commit has already been pushed, so ArgoCD will pick the change up on its own refresh interval rather than now."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

OVERALL_HEALTH="Healthy"
OVERALL_SYNC="Synced"
FAILED_APPS=()

APP_ROWS="${RUNNER_TEMP}/argocd-apps.tsv"
: > "${APP_ROWS}"

# shellcheck disable=SC2086 # ARGOCD_APP_NAME is space-separated; the split is the point
for APP in ${ARGOCD_APP_NAME}; do
  echo "=== ${APP} ==="

  argocd app get "${APP}" --hard-refresh || true

  SYNC_OK=true
  if ! argocd app sync "${APP}" --async; then
    echo "::error::Sync request failed for ${APP}."
    SYNC_OK=false
  fi

  if [[ "${SYNC_OK}" == "true" ]]; then
    if ! argocd app wait "${APP}" --health --sync --operation \
         --timeout "${SYNC_TIMEOUT}"; then
      SYNC_OK=false
    fi
  fi

  if [[ "${SYNC_OK}" != "true" ]]; then
    FAILED_APPS+=("${APP}")
    OVERALL_HEALTH="Unhealthy"
    OVERALL_SYNC="OutOfSync"
  fi

  APP_JSON="$(argocd app get "${APP}" -o json 2>/dev/null || true)"
  if [[ -n "${APP_JSON}" ]]; then
    APP_SYNC="$(jq -r '.status.sync.status // "Unknown"' <<<"${APP_JSON}")"
    APP_HEALTH="$(jq -r '.status.health.status // "Unknown"' <<<"${APP_JSON}")"
    APP_REV="$(jq -r '.status.sync.revision // "" | .[0:7]' <<<"${APP_JSON}")"
    APP_MSG="$(jq -r '.status.operationState.message // "" | gsub("\n"; " ") | .[0:120]' <<<"${APP_JSON}")"

    FULL_REV="$(jq -r '.status.sync.revision // ""' <<<"${APP_JSON}")"
    if [[ "${SYNC_OK}" == "true" && -n "${EXPECTED_REVISION}" && -n "${FULL_REV}" && "${FULL_REV}" != "${EXPECTED_REVISION}" ]]; then
      echo "::error::${APP} is synced to ${FULL_REV:0:7}, not the revision this run pushed (${EXPECTED_REVISION:0:7})."
      FAILED_APPS+=("${APP}")
      OVERALL_SYNC="OutOfSync"
      APP_MSG="synced to ${FULL_REV:0:7}, expected ${EXPECTED_REVISION:0:7}"
    fi
  else
    APP_SYNC="Unknown"
    APP_HEALTH="Unknown"
    APP_REV=""
    APP_MSG="could not read application state"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${APP}" "${APP_SYNC}" "${APP_HEALTH}" "${APP_REV}" "${APP_MSG}" >> "${APP_ROWS}"
done

{
  echo "health=${OVERALL_HEALTH}"
  echo "sync=${OVERALL_SYNC}"
} >> "${GITHUB_OUTPUT}"

if [[ ${#FAILED_APPS[@]} -gt 0 ]]; then
  echo "::error::ArgoCD sync or health check failed for: ${FAILED_APPS[*]}"
  exit 1
fi
echo "All applications are Synced and Healthy."
