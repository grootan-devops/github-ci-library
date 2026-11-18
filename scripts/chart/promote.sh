#!/usr/bin/env bash
# Promote the scanned candidate chart to the production repository. On Docker
# Hub the candidate and production repositories are intentionally identical;
# only the candidate/release chart versions differ.
#
# A release must publish the chart that was scanned, not a fresh build of
# whatever the working tree holds. So the exact candidate version init.yml
# named is pulled back out of the candidate repository and re-packaged at the
# release tag. Nothing is searched for and the working tree is never packaged:
# an empty or missing candidate refuses the release, because every pull request
# of a version publishes the same `<tag>-<run>.<n>` shape and the newest one is
# a guess.
#
# A production version that already exists is compared by content with the
# package about to be pushed: identical is a re-run and is left as it is, any
# difference refuses the release instead of overwriting it.
#
# Env:
#   CHART_NAME            chart name
#   TAG                   production tag to promote to (default: none)
#   CANDIDATE_VERSION     exact candidate version to promote; empty refuses
#   DEV_REPOSITORY        candidate repository to promote from (same as the
#                         production repository on Docker Hub; default: none)
#   PROD_REPOSITORY       production repository to push to
#   CHART_REGISTRY        OCI registry host
#   CHART_INFO_FILE_NAME  file the published details are written to
#                         (default: CHART_INFO.md)
#   GITHUB_STEP_SUMMARY   GitHub-provided; appended to
#
# Exit codes: 0 promoted (or already published with the same content); 1 no
# candidate named, the candidate is missing or cannot be pulled, the production
# version holds a different chart, or the production repository refused the
# package; 2 the registry could not be queried. These gate the release.
set -euo pipefail

: "${CHART_NAME:?CHART_NAME must be set}"
: "${PROD_REPOSITORY:?PROD_REPOSITORY must be set}"
: "${TAG:?Release tag must be set}"
: "${CANDIDATE_VERSION:=}"
: "${DEV_REPOSITORY:=}"
# shellcheck source=scripts/chart/registry.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
chart_registry_validate
: "${CHART_INFO_FILE_NAME:=CHART_INFO.md}"

DEV_REF="oci://${CHART_REGISTRY}/${DEV_REPOSITORY}/${CHART_NAME}"
PROD_REF="oci://${CHART_REGISTRY}/${PROD_REPOSITORY}/${CHART_NAME}"
PACKAGE="${CHART_NAME}-${TAG}.tgz"
PROMOTE_TEMP=$(mktemp -d)
trap 'rm -rf "${PROMOTE_TEMP}"' EXIT

refuse() {
  echo "::error title=Chart promote::$1"
  {
    echo "### ⎈ Helm Chart Package Info"
    echo ""
    echo "❌ $2 The production repository is unchanged."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
}

# One digest for a whole unpacked chart: every file's sha256, in path order.
tree_digest() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1
}

if [[ -z "${CANDIDATE_VERSION}" ]]; then
  refuse "No candidate chart version was named for ${TAG}." \
    "\`${TAG}\` was not promoted: no candidate chart version was named. init.yml names it from the merged pull request's successful run; a direct push or a pull request whose run did not succeed has none, and nothing is guessed."
fi

if chart_oci_lookup "${DEV_REF}" "${CANDIDATE_VERSION}" >/dev/null; then
  :
else
  RESULT=$?
  [[ "${RESULT}" -eq 1 ]] || exit "${RESULT}"
  refuse "Candidate ${DEV_REF}:${CANDIDATE_VERSION} does not exist." \
    "\`${TAG}\` was not promoted: the named candidate \`${DEV_REF}\` version \`${CANDIDATE_VERSION}\` does not exist, and no other candidate is tried. Check that the pull request published its candidate chart (\`publish-candidate\`)."
fi

mkdir -p "${PROMOTE_TEMP}/candidate"
if ! helm pull "${DEV_REF}" --version "${CANDIDATE_VERSION}" --untar --untardir "${PROMOTE_TEMP}/candidate" >/dev/null 2>&1; then
  refuse "Candidate ${CANDIDATE_VERSION} exists but could not be pulled." \
    "\`${DEV_REF}\` version \`${CANDIDATE_VERSION}\` exists but could not be pulled."
fi

echo "🚀 Re-packaging the scanned candidate ${CANDIDATE_VERSION} at ${TAG}..."
helm package "${PROMOTE_TEMP}/candidate/${CHART_NAME}" --version "${TAG}" --app-version "${TAG}"

PUBLISHED="pushed"
if chart_oci_lookup "${PROD_REF}" "${TAG}" >/dev/null; then
  mkdir -p "${PROMOTE_TEMP}/published" "${PROMOTE_TEMP}/packaged"
  if ! helm pull "${PROD_REF}" --version "${TAG}" --untar --untardir "${PROMOTE_TEMP}/published" >/dev/null 2>&1; then
    refuse "${PROD_REF}:${TAG} exists but could not be pulled for comparison." \
      "\`${PROD_REF}\` version \`${TAG}\` already exists and could not be pulled to compare, so it is not overwritten."
  fi
  tar -xzf "${PACKAGE}" -C "${PROMOTE_TEMP}/packaged"
  if [[ "$(tree_digest "${PROMOTE_TEMP}/published/${CHART_NAME}")" != "$(tree_digest "${PROMOTE_TEMP}/packaged/${CHART_NAME}")" ]]; then
    refuse "${PROD_REF}:${TAG} already holds a different chart." \
      "\`${PROD_REF}\` version \`${TAG}\` already holds a chart that differs from candidate \`${CANDIDATE_VERSION}\`. A published release is never overwritten: bump the version."
  fi
  echo "${CHART_NAME}:${TAG} is already published with this content; skipping the push."
  PUBLISHED="already published with the same content (re-run)"
else
  RESULT=$?
  [[ "${RESULT}" -eq 1 ]] || exit "${RESULT}"
  if ! helm push "${PACKAGE}" "oci://${CHART_REGISTRY}/${PROD_REPOSITORY}" >/dev/null 2>&1; then
    echo "::error title=Chart promote::The production repository refused ${PACKAGE}."
    {
      echo "### ⎈ Helm Chart Package Info"
      echo ""
      echo "❌ \`oci://${CHART_REGISTRY}/${PROD_REPOSITORY}\` refused \`${PACKAGE}\`. The candidate \`${CANDIDATE_VERSION}\` is unchanged. Check chart credentials, repository permissions and registry connectivity."
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
    exit 1
  fi
  echo "Published ${CHART_NAME}:${TAG}."
fi

{
  echo "### ⎈ Helm Chart Package Info"
  echo "- **📦 Name:** \`${CHART_NAME}\`"
  echo "- **🏷️ Version:** \`${TAG}\`"
  echo "- **🌐 Registry:** \`oci://${CHART_REGISTRY}/${PROD_REPOSITORY}\`"
  echo "- **🔗 Promoted from:** \`${CANDIDATE_VERSION}\`"
  echo "- **📤 Push:** ${PUBLISHED}"
} > "${CHART_INFO_FILE_NAME}"
cat "${CHART_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
