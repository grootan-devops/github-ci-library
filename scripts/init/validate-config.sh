#!/usr/bin/env bash
# Guard: the organisation registry variables are set before anything resolves a target.
#
# Images and charts may use different registries and credentials. Validate only
# the artifact types enabled by this caller: a chart-only repository must not be
# forced to configure IMAGE_REGISTRY or IMAGE_REPOSITORY, while a repository
# publishing both artifacts must configure both sets.
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
#   IMAGE_REGISTRY_INPUT     vars.IMAGE_REGISTRY (default: empty, which is the failure)
#   IMAGE_REPOSITORY_INPUT   vars.IMAGE_REPOSITORY (default: empty, which is the failure)
#   IMAGE_REGISTRY_USERNAME  secrets.IMAGE_REGISTRY_USERNAME (default: empty)
#   IMAGE_REGISTRY_PASSWORD  secrets.IMAGE_REGISTRY_PASSWORD (default: empty)
#   CHART_REGISTRY_INPUT     vars.CHART_REGISTRY (default: empty, which is the failure)
#   CHART_REPOSITORY_INPUT   vars.CHART_REPOSITORY (default: empty, which is the failure)
#   CHART_REGISTRY_USERNAME  secrets.CHART_REGISTRY_USERNAME (default: empty)
#   CHART_REGISTRY_PASSWORD  secrets.CHART_REGISTRY_PASSWORD (default: empty)
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
  local input="${1,,}" present="${2}"
  case "${input}" in
    true)  return 1 ;;
    false) return 0 ;;
    auto|"") [[ "${present}" == "true" ]] ;;
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

MISSING=()
if [[ "${PUBLISH_DOCKER}" == "true" ]]; then
  [[ -n "${IMAGE_REGISTRY_INPUT}" ]] || MISSING+=("vars.IMAGE_REGISTRY")
  [[ -n "${IMAGE_REPOSITORY_INPUT}" ]] || MISSING+=("vars.IMAGE_REPOSITORY")
  [[ -n "${IMAGE_REGISTRY_USERNAME}" ]] || MISSING+=("secrets.IMAGE_REGISTRY_USERNAME")
  [[ -n "${IMAGE_REGISTRY_PASSWORD}" ]] || MISSING+=("secrets.IMAGE_REGISTRY_PASSWORD")
fi
if [[ "${PUBLISH_CHART}" == "true" ]]; then
  [[ -n "${CHART_REGISTRY_INPUT}" ]] || MISSING+=("vars.CHART_REGISTRY")
  [[ -n "${CHART_REPOSITORY_INPUT}" ]] || MISSING+=("vars.CHART_REPOSITORY")
  [[ -n "${CHART_REGISTRY_USERNAME}" ]] || MISSING+=("secrets.CHART_REGISTRY_USERNAME")
  [[ -n "${CHART_REGISTRY_PASSWORD}" ]] || MISSING+=("secrets.CHART_REGISTRY_PASSWORD")
fi
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
