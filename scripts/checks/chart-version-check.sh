#!/usr/bin/env bash
# Guard: the chart version being released must not already be published.
#
# Env:
#   CHART_REGISTRY             OCI registry host
#   CHART_REGISTRY_USERNAME    registry username
#   CHART_REGISTRY_PASSWORD    registry password or token
#   CHART_NAME                 Helm chart name
#   CHART_REPOSITORY           production chart repository
#   CHART_VERSION              chart version being guarded
set -euo pipefail

: "${CHART_NAME:?CHART_NAME is required}"
PROJECT_PATH="${PROJECT_PATH:-.}"
CHART_DIR="${CHART_DIR:-./chart}"

if [[ -z "${CHART_VERSION:-}" ]]; then
  if [[ -f "${PROJECT_PATH}/${CHART_DIR}/Chart.yaml" ]]; then
    echo "Local chart present; nothing published to collide with."
    exit 0
  fi
  echo "::error title=Chart::No chart-version supplied and no chart at ${PROJECT_PATH}/${CHART_DIR}/Chart.yaml."
  { echo "### ⎈ Chart version"; echo; echo "❌ No \`chart-version\` was passed and there is no \`${PROJECT_PATH}/${CHART_DIR}/Chart.yaml\` to read one from. Pass \`chart-version\` from \`init.yml\`, or pass the chart directory through the reusable workflow input."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

if [[ ! "${CHART_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::notice::Chart version '${CHART_VERSION}' is a candidate build. Skipping the collision check."
  exit 0
fi

# shellcheck source=scripts/chart/registry.sh
source "$(dirname "${BASH_SOURCE[0]}")/../chart/registry.sh"
chart_registry_login
: "${CHART_REPOSITORY:?Set CHART_REPOSITORY to the OCI namespace/path}"
TARGET="oci://${CHART_REGISTRY}/${CHART_REPOSITORY}/${CHART_NAME}"
if chart_oci_lookup "${TARGET}" "${CHART_VERSION}" >/dev/null; then
  EXISTS=true
else
  RESULT=$?
  [[ "${RESULT}" -eq 1 ]] || exit "${RESULT}"
  EXISTS=false
fi

if [[ "${EXISTS}" == "true" ]]; then
  echo "::error title=Chart::Version '${CHART_VERSION}' already exists at ${TARGET}. Bump the chart version."
  { echo "### ⎈ Chart version"; echo; echo "❌ \`${TARGET}:${CHART_VERSION}\` is already taken by a published chart. Bump the chart version."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "Chart version '${CHART_VERSION}' is unpublished at ${TARGET}; the release may push it."
{ echo "### ⎈ Chart version"; echo; echo "✅ \`${TARGET}:${CHART_VERSION}\` is unpublished — free to push."; echo; } >> "${GITHUB_STEP_SUMMARY}"
