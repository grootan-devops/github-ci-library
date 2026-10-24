#!/usr/bin/env bash
# Write the Docker config Trivy reads to pull the image it scans, and publish
# the registry that image is pulled from.
#
# The scanned image comes from the primary registry, so only its credentials
# are written: the single registry's secret pair, or the primary registry's
# credentials in the REGISTRY_CONFIG group. With neither, an empty credential
# is written, as it always was, and Trivy pulls anonymously. The encoded
# credential is masked and only ever reaches jq on stdin.
#
# Docker Hub is reached under several hostnames; every key is written so the
# credential is found whichever one the client resolved.
#
# Env:
#   IMAGE_REPOSITORY  the image's repositories; with PROJECT_REGISTRY_NAME the
#                     first, a full <registry>/<path>, names the primary registry
#   IMAGE_REGISTRY, IMAGE_REGISTRY_USERNAME, IMAGE_REGISTRY_PASSWORD, or
#   PROJECT_REGISTRY_NAME and REGISTRY_CONFIG -- see scripts/registry/lib.sh
#
# Outputs (GITHUB_OUTPUT):
#   host        the primary registry, which the scan builds the image reference from
#   repository  the path in it
#
# Exit codes: 0 written; 1 the primary repository is incomplete; 2 the registry
# configuration is invalid.
set -euo pipefail

: "${IMAGE_REGISTRY:=}"
: "${IMAGE_REPOSITORY:=}"

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"

FIRST="$(registry_primary "${IMAGE_REPOSITORY}")"
PRIMARY="${IMAGE_REGISTRY}"
REPOSITORY="${FIRST}"
REG_USER=""
REG_PASS=""
if { registry_named && [[ -n "${FIRST}" ]]; } || { ! registry_named && [[ -n "${IMAGE_REGISTRY}" ]]; }; then
  STATUS=0
  registry_resolve image "${FIRST}" || STATUS=$?
  if [[ ${STATUS} -ne 0 ]]; then
    exit "${STATUS}"
  fi
  PRIMARY="${REGISTRY_PRIMARY}"
  REPOSITORY="${REGISTRY_REPOS[0]}"
  registry_credentials 0 || STATUS=$?
  if [[ ${STATUS} -eq 2 ]]; then
    exit 2
  fi
fi
AUTH="$(printf '%s:%s' "${REG_USER}" "${REG_PASS}" | base64 -w0)"
REG_USER=""
REG_PASS=""
registry_mask "${AUTH}"

mkdir -p ~/.docker
if registry_is_docker_hub "${PRIMARY}"; then
  printf '%s' "${AUTH}" | jq -R '{auths: {
    "https://index.docker.io/v1/": {auth: .},
    "registry-1.docker.io": {auth: .},
    "index.docker.io": {auth: .},
    "docker.io": {auth: .}
  }}' > ~/.docker/config.json
else
  printf '%s' "${AUTH}" | jq -R --arg reg "${PRIMARY}" '{auths: {($reg): {auth: .}}}' > ~/.docker/config.json
fi
{
  echo "host=${PRIMARY}"
  echo "repository=${REPOSITORY}"
} >> "${GITHUB_OUTPUT}"
