#!/usr/bin/env bash
# Write the deployment summary, including the per-application sync table.
#
# Runs with `if: always()`, so it has to render something useful when the sync
# step failed or never got that far. The per-application rows are read from
# the TSV the sync step appends to; when that file is missing or empty the
# table is skipped and the application names are listed in the property table
# instead, so the summary never implies a state nothing actually reported.
#
# Exit codes: 0 always, unless writing the summary itself fails.
#
# Env:
#   ENVIRONMENT        target environment
#   ARGOCD_APP_NAME    space-separated application names, listed only as a fallback
#   MODE               "helm" or "manifest"; decides which rows are relevant
#   VERSION            chart version (Helm mode)
#   CHART_REPO_URL     chart repoURL (Helm mode)
#   NEW_IMAGE          image reference (manifest mode, or with IMAGE_VALUES_FILE)
#   IMAGE_VALUES_FILE  separate image values.yaml, if one was written
#   BRANCH             GitOps branch that was committed to
#   COMMIT_SHA         GitOps commit SHA; empty means no change was needed
#   LIVE_URL           deployed application URL; row omitted when empty
#   RUNNER_TEMP        holds argocd-apps.tsv, written by the sync step
set -euo pipefail

: "${ENVIRONMENT:=}"
: "${ARGOCD_APP_NAME:=}"
: "${MODE:=}"
: "${VERSION:=}"
: "${CHART_REPO_URL:=}"
: "${NEW_IMAGE:=}"
: "${IMAGE_VALUES_FILE:=}"
: "${BRANCH:=}"
: "${COMMIT_SHA:=}"
: "${LIVE_URL:=}"

APP_ROWS="${RUNNER_TEMP}/argocd-apps.tsv"
# Manifest mode resolves no chart; helm mode writes an image only when image-values-file is set.
WANT_CHART=false
if [[ "${MODE}" == "helm" ]]; then
  WANT_CHART=true
fi
WANT_IMAGE=false
if [[ "${MODE}" == "manifest" || -n "${IMAGE_VALUES_FILE}" ]]; then
  WANT_IMAGE=true
fi

{
  echo "## 🚢 Deployment Summary"
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  echo "| **Environment** | \`${ENVIRONMENT}\` |"
  # The per-application table below carries the names; list them here only when it never rendered.
  if [[ ! -s "${APP_ROWS}" ]]; then
    echo "| **Applications** | \`${ARGOCD_APP_NAME}\` |"
  fi
  if [[ "${WANT_CHART}" == "true" && -n "${VERSION}" ]]; then
    echo "| **Chart Version** | \`${VERSION}\` |"
  fi
  if [[ "${WANT_CHART}" == "true" ]]; then
    echo "| **Chart repoURL** | \`${CHART_REPO_URL}\` |"
  fi
  if [[ "${WANT_IMAGE}" == "true" ]]; then
    echo "| **Image** | \`${NEW_IMAGE}\` |"
  fi
  echo "| **GitOps Branch** | \`${BRANCH}\` |"
  echo "| **GitOps Commit** | \`${COMMIT_SHA:-no change}\` |"
  if [[ -n "${LIVE_URL}" ]]; then
    echo "| **Live URL** | [${LIVE_URL}](${LIVE_URL}) |"
  fi

  if [[ -s "${APP_ROWS}" ]]; then
    echo ""
    echo "### 📦 Applications"
    echo ""
    echo "| Application | Sync | Health | Revision | Message |"
    echo "|---|:--:|:--:|---|---|"
    while IFS=$'\t' read -r APP APP_SYNC APP_HEALTH APP_REV APP_MSG; do
      if [[ -z "${APP}" ]]; then
        continue
      fi
      case "${APP_SYNC}" in
        Synced) SYNC_ICON="✅ Synced" ;;
        *) SYNC_ICON="❌ ${APP_SYNC}" ;;
      esac
      case "${APP_HEALTH}" in
        Healthy) HEALTH_ICON="✅ Healthy" ;;
        *) HEALTH_ICON="❌ ${APP_HEALTH}" ;;
      esac
      echo "| \`${APP}\` | ${SYNC_ICON} | ${HEALTH_ICON} | \`${APP_REV:-n/a}\` | ${APP_MSG:-—} |"
    done < "${APP_ROWS}"
  fi

} >> "${GITHUB_STEP_SUMMARY}"
