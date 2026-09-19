#!/usr/bin/env bash
# Guard: no chart dependency may resolve to the development chart repository.
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-.}"
CHART_DIR="${CHART_DIR:-./chart}"
CHART_DEV_REPOSITORY_SUFFIX="${CHART_DEV_REPOSITORY_SUFFIX:-/dev}"
CHART_FILE="${PROJECT_PATH}/${CHART_DIR}/Chart.yaml"

if [[ ! -f "${CHART_FILE}" ]]; then
  echo "No chart at ${CHART_FILE}; nothing to check."
  exit 0
fi

DEV_PATH="${CHART_REPOSITORY:-}${CHART_DEV_REPOSITORY_SUFFIX}"
# shellcheck disable=SC2016 # $dev is a yq variable, not a shell one
OFFENDERS="$(yq -r --arg dev "${DEV_PATH}" \
  '.dependencies[]? | select((.repository // "") | test($dev)) | "\(.name) -> \(.repository)"' \
  "${CHART_FILE}" 2>/dev/null || true)"

if [[ -n "${OFFENDERS}" ]]; then
  echo "::error title=Chart dependency::A dependency resolves to the development repository '${DEV_PATH}'. Only stable releases may be depended on."
  echo "${OFFENDERS}"
  {
    echo "### ⎈ Chart dependencies"
    echo ""
    echo "❌ These dependencies point at the development repository \`${DEV_PATH}\`:"
    echo ""
    echo '```'
    echo "${OFFENDERS}"
    echo '```'
    echo ""
    echo "Depend on published stable versions instead."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

echo "All chart dependencies resolve to stable repositories."
{ echo "### ⎈ Chart dependencies"; echo; echo "✅ All dependencies resolve to stable repositories."; echo; } >> "${GITHUB_STEP_SUMMARY}"
