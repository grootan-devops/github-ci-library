#!/usr/bin/env bash
# Report what the validate job verified, once every check has passed.
#
# Only the success path is written here. Each refusal -- a missing input, a
# chart or image that does not resolve -- already appends its own section
# naming what stopped the run, so this step stays silent on failure rather
# than overwriting that with a generic line. The rows are filtered by mode:
# manifest mode resolves no chart, and helm mode writes an image only when
# `image-values-file` is set, so a row that was never written is not shown.
#
# Exit codes: 0 always, unless writing the summary itself fails.
#
# Env:
#   ENVIRONMENT        target environment
#   MODE               "helm" or "manifest"; decides which rows are relevant
#   VERSION            chart version (Helm mode)
#   CHART_REPO_URL     chart repository (Helm mode)
#   NEW_IMAGE          image reference (manifest mode, or with IMAGE_VALUES_FILE)
#   IMAGE_VALUES_FILE  separate image values.yaml, if one will be written
set -euo pipefail

: "${ENVIRONMENT:=}"
: "${MODE:=}"
: "${VERSION:=}"
: "${CHART_REPO_URL:=}"
: "${NEW_IMAGE:=}"
: "${IMAGE_VALUES_FILE:=}"

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
  echo "### 🔎 Deployment prerequisites"
  echo ""
  echo "✅ Verified in the registry — ready to deploy to **${ENVIRONMENT}** (${MODE} mode)."
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  if [[ "${WANT_CHART}" == "true" && -n "${VERSION}" ]]; then
    echo "| **Chart version** | \`${VERSION}\` |"
  fi
  if [[ "${WANT_CHART}" == "true" ]]; then
    echo "| **Chart repository** | \`${CHART_REPO_URL}\` |"
  fi
  if [[ "${WANT_IMAGE}" == "true" ]]; then
    echo "| **Image** | \`${NEW_IMAGE}\` |"
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
