#!/usr/bin/env bash
# Pushes the built candidate image and exports its digest-pinned reference.
#
# A tag is mutable: the next build can move it, so anything that resolves
# `repo:tag` again later -- the scan, the promotion -- may get different bytes
# than the ones this step published. Resolving the digest here and handing
# downstream jobs `repo@sha256:...` pins them to exactly this image. The digest
# is shape-checked first, because a registry that answers a `crane digest` with
# an error page or an empty body would otherwise produce a reference that looks
# well-formed and resolves to nothing.
#
# The podman leg is teed to a log that "Publish Build Failure Summary" tails, so
# a failed push can quote the registry's own error in the run summary.
#
# Shell: GitHub runs step scripts with `-e -o pipefail` already set, and the
# `set -uo pipefail` this block used to open with did not clear that `-e`. The
# header below reproduces the flags that were actually in force; the inner
# `set -euo pipefail` is kept where it was, as it was, and is still a no-op.
#
# Env:
#   REGISTRY_HOST         registry to log in to and push to
#   REGISTRY_USERNAME     registry credentials
#   REGISTRY_PASSWORD     registry credentials
#   IMAGE_NAME            local image name buildah-build.sh committed to
#   IMAGE_REPOSITORY      repository to publish the candidate under
#   IMAGE_TAG             tag to publish
#   IMAGE_INFO_FILE_NAME  markdown summary written into the working directory
#
# Outputs (GITHUB_OUTPUT): IMAGE_REF_DIGEST
#
# Exit codes: 0 pushed; 1 the registry returned an unusable digest; otherwise
# podman's own exit code from the login/tag/push chain.
set -euo pipefail

# Unset-only guards (`?`, not `:?`): the block these came from ran under
# `set -u`, where an empty value was not fatal here. Rejecting empties would
# change the exit code a misconfigured registry variable produces.
: "${REGISTRY_HOST?REGISTRY_HOST must be set}"
: "${REGISTRY_USERNAME?REGISTRY_USERNAME must be set}"
: "${REGISTRY_PASSWORD?REGISTRY_PASSWORD must be set}"
: "${IMAGE_NAME?IMAGE_NAME must be set}"
: "${IMAGE_REPOSITORY?IMAGE_REPOSITORY must be set}"
: "${IMAGE_TAG?IMAGE_TAG must be set}"
: "${IMAGE_INFO_FILE_NAME?IMAGE_INFO_FILE_NAME must be set}"

{
  podman login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password "${REGISTRY_PASSWORD}" &&
  podman tag "${IMAGE_NAME}" "${REGISTRY_HOST}/${IMAGE_REPOSITORY}:${IMAGE_TAG}" &&
  podman push "${REGISTRY_HOST}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
} 2>&1 | tee "${RUNNER_TEMP}/podman-push.log"
PUSH_RESULT="${PIPESTATUS[0]}"
if [[ "${PUSH_RESULT}" -ne 0 ]]; then
  exit "${PUSH_RESULT}"
fi
set -euo pipefail

TARGET="${REGISTRY_HOST}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"

crane auth login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password "${REGISTRY_PASSWORD}"
DIGEST="$(crane digest "${TARGET}")"
if [[ ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error title=Image digest::The registry returned an invalid digest for ${TARGET}: ${DIGEST}"
  exit 1
fi
REF="${REGISTRY_HOST}/${IMAGE_REPOSITORY}@${DIGEST}"
echo "IMAGE_REF_DIGEST=${REF}" >> "${GITHUB_OUTPUT}"

{
  echo "### 🐳 Container Image"
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  echo "| **Tag** | \`${TARGET}\` |"
  echo "| **Digest** | \`${DIGEST}\` |"
  echo "| **Pinned reference** | \`${REF}\` |"
  echo ""
} > "${IMAGE_INFO_FILE_NAME}"
cat "${IMAGE_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
