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
# With vars.PROJECT_REGISTRY_NAME (scripts/registry/lib.sh) the package is
# pushed to every full repository CHART_REPOSITORY lists -- the workflow has
# already logged in to the primary's registry, and every other registry is
# logged in to here, once -- and every repository is tried before the step
# fails, so one run names all that need attention.
#
# Env:
#   CHART_NAME            chart name
#   CHART_VERSION         version being pushed; names the .tgz
#   CHART_REPOSITORY      repository to push to: the path in CHART_REGISTRY,
#                         or with a group the full <registry>/<path>
#                         repositories, primary first
#   CHART_DEV_REPOSITORY  candidate repository to mirror into (same as the
#                         production repository on Docker Hub), given the
#                         same way
#   CHART_REGISTRY, or PROJECT_REGISTRY_NAME and REGISTRY_CONFIG
#                         the registries and their credentials -- see
#                         scripts/registry/lib.sh
#   CHART_INFO_FILE_NAME  file the published details are written to
#                         (default: CHART_INFO.md)
#   GITHUB_STEP_SUMMARY   GitHub-provided; appended to
#
# Exit codes: 0 pushed; 1 the package is missing from the artifact, or a
# registry refused it. A failed dev mirror does not change the exit code.
set -euo pipefail

: "${CHART_NAME:?CHART_NAME must be set}"
: "${CHART_VERSION:?CHART_VERSION must be set}"
: "${CHART_REPOSITORY:?CHART_REPOSITORY must be set}"
: "${CHART_DEV_REPOSITORY:=}"
# shellcheck source=scripts/chart/registry.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
chart_registry_targets "${CHART_REPOSITORY}" "${CHART_DEV_REPOSITORY}" || exit 1
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

INFO=()
FAILED=()
for I in "${!REGISTRY_HOSTS[@]}"; do
  HOST="${REGISTRY_HOSTS[${I}]}"
  LABEL="${HOST}/${REGISTRY_REPOS[${I}]}"
  REPOSITORY="${REGISTRY_REPOS[${I}]}"
  DEV_REPOSITORY="${REGISTRY_DEV_REPOS[${I}]-}"
  if [[ ${I} -gt 0 ]] && ! chart_registry_login "${I}"; then
    FAILED+=("${LABEL}")
    continue
  fi

  TARGET="oci://${HOST}/${REPOSITORY}"
  echo "Pushing ${PACKAGE} to ${TARGET}..."
  if ! helm push "${PACKAGE}" "${TARGET}" >/dev/null 2>&1; then
    echo "::error title=Chart push::${TARGET} refused ${PACKAGE}."
    {
      echo "### ⎈ Helm Chart Package Info"
      echo ""
      echo "❌ \`${TARGET}\` refused \`${PACKAGE}\`. Check chart credentials, repository permissions and registry connectivity."
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
    FAILED+=("${LABEL}")
    continue
  fi
  echo "Published ${PACKAGE} to ${TARGET}."
  INFO+=("- **🌐 Registry:** \`${TARGET}\`")

  # Mirror a stable push into the dev channel so consumers pinned there
  # still resolve it. A convenience: a failed mirror warns, not fails.
  if [[ -n "${DEV_REPOSITORY}" && "${REPOSITORY}" != "${DEV_REPOSITORY}" ]]; then
    DEV_TARGET="oci://${HOST}/${DEV_REPOSITORY}"
    echo "Mirroring ${PACKAGE} to the dev channel at ${DEV_TARGET}..."
    if helm push "${PACKAGE}" "${DEV_TARGET}" >/dev/null 2>&1; then
      echo "✅ Mirrored ${PACKAGE} to ${DEV_TARGET}."
      INFO+=("- **🔁 Dev mirror:** \`${DEV_TARGET}\`")
    else
      echo "::warning title=Chart push::Optional dev mirror push failed for '${PACKAGE}'. The chart is published at ${TARGET}."
      INFO+=("- **🔁 Dev mirror:** ⚠️ failed — consumers pinned to \`${DEV_REPOSITORY}\` will not resolve \`${CHART_VERSION}\`")
    fi
  fi
done

if [[ ${#INFO[@]} -gt 0 ]]; then
  {
    echo "### ⎈ Helm Chart Package Info"
    echo "- **📦 Name:** \`${CHART_NAME}\`"
    echo "- **🏷️ Version:** \`${CHART_VERSION}\`"
    printf '%s\n' "${INFO[@]}"
  } > "${CHART_INFO_FILE_NAME}"
  cat "${CHART_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  if [[ ${#REGISTRY_HOSTS[@]} -gt 1 ]]; then
    JOINED="$(printf '%s, ' "${FAILED[@]}")"
    echo "::error title=Chart push::${PACKAGE} was not published to: ${JOINED%, }. Every repository was tried; re-run once they are fixed."
  fi
  exit 1
fi
