#!/usr/bin/env bash
# Confirm the Helm chart version exists in the registry before the GitOps commit.
#
# The GitOps commit is the point of no return: once `chart.version` is pushed,
# ArgoCD will try to pull that chart on its next reconcile. If the chart job
# never published the version -- a failed build, a typo in `chart-version`, a
# candidate that went to a different repository -- ArgoCD is left pointing at
# something that does not resolve, and the environment is stuck until someone
# reverts the commit by hand. `helm show chart` here is cheap; that is not.
#
# Exit codes: 0 the chart resolves, 1 credentials are missing or it does not.
#
# Env:
#   REGISTRY_HOST      registry hostname to log in to
#   REGISTRY_USERNAME  registry username (mandatory)
#   REGISTRY_PASSWORD  registry password or token (mandatory)
#   CHART_REPO_URL     resolved chart repository, without the oci:// scheme
#   CHART_NAME         Helm chart name
#   TARGET_VERSION     chart version that must exist
set -euo pipefail

: "${REGISTRY_HOST:=}"
: "${REGISTRY_USERNAME:=}"
: "${REGISTRY_PASSWORD:=}"
: "${CHART_REPO_URL:=}"
: "${CHART_NAME:=}"
: "${TARGET_VERSION:=}"

if [[ -z "${REGISTRY_USERNAME}" || -z "${REGISTRY_PASSWORD}" ]]; then
  echo "::error::REGISTRY_USERNAME / REGISTRY_PASSWORD are required to verify the chart before deploying."
  exit 1
fi
printf '%s' "${REGISTRY_PASSWORD}" | helm registry login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password-stdin

TARGET="oci://${CHART_REPO_URL}/${CHART_NAME}"
VERSION="${TARGET_VERSION}"
if ! CHART_OUTPUT="$(helm show chart "${TARGET}" --version "${VERSION}" 2>&1)"; then
  echo "${CHART_OUTPUT}" >&2
  echo "::error::Helm chart '${CHART_NAME}' version '${VERSION}' does not exist at ${TARGET}. Refusing to commit a GitOps change that cannot resolve."
  {
    echo "### 🔎 Deployment prerequisites"
    echo ""
    echo "❌ Nothing was deployed: \`${TARGET}\` has no version \`${VERSION}\`, so the GitOps commit would point ArgoCD at a chart that does not exist. Helm reported:"
    echo ""
    echo '```'
    tail -n 20 <<< "${CHART_OUTPUT}"
    echo '```'
    echo ""
    echo "Check that the chart job published \`${VERSION}\` to the candidate repository before this deploy ran."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "Chart ${CHART_NAME}:${TARGET_VERSION} verified at ${TARGET}."
