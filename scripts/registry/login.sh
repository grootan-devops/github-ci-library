#!/usr/bin/env bash
# Log one tool in to the primary registry of an artifact kind.
#
# docker/login-action takes a host and a pair, but the primary's credentials
# may come from a REGISTRY_CONFIG group, and those must never travel through a
# step output. So workflow logins go through here and lib.sh: the primary's own
# credentials, with the password only ever on stdin. The other registries are
# logged in to by the scripts that copy or push to them.
#
# Env:
#   TOOL          docker | crane | helm
#   KIND          image | chart | dependency: whose registry and credentials apply
#   REPOSITORIES  the KIND's repositories, which with vars.PROJECT_REGISTRY_NAME
#                 name the registries (default: empty)
#   OPTIONAL      "true" uses a registry without credentials anonymously instead
#                 of failing (default: false)
#   IMAGE_REGISTRY, CHART_REGISTRY, CHART_DEPENDENCY_REGISTRY and their secret
#   pairs, or PROJECT_REGISTRY_NAME and REGISTRY_CONFIG -- see lib.sh
#
# Exit codes: 0 logged in; 1 the registry has no credentials or refused them;
# 2 configuration error.
set -euo pipefail

: "${TOOL:?TOOL must be set}"
: "${KIND:?KIND must be set}"
: "${REPOSITORIES:=}"
: "${OPTIONAL:=false}"

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS=0
registry_resolve "${KIND}" "${REPOSITORIES}" || STATUS=$?
if [[ ${STATUS} -ne 0 ]]; then
  exit "${STATUS}"
fi

ARGS=()
if [[ "${OPTIONAL}" == "true" ]]; then
  ARGS+=(--optional)
fi
registry_login "${ARGS[@]}" "${TOOL}" 0
