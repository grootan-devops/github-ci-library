#!/usr/bin/env bash
# Release preflight: every artifact this release promotes must have its exact
# candidate before anything is written to production.
#
# docker.yml · promote runs before chart.yml · promote, and each only checks its
# own candidate. A missing chart candidate was therefore found only after the
# image had been released and `latest` moved: a half-published version. init.yml
# runs this before either promote job, so a release with any candidate unnamed or
# missing fails here and nothing is written.
#
# A project that publishes no image and no chart (IGNORE_DOCKER and IGNORE_CHART
# both "true") has nothing to check and releases with notes only, as before.
#
# Exit codes: 0 every enabled candidate exists; 1 a candidate is unnamed or not in
# its registry; 2 the chart registry could not be queried.
#
# Env:
#   IGNORE_DOCKER, IGNORE_CHART      "true" when the artifact is not published
#   CANDIDATE_IMAGE_TAG              exact candidate image tag from provenance.sh
#   CANDIDATE_CHART_VERSION          exact candidate chart version from provenance.sh
#   IMAGE_REGISTRY, IMAGE_DEV_REPOSITORY
#   IMAGE_REGISTRY_USERNAME, IMAGE_REGISTRY_PASSWORD   (optional for a public registry)
#   CHART_REGISTRY, CHART_DEV_REPOSITORY, CHART_NAME
#   CHART_REGISTRY_USERNAME, CHART_REGISTRY_PASSWORD
#   TAG                              the release version, for messages
#   GITHUB_STEP_SUMMARY              runner-provided
set -euo pipefail

: "${IGNORE_DOCKER:=true}"
: "${IGNORE_CHART:=true}"
: "${CANDIDATE_IMAGE_TAG:=}"
: "${CANDIDATE_CHART_VERSION:=}"
: "${IMAGE_REGISTRY:=}"
: "${IMAGE_DEV_REPOSITORY:=}"
: "${IMAGE_REGISTRY_USERNAME:=}"
: "${IMAGE_REGISTRY_PASSWORD:=}"
: "${CHART_REGISTRY:=}"
: "${CHART_DEV_REPOSITORY:=}"
: "${CHART_NAME:=}"
: "${TAG:=}"

FOUND=()
PROBLEMS=()
UNNAMED="no candidate was named: init.yml names it from the merged pull request's successful run, so a direct push or a pull request whose run did not succeed has none"

if [[ "${IGNORE_DOCKER}" != "true" ]]; then
  if [[ -z "${CANDIDATE_IMAGE_TAG}" ]]; then
    PROBLEMS+=("Image: ${UNNAMED}.")
  else
    if [[ -n "${IMAGE_REGISTRY_USERNAME}" && -n "${IMAGE_REGISTRY_PASSWORD}" ]]; then
      crane auth login "${IMAGE_REGISTRY}" --username "${IMAGE_REGISTRY_USERNAME}" --password "${IMAGE_REGISTRY_PASSWORD}" >/dev/null 2>&1 || true
    fi
    IMAGE_REF="${IMAGE_REGISTRY}/${IMAGE_DEV_REPOSITORY}:${CANDIDATE_IMAGE_TAG}"
    if crane manifest "${IMAGE_REF}" >/dev/null 2>&1; then
      FOUND+=("image \`${IMAGE_REF}\`")
    else
      PROBLEMS+=("Image: the candidate \`${IMAGE_REF}\` is not in the registry, or the registry could not be read.")
    fi
  fi
fi

if [[ "${IGNORE_CHART}" != "true" ]]; then
  if [[ -z "${CANDIDATE_CHART_VERSION}" ]]; then
    PROBLEMS+=("Chart: ${UNNAMED}.")
  else
    # shellcheck source=scripts/chart/registry.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../chart/registry.sh"
    chart_registry_login
    CHART_REF="oci://${CHART_REGISTRY}/${CHART_DEV_REPOSITORY}/${CHART_NAME}"
    if chart_oci_lookup "${CHART_REF}" "${CANDIDATE_CHART_VERSION}" >/dev/null; then
      FOUND+=("chart \`${CHART_REF}\` version \`${CANDIDATE_CHART_VERSION}\`")
    else
      RESULT=$?
      [[ "${RESULT}" -eq 1 ]] || exit "${RESULT}"
      PROBLEMS+=("Chart: the candidate \`${CHART_REF}\` version \`${CANDIDATE_CHART_VERSION}\` does not exist. Check that the pull request published its candidate chart (\`publish-candidate\`).")
    fi
  fi
fi

if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
  for PROBLEM in "${PROBLEMS[@]}"; do
    echo "::error title=Release preflight::${PROBLEM}"
  done
  {
    echo "### 🛫 Release preflight"
    echo ""
    echo "❌ \`${TAG}\` is not released: a candidate it would promote is missing, so nothing was written to production."
    echo ""
    printf -- '- %s\n' "${PROBLEMS[@]}"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

if [[ ${#FOUND[@]} -gt 0 ]]; then
  echo "Every candidate this release promotes exists: ${FOUND[*]}."
  {
    echo "### 🛫 Release preflight"
    echo ""
    echo "✅ Every candidate \`${TAG}\` promotes exists:"
    echo ""
    printf -- '- %s\n' "${FOUND[@]}"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
else
  echo "This release promotes no image or chart; nothing to check."
fi
