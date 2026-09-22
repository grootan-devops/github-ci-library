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
: "${TAG:=}"
: "${CANDIDATE_VERSION:=}"
: "${DEV_REPOSITORY:=}"
: "${CHART_REGISTRY:?CHART_REGISTRY must be set}"
: "${CHART_DIR:=./chart}"
: "${CHART_INFO_FILE_NAME:=CHART_INFO.md}"

DEV_REF="oci://${CHART_REGISTRY}/${DEV_REPOSITORY}/${CHART_NAME}"
mkdir -p _promote
PULLED=0

if [[ -n "${CANDIDATE_VERSION}" ]] \
   && helm pull "${DEV_REF}" --version "${CANDIDATE_VERSION}" --untar --untardir _promote 2>/dev/null; then
  echo "📦 Pulled candidate ${CHART_NAME}:${CANDIDATE_VERSION}"
  PULLED=1
  # Provenance is recorded where the bytes are chosen, not inferred afterwards:
  # CANDIDATE_VERSION stays set even when the pull fails, so inferring it later
  # would credit the scanned candidate for an unscanned working-tree build.
  PROMOTED_FROM="${CANDIDATE_VERSION}"
else
  LATEST="$(helm show chart "${DEV_REF}" --version "^${TAG}-0" 2>/dev/null | yq -r '.version // ""' || true)"
  if [[ -n "${LATEST}" ]] \
     && helm pull "${DEV_REF}" --version "${LATEST}" --untar --untardir _promote 2>/dev/null; then
    echo "📦 Pulled newest candidate ${CHART_NAME}:${LATEST}"
    PULLED=1
    PROMOTED_FROM="${LATEST}"
  fi
fi

if [[ ${PULLED} -eq 1 ]]; then
  echo "🚀 Re-packaging the scanned candidate at ${TAG}..."
  helm package "_promote/${CHART_NAME}" --version "${TAG}" --app-version "${TAG}"
  rm -rf _promote
elif [[ -f "${CHART_DIR}/Chart.yaml" ]]; then
  echo "::warning title=Chart promote::No candidate found — packaging from the working tree instead. These bytes were not scanned as a candidate."
  PROMOTED_FROM="working tree"
  helm dependency update "${CHART_DIR}/"
  helm package "${CHART_DIR}" --version "${TAG}" --app-version "${TAG}"
else
  echo "::error title=Chart promote::No candidate and no local chart to publish."
  {
    echo "### ⎈ Helm Chart Package Info"
    echo ""
    echo "❌ \`${TAG}\` was not promoted: nothing in \`${DEV_REF}\` matched \`${CANDIDATE_VERSION:-^${TAG}-0}\`, and there is no \`${CHART_DIR}/Chart.yaml\` to fall back to. The production repository is unchanged."
    echo ""
    echo "Candidate versions currently published:"
    echo ""
    echo '```'
    helm show chart "${DEV_REF}" --version "^${TAG}-0" 2>&1 | head -n 20 || echo "(the dev repository could not be listed either)"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

if ! PUSH_OUTPUT="$(helm push "${CHART_NAME}-${TAG}.tgz" "oci://${CHART_REGISTRY}/${PROD_REPOSITORY}" 2>&1)"; then
  echo "${PUSH_OUTPUT}" >&2
  echo "::error title=Chart promote::The production repository refused ${CHART_NAME}-${TAG}.tgz."
  {
    echo "### ⎈ Helm Chart Package Info"
    echo ""
    echo "❌ \`oci://${CHART_REGISTRY}/${PROD_REPOSITORY}\` refused \`${CHART_NAME}-${TAG}.tgz\`. The candidate \`${PROMOTED_FROM}\` is unchanged in the dev repository. Helm reported:"
    echo ""
    echo '```'
    tail -n 30 <<< "${PUSH_OUTPUT}"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "${PUSH_OUTPUT}"

{
  echo "### ⎈ Helm Chart Package Info"
  echo "- **📦 Name:** \`${CHART_NAME}\`"
  echo "- **🏷️ Version:** \`${TAG}\`"
  echo "- **🌐 Registry:** \`oci://${CHART_REGISTRY}/${PROD_REPOSITORY}\`"
  echo "- **🔗 Promoted from:** \`${PROMOTED_FROM}\`"
} > "${CHART_INFO_FILE_NAME}"
cat "${CHART_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
