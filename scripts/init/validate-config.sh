#!/usr/bin/env bash
# Guard: the organisation registry variables are set before anything resolves a target.
#
# Images and charts may use different registries and credentials. Validate only
# the artifact types enabled by this caller: a chart-only repository must not be
# forced to configure IMAGE_REGISTRY or IMAGE_REPOSITORY, while a repository
# publishing both artifacts must configure both sets.
#
# Registries are configured one of two ways (scripts/registry/lib.sh): one
# registry per artifact through vars.IMAGE_REGISTRY / vars.CHART_REGISTRY and
# their secret pairs, or a credential group through vars.PROJECT_REGISTRY_NAME,
# which names a group of the REGISTRY_CONFIG secret. Setting both is ambiguous,
# so that is checked first and stops the run whatever this caller publishes.
# With a group, every repository a published artifact lists must be a full
# <registry>/<path> on one of the group's registries, and each of those
# registries needs a username and password. A single registry is reported word
# for word as it always was.
#
# Exit codes: 0 configured, or nothing to publish. 1 variables missing,
# inconsistent or ambiguous.
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
#   PROJECT_REGISTRY_NAME    vars.PROJECT_REGISTRY_NAME, the REGISTRY_CONFIG group to publish
#                            with (default: empty, one registry per artifact)
#   REGISTRY_CONFIG          secrets.REGISTRY_CONFIG, the credential groups (default: empty)
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
: "${PROJECT_REGISTRY_NAME:=}"
: "${REGISTRY_CONFIG:=}"

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"
# lib.sh reads each artifact's single registry under these names.
export IMAGE_REGISTRY="${IMAGE_REGISTRY_INPUT}" CHART_REGISTRY="${CHART_REGISTRY_INPUT}"

# Report an invalid configuration, whose annotations are already printed.
fail_invalid() {
  {
    echo "## 🚀 CI/CD Version & Target Discovery"
    echo ""
    echo "❌ $1 Nothing downstream ran."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
}

# A group and a single registry together leave no way to tell where to
# publish, so this holds whatever the caller publishes, and runs before
# anything else.
if ! registry_check_mode; then
  fail_invalid "\`vars.PROJECT_REGISTRY_NAME\` is set together with \`vars.IMAGE_REGISTRY\` or \`vars.CHART_REGISTRY\`, so it is unclear where to publish. Keep \`PROJECT_REGISTRY_NAME\` to publish to the full repositories \`vars.IMAGE_REPOSITORY\` and \`vars.CHART_REPOSITORY\` list, or the registry variables to publish to one registry per artifact, and remove the other."
fi

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
INVALID=false

# Record what one artifact lacks with a single registry. KIND is image or chart.
check_single() {
  local kind="$1" registry="$2" repositories="$3"
  local label="${kind^^}"
  local user="${label}_REGISTRY_USERNAME" pass="${label}_REGISTRY_PASSWORD"
  [[ -n "${registry}" ]] || MISSING+=("vars.${label}_REGISTRY")
  [[ -n "${repositories}" ]] || MISSING+=("vars.${label}_REPOSITORY")
  [[ -n "${!user}" ]] || MISSING+=("secrets.${user}")
  [[ -n "${!pass}" ]] || MISSING+=("secrets.${pass}")
  if [[ -n "${registry}" ]] && ! registry_resolve "${kind}" "${repositories}"; then
    INVALID=true
  fi
}

# Check the full repositories one artifact is published to: each is on a
# registry of the group, and each of those registries has a username and
# password.
check_named() {
  local kind="$1" repositories="$2" status
  local label="${kind^^}"
  if [[ -z "${repositories//[[:space:],]/}" ]]; then
    MISSING+=("vars.${label}_REPOSITORY")
    registry_group_load || INVALID=true
    return 0
  fi
  status=0
  registry_resolve "${kind}" "${repositories}" || status=$?
  if [[ ${status} -ne 0 ]]; then
    INVALID=true
    return 0
  fi
  registry_require_credentials || INVALID=true
}

if registry_named; then
  if [[ "${PUBLISH_DOCKER}" == "true" ]]; then
    check_named image "${IMAGE_REPOSITORY_INPUT}"
  fi
  if [[ "${PUBLISH_CHART}" == "true" ]]; then
    check_named chart "${CHART_REPOSITORY_INPUT}"
  fi
else
  if [[ "${PUBLISH_DOCKER}" == "true" ]]; then
    check_single image "${IMAGE_REGISTRY_INPUT}" "${IMAGE_REPOSITORY_INPUT}"
  fi
  if [[ "${PUBLISH_CHART}" == "true" ]]; then
    check_single chart "${CHART_REGISTRY_INPUT}" "${CHART_REPOSITORY_INPUT}"
  fi
fi
if [[ "${INVALID}" == "true" && ${#MISSING[@]} -eq 0 ]]; then
  fail_invalid "The registry configuration is inconsistent; the annotations above name each problem."
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
