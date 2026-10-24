#!/usr/bin/env bash
# Publish an artifact's registry targets for the steps that follow.
#
# A workflow expression can neither split a list nor check a repository against
# REGISTRY_CONFIG, so the targets are resolved here, by lib.sh's rules, and
# handed over through GITHUB_OUTPUT. Only hosts and repositories are written,
# never credentials. A single registry produces exactly the one reference it
# always did.
#
# Env:
#   KIND          image | chart
#   REPOSITORIES  the path in vars.IMAGE_REGISTRY or vars.CHART_REGISTRY, or with
#                 vars.PROJECT_REGISTRY_NAME the full <registry>/<path> repositories
#   TAG           tag of the primary reference (default: empty, no ref output)
#   IMAGE_REGISTRY or CHART_REGISTRY, or PROJECT_REGISTRY_NAME and
#   REGISTRY_CONFIG -- see lib.sh
#
# Outputs (GITHUB_OUTPUT):
#   primary     the primary registry's host
#   repository  the primary's repository
#   ref         primary/repository:tag, when TAG is set
#   others      "true" when there are registries besides the primary
#
# Exit codes: 0 resolved; 1 a registry or a repository is missing; 2 the
# configuration is invalid.
set -euo pipefail

: "${KIND:?KIND must be set}"
: "${REPOSITORIES?REPOSITORIES must be set}"
: "${TAG:=}"

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS=0
registry_resolve "${KIND}" "${REPOSITORIES}" || STATUS=$?
if [[ ${STATUS} -ne 0 ]]; then
  exit "${STATUS}"
fi

OTHERS="false"
if [[ ${#REGISTRY_HOSTS[@]} -gt 1 ]]; then
  OTHERS="true"
fi
{
  echo "primary=${REGISTRY_PRIMARY}"
  echo "repository=${REGISTRY_REPOS[0]}"
  if [[ -n "${TAG}" ]]; then
    echo "ref=${REGISTRY_PRIMARY}/${REGISTRY_REPOS[0]}:${TAG}"
  fi
  echo "others=${OTHERS}"
} >> "${GITHUB_OUTPUT}"

for i in "${!REGISTRY_HOSTS[@]}"; do
  echo "Target: ${REGISTRY_HOSTS[i]}/${REGISTRY_REPOS[i]}${TAG:+:${TAG}}"
done
