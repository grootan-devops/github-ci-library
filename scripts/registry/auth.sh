#!/usr/bin/env bash
# Prepare a job to use its registries: write the one Docker config.json every tool reads,
# export it and the non-secret registry settings to the later steps (GITHUB_ENV), and
# output the selected image and chart destinations.
#
# Usage: auth.sh            the primary destinations
#        auth.sh deploy     DEPLOY_IMAGE_REPOSITORY / DEPLOY_CHART_REPOSITORY when set
#
# Outputs (GITHUB_OUTPUT):
#   image-registry, image-repository, image-dev-repository
#   chart-registry, chart-repository, chart-dev-repository
# Env for the later steps (GITHUB_ENV): DOCKER_CONFIG, HELM_REGISTRY_CONFIG,
#   REGISTRY_AUTH_FILE, REGISTRY_HOST (the selected image host) and the registry settings.
#
# Env: see scripts/registry/lib.sh. REGISTRY_CONFIG stays in this step: later steps get
# REGISTRY_CONFIG_PUBLIC, the same settings without credentials.
#
# Exit codes: 0 ready, 1 invalid registry configuration.
set -euo pipefail

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="${1:-primary}"
AUTH_DIR="${RUNNER_TEMP:-/tmp}/registry-auth"

registry_auth "${AUTH_DIR}"
PUBLIC=$(registry_config_json | jq -c 'with_entries(.value |= (if type == "object" then {dev} | with_entries(select(.value != null)) else {} end))')

{
  echo "DOCKER_CONFIG=${DOCKER_CONFIG}"
  echo "HELM_REGISTRY_CONFIG=${HELM_REGISTRY_CONFIG}"
  echo "REGISTRY_AUTH_FILE=${REGISTRY_AUTH_FILE}"
  echo "REGISTRY_CONFIG_PUBLIC=${PUBLIC}"
  echo "IMAGE_REGISTRY=${IMAGE_REGISTRY:-}"
  echo "IMAGE_REPOSITORY=${IMAGE_REPOSITORY:-}"
  echo "IMAGE_DEV_REPOSITORY_SUFFIX=${IMAGE_DEV_REPOSITORY_SUFFIX:-}"
  echo "CHART_REGISTRY=${CHART_REGISTRY:-}"
  echo "CHART_REPOSITORY=${CHART_REPOSITORY:-}"
  echo "CHART_DEV_REPOSITORY_SUFFIX=${CHART_DEV_REPOSITORY_SUFFIX:-}"
} >> "${GITHUB_ENV}"

for KIND in image chart; do
  SELECT=""
  if [[ "${MODE}" == "deploy" ]]; then
    VAR="DEPLOY_${KIND^^}_REPOSITORY"
    SELECT="${!VAR:-}"
  fi
  if ! registry_select "${KIND}" "${SELECT}" 2>/tmp/registry-select.err; then
    # A repository that publishes no charts may leave them unresolvable; the jobs that
    # need a chart destination fail on their own.
    if [[ "${KIND}" == "chart" && -z "${SELECT}" ]]; then
      continue
    fi
    cat /tmp/registry-select.err >&2
    exit 1
  fi
  {
    echo "${KIND}-registry=${SELECTED_HOST}"
    echo "${KIND}-repository=${SELECTED_STABLE}"
    echo "${KIND}-dev-repository=${SELECTED_DEV}"
  } >> "${GITHUB_OUTPUT}"
  # The image host is also REGISTRY_HOST, which the image scripts read.
  [[ "${KIND}" == "image" ]] && echo "REGISTRY_HOST=${SELECTED_HOST}" >> "${GITHUB_ENV}"
  echo "${KIND^} destinations (stable | dev), primary first:"
  registry_targets "${KIND}" | awk -F'\t' '{print "  " $1 "/" $2 " | " $1 "/" $3}'
done
