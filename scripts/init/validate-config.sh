#!/usr/bin/env bash
# Guard: the organisation registry variables are set before anything resolves a target.
#
# Images and charts may use different registries and credentials. Validate only
# the artifact types enabled by this caller: a chart-only repository must not be
# forced to configure images. Every destination must resolve (either registry style,
# see scripts/registry/lib.sh) and have credentials: ghcr.io uses the workflow token,
# any other host needs a REGISTRY_CONFIG entry or the IMAGE_ / CHART_ pair.
#
# Exit codes: 0 configured, or nothing to publish. 1 variables missing.
#
# Env:
#   IGNORE_DOCKER_INPUT      inputs.ignore-docker, "true" when no image is published
#   IGNORE_CHART_INPUT       inputs.ignore-chart, "true" when no chart is published
#   PROJECT_PATH             project root (default: .)
#   CHART_DIR                directory containing the chart (default: ./chart)
#   CHART_FILE               chart manifest filename (default: Chart.yaml)
#   DOCKERFILE               Dockerfile filename (default: Dockerfile)
#   IMAGE_REGISTRY_INPUT     vars.IMAGE_REGISTRY (default: empty)
#   IMAGE_REPOSITORY_INPUT   vars.IMAGE_REPOSITORY (default: empty: ghcr.io/<owner>/<repo>)
#   IMAGE_REGISTRY_USERNAME  secrets.IMAGE_REGISTRY_USERNAME (default: empty)
#   IMAGE_REGISTRY_PASSWORD  secrets.IMAGE_REGISTRY_PASSWORD (default: empty)
#   CHART_REGISTRY_INPUT     vars.CHART_REGISTRY (default: empty)
#   CHART_REPOSITORY_INPUT   vars.CHART_REPOSITORY (default: empty: ghcr.io/<owner>/<repo>/helm)
#   CHART_REGISTRY_USERNAME  secrets.CHART_REGISTRY_USERNAME (default: empty)
#   CHART_REGISTRY_PASSWORD  secrets.CHART_REGISTRY_PASSWORD (default: empty)
#   REGISTRY_CONFIG          secrets.REGISTRY_CONFIG (default: empty)
#   REGISTRY_TOKEN           github.token, the ghcr.io credential
set -euo pipefail

: "${IGNORE_DOCKER_INPUT:=}"
: "${IGNORE_CHART_INPUT:=}"
: "${PROJECT_PATH:=.}"
: "${CHART_DIR:=./chart}"
: "${CHART_FILE:=Chart.yaml}"
: "${DOCKERFILE:=Dockerfile}"
: "${IMAGE_REGISTRY_INPUT:=}"
: "${IMAGE_REPOSITORY_INPUT:=}"
: "${IMAGE_REGISTRY_USERNAME:=}"
: "${IMAGE_REGISTRY_PASSWORD:=}"
: "${CHART_REGISTRY_INPUT:=}"
: "${CHART_REPOSITORY_INPUT:=}"
: "${CHART_REGISTRY_USERNAME:=}"
: "${CHART_REGISTRY_PASSWORD:=}"

CHART_FILE_PATH="${PROJECT_PATH}/${CHART_DIR}/${CHART_FILE}"
if [[ ! -f "${CHART_FILE_PATH}" && -f "${CHART_DIR}/${CHART_FILE}" ]]; then
  CHART_FILE_PATH="${CHART_DIR}/${CHART_FILE}"
fi
DOCKERFILE_PATH="${PROJECT_PATH}/${DOCKERFILE}"
if [[ ! -f "${DOCKERFILE_PATH}" && -f "${DOCKERFILE}" ]]; then
  DOCKERFILE_PATH="${DOCKERFILE}"
fi

publishes_artifact() {
  local IGNORE_VALUE="${1,,}" ARTIFACT_PRESENT="${2}"
  case "${IGNORE_VALUE}" in
    true)  return 1 ;;
    false) return 0 ;;
    auto|"") [[ "${ARTIFACT_PRESENT}" == "true" ]] ;;
    *)
      echo "::error::Invalid ignore input '${1}'. Expected one of: auto, true, false." >&2
      return 2
      ;;
  esac
}

CHART_PRESENT=false
[[ -f "${CHART_FILE_PATH}" ]] && CHART_PRESENT=true
DOCKER_PRESENT=false
[[ -f "${DOCKERFILE_PATH}" ]] && DOCKER_PRESENT=true

if publishes_artifact "${IGNORE_DOCKER_INPUT}" "${DOCKER_PRESENT}"; then
  PUBLISH_DOCKER=true
else
  STATUS=$?
  [[ ${STATUS} -eq 1 ]] || exit "${STATUS}"
  PUBLISH_DOCKER=false
fi
if publishes_artifact "${IGNORE_CHART_INPUT}" "${CHART_PRESENT}"; then
  PUBLISH_CHART=true
else
  STATUS=$?
  [[ ${STATUS} -eq 1 ]] || exit "${STATUS}"
  PUBLISH_CHART=false
fi

if [[ "${PUBLISH_DOCKER}" == "false" && "${PUBLISH_CHART}" == "false" ]]; then
  echo "No image or chart target is enabled; registry configuration is not required."
  exit 0
fi

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"
export IMAGE_REGISTRY="${IMAGE_REGISTRY_INPUT}" IMAGE_REPOSITORY="${IMAGE_REPOSITORY_INPUT}"
export CHART_REGISTRY="${CHART_REGISTRY_INPUT}" CHART_REPOSITORY="${CHART_REPOSITORY_INPUT}"
AUTH_DIR=$(mktemp -d)
trap 'rm -rf "${AUTH_DIR}"' EXIT
registry_auth "${AUTH_DIR}" || exit 1

MISSING=()
for KIND in image chart; do
  if [[ "${KIND}" == "image" && "${PUBLISH_DOCKER}" != "true" ]] \
      || [[ "${KIND}" == "chart" && "${PUBLISH_CHART}" != "true" ]]; then
    continue
  fi
  if ! TARGETS=$(registry_targets "${KIND}" 2>&1); then
    MISSING+=("vars.${KIND^^}_REPOSITORY (${TARGETS##*::})")
    continue
  fi
  while IFS=$'\t' read -r HOST _ _; do
    if ! jq -e --arg KEY "$(registry_auth_keys "${HOST}" | awk '{print $NF}')" \
        '.auths[$KEY]' "${AUTH_DIR}/config.json" >/dev/null; then
      MISSING+=("credentials for ${HOST}: secrets.REGISTRY_CONFIG or secrets.${KIND^^}_REGISTRY_USERNAME / _PASSWORD")
    fi
  done <<<"${TARGETS}"
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "::error title=Configuration::Set these organisation or repository variables: ${MISSING[*]}"
  {
    echo "## 🚀 CI/CD Version & Target Discovery"
    echo ""
    echo "❌ Not configured. Set these under **Settings → Secrets and variables → Actions → Variables**, on the organisation or on this repository:"
    echo ""
    # shellcheck disable=SC2016 # backticks are markdown, not command substitution
    printf -- '- `%s`\n' "${MISSING[@]}"
    echo ""
    echo "Nothing downstream can resolve a registry target without them, so no other job ran."
    echo ""
    echo "If this repository publishes neither an image nor a chart, call \`init.yml\` with \`ignore-docker: \"true\"\` and \`ignore-chart: \"true\"\` instead of setting them."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
