#!/usr/bin/env bash
# Promote the scanned candidate chart to the production repository. On Docker
# Hub the candidate and production repositories are intentionally identical;
# only the candidate/release chart versions differ.
#
# A release must publish the exact bytes that were scanned, not a fresh build
# of whatever the working tree happens to hold. So the candidate is pulled
# back out of the candidate repository -- by exact version when the caller knows it,
# otherwise the newest candidate matching the tag -- and re-packaged at the
# release tag. Packaging from the working tree is a last resort and warns
# loudly, because those bytes never went through the scan.
#
# Env:
#   CHART_NAME            chart name
#   TAG                   production tag to promote to (default: none)
#   CANDIDATE_VERSION     exact candidate version to promote (default: newest
#                         candidate matching ^${TAG}-0)
#   DEV_REPOSITORY        candidate repository to promote from (same as the
#                         production repository on Docker Hub; default: none)
#   PROD_REPOSITORY       production repository to push to
#   CHART_REGISTRY        OCI registry host
#   CHART_DIR             working-tree chart directory (default: ./chart)
#   CHART_INFO_FILE_NAME  file the published details are written to
#                         (default: CHART_INFO.md)
#   GITHUB_STEP_SUMMARY   GitHub-provided; appended to
#
# Exit codes: 0 promoted; 1 no candidate and no local chart to fall back to,
# or the production repository refused the package. These gate the release.
set -euo pipefail

: "${CHART_NAME:?CHART_NAME must be set}"
: "${PROD_REPOSITORY:?PROD_REPOSITORY must be set}"
: "${TAG:?Release tag must be set}"
: "${CANDIDATE_VERSION:=}"
: "${DEV_REPOSITORY:=}"
# shellcheck source=scripts/chart/registry.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
chart_registry_validate
: "${CHART_DIR:=./chart}"
: "${CHART_INFO_FILE_NAME:=CHART_INFO.md}"

DEV_REF="oci://${CHART_REGISTRY}/${DEV_REPOSITORY}/${CHART_NAME}"
PROMOTE_TEMP=$(mktemp -d)
trap 'rm -rf "${PROMOTE_TEMP}"' EXIT
PULLED=0

for VERSION in "${CANDIDATE_VERSION}" "^${TAG}-0"; do
  [[ -n "${VERSION}" ]] || continue
  if METADATA=$(chart_oci_lookup "${DEV_REF}" "${VERSION}"); then
    LATEST=$(printf '%s' "${METADATA}" | yq -er '.version')
    if ! helm pull "${DEV_REF}" --version "${LATEST}" --untar --untardir "${PROMOTE_TEMP}" >/dev/null 2>&1; then
      echo "::error title=Chart promote::Candidate exists but could not be pulled; refusing a working-tree fallback."
      exit 1
    fi
    PULLED=1
    PROMOTED_FROM="${LATEST}"
    break
  else
    RESULT=$?
    [[ "${RESULT}" -eq 1 ]] || exit "${RESULT}"
  fi
done

if [[ ${PULLED} -eq 1 ]]; then
  echo "🚀 Re-packaging the scanned candidate at ${TAG}..."
  helm package "${PROMOTE_TEMP}/${CHART_NAME}" --version "${TAG}" --app-version "${TAG}"
elif [[ -f "${CHART_DIR}/Chart.yaml" ]]; then
  echo "::warning title=Chart promote::No candidate found — packaging from the working tree instead. These bytes were not scanned as a candidate."
  PROMOTED_FROM="working tree"
  chart_dependency_login
  helm dependency update "${CHART_DIR}/"
  helm package "${CHART_DIR}" --version "${TAG}" --app-version "${TAG}"
else
  echo "::error title=Chart promote::No candidate and no local chart to publish."
  {
    echo "### ⎈ Helm Chart Package Info"
    echo ""
    echo "❌ \`${TAG}\` was not promoted: nothing in \`${DEV_REF}\` matched \`${CANDIDATE_VERSION:-^${TAG}-0}\`, and there is no \`${CHART_DIR}/Chart.yaml\` to fall back to. The production repository is unchanged."
    echo ""
    echo "Verify the candidate version and repository passed from init.yml."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

if ! helm push "${CHART_NAME}-${TAG}.tgz" "oci://${CHART_REGISTRY}/${PROD_REPOSITORY}" >/dev/null 2>&1; then
  echo "::error title=Chart promote::The production repository refused ${CHART_NAME}-${TAG}.tgz."
  {
    echo "### ⎈ Helm Chart Package Info"
    echo ""
    echo "❌ \`oci://${CHART_REGISTRY}/${PROD_REPOSITORY}\` refused \`${CHART_NAME}-${TAG}.tgz\`. The candidate \`${PROMOTED_FROM}\` is unchanged. Check chart credentials, repository permissions and registry connectivity."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "Published ${CHART_NAME}:${TAG}."

{
  echo "### ⎈ Helm Chart Package Info"
  echo "- **📦 Name:** \`${CHART_NAME}\`"
  echo "- **🏷️ Version:** \`${TAG}\`"
  echo "- **🌐 Registry:** \`oci://${CHART_REGISTRY}/${PROD_REPOSITORY}\`"
  echo "- **🔗 Promoted from:** \`${PROMOTED_FROM}\`"
} > "${CHART_INFO_FILE_NAME}"
cat "${CHART_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
