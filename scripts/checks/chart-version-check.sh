#!/usr/bin/env bash
# Guard: the chart version being released must not already be published.
#
# With vars.PROJECT_REGISTRY_NAME the release is published to every repository
# CHART_REPOSITORY lists, so every one is checked, and each must log in.
#
# Env:
#   CHART_REGISTRY, CHART_REGISTRY_USERNAME, CHART_REGISTRY_PASSWORD, or
#   PROJECT_REGISTRY_NAME and REGISTRY_CONFIG
#                              the registries and their credentials -- see
#                              scripts/registry/lib.sh
#   CHART_NAME                 Helm chart name
#   CHART_REPOSITORY           production chart repository: the path in
#                              CHART_REGISTRY, or with a group the full
#                              <registry>/<path> repositories
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
: "${CHART_REPOSITORY:?Set CHART_REPOSITORY to the OCI namespace/path}"
chart_registry_targets "${CHART_REPOSITORY}" "" || exit 1

TAKEN=()
FREE=()
UNCHECKED=()
for I in "${!REGISTRY_HOSTS[@]}"; do
  LABEL="${REGISTRY_HOSTS[${I}]}/${REGISTRY_REPOS[${I}]}"
  if ! chart_registry_login "${I}"; then
    UNCHECKED+=("${LABEL}")
    continue
  fi
  TARGET="oci://${REGISTRY_HOSTS[${I}]}/${REGISTRY_REPOS[${I}]}/${CHART_NAME}"
  RESULT=0
  chart_oci_lookup "${TARGET}" "${CHART_VERSION}" >/dev/null || RESULT=$?
  if [[ "${RESULT}" -eq 0 ]]; then
    echo "::error title=Chart::Version '${CHART_VERSION}' already exists at ${TARGET}. Bump the chart version."
    TAKEN+=("${TARGET}")
  elif [[ "${RESULT}" -eq 1 ]]; then
    echo "Chart version '${CHART_VERSION}' is unpublished at ${TARGET}; the release may push it."
    FREE+=("${TARGET}")
  else
    UNCHECKED+=("${LABEL}")
  fi
done

{
  echo "### ⎈ Chart version"
  echo ""
  for TARGET in "${TAKEN[@]}"; do
    echo "❌ \`${TARGET}:${CHART_VERSION}\` is already taken by a published chart. Bump the chart version."
    echo ""
  done
  for LABEL in "${UNCHECKED[@]}"; do
    echo "❌ \`${CHART_VERSION}\` could not be checked in \`${LABEL}\`: the log names the reason."
    echo ""
  done
  for TARGET in "${FREE[@]}"; do
    echo "✅ \`${TARGET}:${CHART_VERSION}\` is unpublished — free to push."
    echo ""
  done
} >> "${GITHUB_STEP_SUMMARY}"

if [[ ${#TAKEN[@]} -gt 0 ]]; then
  exit 1
fi
if [[ ${#UNCHECKED[@]} -gt 0 ]]; then
  exit 2
fi
