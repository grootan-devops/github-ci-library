#!/usr/bin/env bash
# Guard: the chart version being released must not already be published.
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

# Capture helm's words: a bad credential and an unreachable registry both exit 1.
if ! LOGIN_OUTPUT="$(printf '%s' "${REGISTRY_PASSWORD}" | helm registry login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password-stdin 2>&1)"; then
  echo "::error title=Chart::Could not authenticate to ${REGISTRY_HOST}."
  echo "${LOGIN_OUTPUT}" >&2
  {
    echo "### ⎈ Chart version"
    echo ""
    echo "❌ Could not log in to \`${REGISTRY_HOST}\` as \`${REGISTRY_USERNAME:-<unset>}\`, so \`${CHART_VERSION}\` cannot be confirmed available. Helm reported:"
    echo ""
    echo '```'
    tail -n 20 <<< "${LOGIN_OUTPUT}"
    echo '```'
    echo ""
    echo "Check \`secrets.IMAGE_REGISTRY_USERNAME\` / \`secrets.IMAGE_REGISTRY_PASSWORD\` and that the caller passes \`secrets: inherit\`."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

TARGET="oci://${REGISTRY_HOST}/${CHART_REPOSITORY}/${CHART_NAME}"
if helm show chart "${TARGET}" --version "${CHART_VERSION}" >/dev/null 2>&1; then
  EXISTS="true"
elif helm show chart "oci://${REGISTRY_HOST}/${CHART_REPOSITORY}" --version "${CHART_VERSION}" >/dev/null 2>&1; then
  EXISTS="true"
  TARGET="oci://${REGISTRY_HOST}/${CHART_REPOSITORY}"
else
  EXISTS="false"
fi

if [[ "${EXISTS}" == "true" ]]; then
  echo "::error title=Chart::Version '${CHART_VERSION}' already exists at ${TARGET}. Bump the chart version."
  { echo "### ⎈ Chart version"; echo; echo "❌ \`${TARGET}:${CHART_VERSION}\` is already taken by a published chart. Bump the chart version."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "Chart version '${CHART_VERSION}' is unpublished at ${TARGET}; the release may push it."
{ echo "### ⎈ Chart version"; echo; echo "✅ \`${TARGET}:${CHART_VERSION}\` is unpublished — free to push."; echo; } >> "${GITHUB_STEP_SUMMARY}"
