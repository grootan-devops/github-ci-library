#!/usr/bin/env bash
# Guard: the chart version being released must not already be published.
#
# Every chart destination is checked. Needs a job prepared by scripts/registry/auth.sh:
# the destinations and credentials come from the registry settings it exported.
#
# Env:
#   CHART_NAME                 Helm chart name
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
# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"
TARGETS=$(registry_targets chart) || exit 1

TAKEN=()
FREE=()
while IFS=$'\t' read -r HOST STABLE _; do
  TARGET="oci://${HOST}/${STABLE}/${CHART_NAME}"
  if chart_oci_lookup "${TARGET}" "${CHART_VERSION}" >/dev/null; then
    TAKEN+=("${TARGET}:${CHART_VERSION}")
  else
    RESULT=$?
    [[ "${RESULT}" -eq 1 ]] || exit "${RESULT}"
    FREE+=("${TARGET}:${CHART_VERSION}")
  fi
done <<<"${TARGETS}"

if [[ "${#TAKEN[@]}" -gt 0 ]]; then
  echo "::error title=Chart::Version '${CHART_VERSION}' already exists at ${TAKEN[*]}. Bump the chart version."
  {
    echo "### ⎈ Chart version"
    echo ""
    for TARGET in "${TAKEN[@]}"; do
      echo "- ❌ \`${TARGET}\` is already taken by a published chart."
    done
    echo ""
    echo "Bump the chart version."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "Chart version '${CHART_VERSION}' is unpublished at ${FREE[*]}; the release may push it."
{
  echo "### ⎈ Chart version"
  echo ""
  for TARGET in "${FREE[@]}"; do
    echo "- ✅ \`${TARGET}\` is unpublished — free to push."
  done
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
