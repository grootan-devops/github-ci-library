#!/usr/bin/env bash
# Guard: the chart version being released must not already be published.
set -euo pipefail

: "${CHART_NAME:?CHART_NAME is required}"
PROJECT_PATH="${PROJECT_PATH:-.}"
CHART_DIR="${CHART_DIR:-./chart}"

if [[ -z "${CHART_VERSION:-}" ]]; then
  if [[ -f "${PROJECT_PATH}/${CHART_DIR}/Chart.yaml" ]]; then
    echo "Local chart present; nothing published to collide with."
    { echo "### ⎈ Chart version"; echo; echo "✅ Working-tree chart present, no published version to collide with."; echo; } >> "${GITHUB_STEP_SUMMARY}"
    exit 0
  fi
  echo "::error title=Chart::No chart-version supplied and no chart at ${PROJECT_PATH}/${CHART_DIR}/Chart.yaml."
  exit 1
fi

if [[ ! "${CHART_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::notice::Chart version '${CHART_VERSION}' is a candidate build. Skipping the collision check."
  { echo "### ⎈ Chart version"; echo; echo "✅ \`${CHART_VERSION}\` is a candidate build — collision check skipped."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 0
fi

printf '%s' "${REGISTRY_PASSWORD}" | helm registry login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password-stdin

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
  { echo "### ⎈ Chart version"; echo; echo "❌ \`${TARGET}:${CHART_VERSION}\` is already published. Bump the chart version."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "Chart version '${CHART_VERSION}' is available at ${TARGET}."
{ echo "### ⎈ Chart version"; echo; echo "✅ \`${TARGET}:${CHART_VERSION}\` is available."; echo; } >> "${GITHUB_STEP_SUMMARY}"
