#!/usr/bin/env bash
# Write the new chart version or container image into the GitOps checkout.
#
# Runs with the GitOps repository as the working directory. A missing values
# or manifest file is the common failure here -- a renamed path in the GitOps
# repo, or an app entry that was never added -- and `yq` would happily create
# the file or the key and produce a commit that deploys nothing. Each path is
# checked first, and a refusal lists what the repository root actually holds
# so the caller can see the rename without cloning anything.
#
# Exit codes: 0 the files were updated, 1 a target path does not exist.
#
# Env:
#   MODE                "manifest" for a Kubernetes manifest, otherwise Helm
#   GITOPS_REPO         GitOps repository, named in the refusal summary
#   CHART_NAME          chart name, used in the log line and commit message
#   MANIFEST_PATH       manifest to rewrite (manifest mode)
#   NEW_IMAGE           image reference written to the manifest (manifest mode);
#                       also the source of the image repository and so required
#                       whenever IMAGE_VALUES_FILE is set (Helm mode)
#   VALUES_PATH         values.yaml to rewrite (Helm mode)
#   APP_PATH            yq path to the application entry (Helm mode)
#   TARGET_VERSION      chart version to write (Helm mode)
#   CHART_REPO_URL      chart repoURL to write; skipped when empty (Helm mode)
#   IMAGE_VALUES_FILE   separate image values.yaml; skipped when empty
#   IMAGE_REPO_YQ_PATH  yq path to the image repository in IMAGE_VALUES_FILE
#   IMAGE_TAG_YQ_PATH   yq path to the image tag in IMAGE_VALUES_FILE
set -euo pipefail

: "${MODE:=}"
: "${GITOPS_REPO:=}"
: "${CHART_NAME:=}"
: "${MANIFEST_PATH:=}"
: "${NEW_IMAGE:=}"
: "${VALUES_PATH:=}"
: "${APP_PATH:=}"
: "${TARGET_VERSION:=}"
: "${CHART_REPO_URL:=}"
: "${IMAGE_VALUES_FILE:=}"
: "${IMAGE_REPO_YQ_PATH:=}"
: "${IMAGE_TAG_YQ_PATH:=}"

gitops_refuse() {
  {
    echo "### 🚢 GitOps commit"
    echo ""
    echo "❌ \`${GITOPS_REPO}\` was not updated: ${1}"
    echo ""
    echo '```'
    echo "${2}"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
}

if [[ "${MODE}" == "manifest" ]]; then
  echo "Updating manifest ${MANIFEST_PATH} -> image = ${NEW_IMAGE}..."
  if [[ ! -f "${MANIFEST_PATH}" ]]; then
    echo "::error::Manifest file not found: ${MANIFEST_PATH}"
    gitops_refuse "\`${MANIFEST_PATH}\` does not exist in the GitOps repository. These are at its root:" "$(ls -1)"
  fi
  PREVIOUS="$(yq -r '.spec.template.spec.containers[0].image // .spec.containers[0].image // ""' "${MANIFEST_PATH}" 2>/dev/null || echo "")"
  yq eval '(.spec.template.spec.containers[0].image // .spec.containers[0].image) = "'"${NEW_IMAGE}"'"' -i "${MANIFEST_PATH}"
  {
    echo "previous=${PREVIOUS}"
    echo "current=${NEW_IMAGE}"
    echo "skip=false"
    echo "commit_msg=chore(deploy): update ${MANIFEST_PATH} image to ${NEW_IMAGE} [skip ci]"
  } >> "${GITHUB_OUTPUT}"
else
  if [[ ! -f "${VALUES_PATH}" ]]; then
    echo "::error::Values file not found: ${VALUES_PATH}"
    gitops_refuse "\`${VALUES_PATH}\` does not exist in the GitOps repository. These are at its root:" "$(ls -1)"
  fi

  echo "Updating ${CHART_NAME:-chart} (${APP_PATH}) to ${TARGET_VERSION} in ${VALUES_PATH}..."
  PREVIOUS="$(yq -r "${APP_PATH}.chart.version // \"\"" "${VALUES_PATH}" 2>/dev/null || echo "")"
  if [[ -n "${CHART_REPO_URL}" ]]; then
    yq eval "${APP_PATH}.chart.repoURL = \"${CHART_REPO_URL}\"" -i "${VALUES_PATH}"
  fi
  yq eval "${APP_PATH}.chart.version = \"${TARGET_VERSION}\"" -i "${VALUES_PATH}"

  if [[ -n "${IMAGE_VALUES_FILE}" ]]; then
    if [[ ! -f "${IMAGE_VALUES_FILE}" ]]; then
      echo "::error::Image values file not found: ${IMAGE_VALUES_FILE}"
      gitops_refuse "\`${IMAGE_VALUES_FILE}\` does not exist in the GitOps repository. These are at its root:" "$(ls -1)"
    fi
    # The image repository is not the chart repository. `chart-repository` and
    # `image-repository` are separate inputs and resolve-target.sh builds two
    # different paths from them, so writing CHART_REPO_URL here pointed the
    # cluster at an OCI chart path and every pod landed in ImagePullBackOff.
    # The repository comes from NEW_IMAGE -- the reference the validate job
    # already proved resolves -- with its digest or tag stripped.
    if [[ -z "${NEW_IMAGE}" ]]; then
      echo "::error::No image reference was resolved, so ${IMAGE_REPO_YQ_PATH} in ${IMAGE_VALUES_FILE} has nothing to be set to"
      gitops_refuse "\`${IMAGE_VALUES_FILE}\` needs an image reference, and none was resolved. Set \`image-repository\` (with \`registry-host\`) or \`new-image\`." "NEW_IMAGE is empty"
    fi
    IMAGE_REPO_URL="${NEW_IMAGE%%@*}"
    # Strip the tag only when the colon sits after the last slash; a registry
    # port (registry:5000/team/app) puts a colon before it.
    if [[ "${IMAGE_REPO_URL##*/}" == *:* ]]; then
      IMAGE_REPO_URL="${IMAGE_REPO_URL%:*}"
    fi
    export IMAGE_REPO_URL
    echo "Updating image repo (${IMAGE_REPO_YQ_PATH}) to ${IMAGE_REPO_URL} and tag (${IMAGE_TAG_YQ_PATH}) in ${IMAGE_VALUES_FILE}..."
    yq eval "${IMAGE_REPO_YQ_PATH} = strenv(IMAGE_REPO_URL)" -i "${IMAGE_VALUES_FILE}"
    yq eval "${IMAGE_TAG_YQ_PATH} = \"${TARGET_VERSION}\"" -i "${IMAGE_VALUES_FILE}"
  fi
  {
    echo "previous=${PREVIOUS}"
    echo "current=${TARGET_VERSION}"
    echo "skip=false"
    echo "commit_msg=chore(deploy): update ${CHART_NAME:-workload} to ${TARGET_VERSION} [skip ci]"
  } >> "${GITHUB_OUTPUT}"
fi

git --no-pager diff
