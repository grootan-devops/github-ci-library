#!/usr/bin/env bash
# Push the packaged chart to the OCI registry and record what was published.
#
# The package arrives as a downloaded artifact, so the first thing that can go
# wrong is a name mismatch: the package job derives the filename from
# chart-name and chart-version, and a caller that changes either between jobs
# gets an empty directory and a confusing helm error. Listing what actually
# arrived turns that into a one-glance diagnosis.
#
# When the caller provides a distinct development repository, a stable push is
# also mirrored there so consumers pinned to that channel still resolve the
# version. Docker Hub intentionally provides the same repository for both
# channels, so the mirror branch is skipped and the version suffix is the
# only candidate/release distinction.
#
# Env:
#   CHART_NAME            chart name
#   CHART_VERSION         version being pushed; names the .tgz
#   CHART_REPOSITORY      repository to push to, under REGISTRY_HOST
#   CHART_DEV_REPOSITORY  candidate repository to mirror into (same as the
#                         production repository on Docker Hub)
#   REGISTRY_HOST         OCI registry host
#   CHART_INFO_FILE_NAME  file the published details are written to
#                         (default: CHART_INFO.md)
#   GITHUB_STEP_SUMMARY   GitHub-provided; appended to
#
# Exit codes: 0 pushed; 1 the package is missing from the artifact, or the
# registry refused it. A failed dev mirror does not change the exit code.
set -euo pipefail

: "${CHART_NAME:?CHART_NAME must be set}"
: "${CHART_VERSION:?CHART_VERSION must be set}"
: "${CHART_REPOSITORY:?CHART_REPOSITORY must be set}"
: "${CHART_DEV_REPOSITORY:=}"
: "${REGISTRY_HOST:=}"
: "${CHART_INFO_FILE_NAME:=CHART_INFO.md}"

PACKAGE="${CHART_NAME}-${CHART_VERSION}.tgz"
if [[ ! -f "${PACKAGE}" ]]; then
  echo "::error title=Chart push::Package '${PACKAGE}' not found."
  {
    echo "### ⎈ Helm Chart Package Info"
    echo ""
    echo "❌ \`${PACKAGE}\` is not in the downloaded \`chart-package\` artifact, so there is nothing to push. The package job names its output from \`chart-name\` and \`chart-version\`; these are what arrived:"
    echo ""
    echo '```'
    ls -1
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

TARGET="oci://${REGISTRY_HOST}/${CHART_REPOSITORY}"
echo "Pushing ${PACKAGE} to ${TARGET}..."
if ! PUSH_OUTPUT="$(helm push "${PACKAGE}" "${TARGET}" 2>&1)"; then
  echo "${PUSH_OUTPUT}" >&2
  echo "::error title=Chart push::${TARGET} refused ${PACKAGE}."
  {
    echo "### ⎈ Helm Chart Package Info"
    echo ""
    echo "❌ \`${TARGET}\` refused \`${PACKAGE}\`. Helm reported:"
    echo ""
    echo '```'
    tail -n 30 <<< "${PUSH_OUTPUT}"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "${PUSH_OUTPUT}"

# Mirror a stable push into the dev channel so consumers pinned there
# still resolve it. A convenience: a failed mirror warns, not fails.
MIRROR_STATE=""
if [[ -n "${CHART_DEV_REPOSITORY}" && "${CHART_REPOSITORY}" != "${CHART_DEV_REPOSITORY}" ]]; then
  DEV_TARGET="oci://${REGISTRY_HOST}/${CHART_DEV_REPOSITORY}"
  echo "Mirroring ${PACKAGE} to the dev channel at ${DEV_TARGET}..."
  if helm push "${PACKAGE}" "${DEV_TARGET}"; then
    echo "✅ Mirrored ${PACKAGE} to ${DEV_TARGET}."
    MIRROR_STATE="\`${DEV_TARGET}\`"
  else
    echo "::warning title=Chart push::Optional dev mirror push failed for '${PACKAGE}'. The chart is published at ${TARGET}."
    MIRROR_STATE="⚠️ failed — consumers pinned to \`${CHART_DEV_REPOSITORY}\` will not resolve \`${CHART_VERSION}\`"
  fi
fi

{
  echo "### ⎈ Helm Chart Package Info"
  echo "- **📦 Name:** \`${CHART_NAME}\`"
  echo "- **🏷️ Version:** \`${CHART_VERSION}\`"
  echo "- **🌐 Registry:** \`${TARGET}\`"
  if [[ -n "${MIRROR_STATE}" ]]; then
    echo "- **🔁 Dev mirror:** ${MIRROR_STATE}"
  fi
} > "${CHART_INFO_FILE_NAME}"
cat "${CHART_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
