#!/usr/bin/env bash
# Resolve the GitOps deployment target and refuse before anything is written.
#
# An ArgoCD deployment that is missing one input fails late: the GitOps commit
# is already pushed, ArgoCD has already started reconciling, and the operator
# is left reading a sync error to work out that `chart-app-yq-path` was never
# set. Everything this run needs -- Helm-vs-manifest mode, the chart repository
# URL, the image reference -- is decided here, and anything missing or
# contradictory stops the run with a step summary that names it.
#
# Exit codes: 0 resolved, 1 the configuration is missing or ambiguous.
#
# Env:
#   ENVIRONMENT          target environment, named in the step summary
#   ARGOCD_APP_NAME      space-separated ArgoCD application names (mandatory)
#   ARGOCD_SERVER        ArgoCD API server hostname (mandatory)
#   ARGOCD_AUTH_TOKEN    ArgoCD API token (mandatory)
#   GITOPS_REPO          GitOps repository holding the values (mandatory)
#   GITOPS_BRANCH        GitOps branch to commit to (mandatory)
#   CHART_VALUES_FILE    values.yaml path in the GitOps repo (Helm mode)
#   CHART_APP_YQ_PATH    yq path to the application entry (Helm mode)
#   IMAGE_VALUES_FILE    separate image values.yaml (Helm mode, optional)
#   IMAGE_REPO_YQ_PATH   yq path to the image repository (with IMAGE_VALUES_FILE)
#   IMAGE_TAG_YQ_PATH    yq path to the image tag (with IMAGE_VALUES_FILE)
#   MANIFEST_FILE        Kubernetes manifest path (manifest mode)
#   NEW_IMAGE_INPUT      explicit image reference (mandatory in manifest mode)
#   CHART_VERSION        chart version to deploy
#   REGISTRY_HOST        registry hostname
#   CHART_REPOSITORY     base chart repository path
#   IMAGE_REPOSITORY     base image repository path
#   DEV_SUFFIX           suffix appended to the repository paths
set -euo pipefail

: "${ENVIRONMENT:=}"
: "${ARGOCD_APP_NAME:=}"
: "${ARGOCD_SERVER:=}"
: "${ARGOCD_AUTH_TOKEN:=}"
: "${GITOPS_REPO:=}"
: "${GITOPS_BRANCH:=}"
: "${CHART_VALUES_FILE:=}"
: "${CHART_APP_YQ_PATH:=}"
: "${IMAGE_VALUES_FILE:=}"
: "${IMAGE_REPO_YQ_PATH:=}"
: "${IMAGE_TAG_YQ_PATH:=}"
: "${MANIFEST_FILE:=}"
: "${NEW_IMAGE_INPUT:=}"
: "${CHART_VERSION:=}"
: "${REGISTRY_HOST:=}"
: "${CHART_REPOSITORY:=}"
: "${IMAGE_REPOSITORY:=}"
: "${DEV_SUFFIX:=}"

refuse() {
  {
    echo "### 🔎 Deployment prerequisites"
    echo ""
    echo "❌ Nothing was deployed to **${ENVIRONMENT}**: ${1}"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
}

MISSING=()
if [[ -z "${ARGOCD_APP_NAME}" ]]; then
  MISSING+=("argocd-app-name")
fi
if [[ -z "${ARGOCD_SERVER}" ]]; then
  MISSING+=("argocd-server")
fi
if [[ -z "${ARGOCD_AUTH_TOKEN}" ]]; then
  MISSING+=("ARGOCD_AUTH_TOKEN secret")
fi
if [[ -z "${GITOPS_REPO}" ]]; then
  MISSING+=("gitops-repo")
fi
if [[ -z "${GITOPS_BRANCH}" ]]; then
  MISSING+=("gitops-branch")
fi
# These three are interpolated straight into a registry reference below. Empty
# yields `host//dev` or an empty tag, which the registry rejects with a parse
# error rather than anything that points at the missing input.
if [[ -z "${CHART_REPOSITORY}" && -z "${NEW_IMAGE_INPUT}" ]]; then
  MISSING+=("chart-repository")
fi
if [[ -z "${IMAGE_REPOSITORY}" && -z "${NEW_IMAGE_INPUT}" ]]; then
  MISSING+=("image-repository")
fi
if [[ -z "${CHART_VERSION}" && -z "${NEW_IMAGE_INPUT}" ]]; then
  MISSING+=("chart-version")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "::error::[HARD FAILURE] Missing mandatory deployment configuration: ${MISSING[*]}"
  {
    echo "### 🔎 Deployment prerequisites"
    echo ""
    echo "❌ Nothing was deployed to **${ENVIRONMENT}**. These are not configured:"
    echo ""
    # shellcheck disable=SC2016 # backticks are markdown, not command substitution
    printf -- '- `%s`\n' "${MISSING[@]}"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

RESOLVED_CHART_APP_YQ_PATH="${CHART_APP_YQ_PATH}"
MODE=""
if [[ -n "${CHART_VALUES_FILE}" || -n "${RESOLVED_CHART_APP_YQ_PATH}" ]]; then
  MODE="helm"
fi
if [[ -n "${MANIFEST_FILE}" ]]; then
  if [[ -n "${MODE}" ]]; then
    echo "::error::[HARD FAILURE] Both Helm parameters (chart-values-file/chart-app-yq-path) and Manifest parameters (manifest-file) are configured. Choose either Helm or Manifest deployment."
    refuse "both the Helm inputs (\`chart-values-file\`/\`chart-app-yq-path\`) and the manifest input (\`manifest-file\`) are set, so the target is ambiguous. Choose one."
  fi
  MODE="manifest"
fi

if [[ -z "${MODE}" ]]; then
  echo "::error::[HARD FAILURE] Either chart-values-file (for Helm) or manifest-file (for Manifest) must be configured."
  refuse "neither \`chart-values-file\` (Helm) nor \`manifest-file\` (Manifest) is set, so there is nothing to update in the GitOps repository."
fi

if [[ "${MODE}" == "helm" ]]; then
  if [[ -z "${RESOLVED_CHART_APP_YQ_PATH}" ]]; then
    echo "::error::[HARD FAILURE] chart-app-yq-path is mandatory when chart-values-file is specified."
    refuse "\`chart-values-file\` is set but \`chart-app-yq-path\` is not, so there is no path in the values file to write the version to."
  fi
  if [[ -n "${IMAGE_VALUES_FILE}" ]]; then
    HELM_IMG_MISSING=()
    if [[ -z "${IMAGE_REPO_YQ_PATH}" ]]; then
      HELM_IMG_MISSING+=("image-repo-yq-path")
    fi
    if [[ -z "${IMAGE_TAG_YQ_PATH}" ]]; then
      HELM_IMG_MISSING+=("image-tag-yq-path")
    fi
    if [[ ${#HELM_IMG_MISSING[@]} -gt 0 ]]; then
      echo "::error::[HARD FAILURE] When image-values-file is used with chart-values-file, the following are mandatory: ${HELM_IMG_MISSING[*]}"
      refuse "\`image-values-file\` is set, which also requires: ${HELM_IMG_MISSING[*]}."
    fi
  fi
elif [[ "${MODE}" == "manifest" ]]; then
  if [[ -z "${NEW_IMAGE_INPUT}" ]]; then
    echo "::error::[HARD FAILURE] new-image is mandatory when manifest-file is specified."
    refuse "\`manifest-file\` is set but \`new-image\` is not, so there is no image reference to write into the manifest."
  fi
fi

TARGET_VERSION="${CHART_VERSION}"

# Docker Hub has no nested repositories, so `<repo>/dev` is not a valid image
# target and the push side rewrites the separator. scripts/init/resolve-version.sh
# and scripts/scan/trivy.sh both do this; without it the deploy path looked for
# `<repo>/dev` while the image had been pushed and scanned at `<repo>-dev`.
# Charts are not rewritten: they live at an OCI path where nesting is legal,
# which is why init normalises the image suffix only.
IMAGE_DEV_SUFFIX="${DEV_SUFFIX}"
case "${REGISTRY_HOST}" in
  docker.io|index.docker.io|registry-1.docker.io)
    IMAGE_DEV_SUFFIX="${DEV_SUFFIX//\//-}"
    ;;
esac

CHART_REPO_URL="${REGISTRY_HOST}/${CHART_REPOSITORY}${DEV_SUFFIX}"
NEW_IMAGE="${NEW_IMAGE_INPUT:-${REGISTRY_HOST}/${IMAGE_REPOSITORY}${IMAGE_DEV_SUFFIX}:${TARGET_VERSION}}"

{
  echo "gitops_branch=${GITOPS_BRANCH}"
  echo "target_version=${TARGET_VERSION}"
  echo "chart_repo_url=${CHART_REPO_URL}"
  echo "new_image=${NEW_IMAGE}"
  echo "mode=${MODE}"
  echo "chart_values_file=${CHART_VALUES_FILE:-values.yaml}"
  echo "chart_app_yq_path=${RESOLVED_CHART_APP_YQ_PATH}"
  echo "manifest_file=${MANIFEST_FILE}"
} | tee -a "${GITHUB_OUTPUT}"
