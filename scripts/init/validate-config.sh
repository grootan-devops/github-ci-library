#!/usr/bin/env bash
# Guard: the organisation registry variables are set before anything resolves a target.
#
# Every downstream job derives its push target from vars.IMAGE_REGISTRY and
# vars.IMAGE_REPOSITORY. Unset, they resolve to an empty host and an empty
# repository, and the run only fails much later at the push -- with an error
# that says nothing about the missing variable. Checking here names the
# variable and the settings page instead. A repository that publishes neither
# an image nor a chart has no target to resolve, so it is exempt.
#
# Exit codes: 0 configured, or nothing to publish. 1 variables missing.
#
# Env:
#   IGNORE_DOCKER_INPUT      inputs.ignore-docker, "true" when no image is published
#   IGNORE_CHART_INPUT       inputs.ignore-chart, "true" when no chart is published
#   REGISTRY_HOST            vars.IMAGE_REGISTRY (default: empty, which is the failure)
#   IMAGE_REPOSITORY_INPUT   vars.IMAGE_REPOSITORY (default: empty, which is the failure)
set -euo pipefail

: "${IGNORE_DOCKER_INPUT:=}"
: "${IGNORE_CHART_INPUT:=}"
: "${REGISTRY_HOST:=}"
: "${IMAGE_REPOSITORY_INPUT:=}"

if [[ "${IGNORE_DOCKER_INPUT,,}" == "true" && "${IGNORE_CHART_INPUT,,}" == "true" ]]; then
  echo "ignore-docker and ignore-chart are both set: no registry target to resolve."
  exit 0
fi

MISSING=()
if [[ -z "${REGISTRY_HOST}" ]]; then
  MISSING+=("vars.IMAGE_REGISTRY")
fi
if [[ -z "${IMAGE_REPOSITORY_INPUT}" ]]; then
  MISSING+=("vars.IMAGE_REPOSITORY")
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
