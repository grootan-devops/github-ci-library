#!/usr/bin/env bash
# Confirm the image the compose file will reference exists before committing.
#
# The check logs in to the primary image registry, as it always has, with its
# secret pair or its credentials in the REGISTRY_CONFIG group. Komodo
# deployments have always required this check, so missing credentials fail it.
#
# Exit codes: 0 the image resolves; 1 it does not resolve, or the registry has
# no credentials or refused them; 2 the registry configuration is invalid.
#
# Env:
#   TARGET                   image reference the deployment will write
#   IMAGE_REPOSITORY         base image repository; the first names the primary
#                            registry with PROJECT_REGISTRY_NAME
#   IMAGE_REGISTRY, IMAGE_REGISTRY_USERNAME, IMAGE_REGISTRY_PASSWORD, or
#   PROJECT_REGISTRY_NAME and REGISTRY_CONFIG -- see scripts/registry/lib.sh
#
# Runner-provided: GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${TARGET:?TARGET must be set}"

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../registry/lib.sh"

STATUS=0
registry_resolve image "$(registry_primary "${IMAGE_REPOSITORY:-}")" || STATUS=$?
if [[ ${STATUS} -ne 0 ]]; then
  exit "${STATUS}"
fi
registry_login crane 0 || exit $?

if ! MANIFEST_OUTPUT="$(crane manifest "${TARGET}" 2>&1)"; then
  echo "${MANIFEST_OUTPUT}" >&2
  echo "::error::Container image '${TARGET}' does not exist. Refusing to commit a GitOps change that cannot resolve."
  {
    echo "### 🔎 Deployment prerequisites"
    echo ""
    echo "❌ Nothing was deployed: \`${TARGET}\` does not resolve, so the compose file would point at an image the stack cannot pull. crane reported:"
    echo ""
    echo '```'
    tail -n 20 <<< "${MANIFEST_OUTPUT}"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "Image ${TARGET} verified."
