#!/usr/bin/env bash
# Merge a run's downloaded artifacts into one release body and one asset directory.
#
# Several Terraform roots scanned in one run each bring their own
# `terraform-<root>_trivy_scan_report.*` and `TF_CVE-<root>.md` (scan.yml names
# them), so every root lands in the bundle and in the notes.
#
# The release is assembled from whatever the candidate run happened to produce,
# and any piece of it may legitimately be absent: a repository with no chart
# produces no CHART_INFO.md, a run with the CVE scan skipped produces no
# IMAGE_CVE.md. Every input below is therefore optional and a missing one only
# shrinks the output. The case worth warning about is all of them being missing
# at once, which almost always means `upstream-run-id` did not resolve -- the
# release would then be published with an empty body and no assets, and nobody
# notices until someone goes looking for the scan reports weeks later.
#
# Runs with the collect job's working directory, so every path below is relative
# to the project root, exactly as the inline block was.
#
# Exit codes: 0 on success; non-zero only if a mkdir, cp or tar genuinely fails.
#
# Env:
#   TAG                                       release tag, used only for the minimal
#                                             fallback body. The `?` guard fires on an
#                                             UNSET variable only: an empty tag rendered
#                                             as "Release " inline and still does.
#   ADDITIONAL_RELEASE_ARTIFACT               space-separated extra files or directories
#                                             to attach; directories are tarred
#                                             (default: empty)
#   RELEASE_CHANGELOG_FILE_NAME               changelog produced upstream
#   RELEASE_MIGRATION_FILE_NAME               migration guide produced upstream
#   CONSOLIDATED_README_FILE_NAME             output: concatenated info and CVE readmes
#   CONSOLIDATED_RELEASE_CHANGELOG_FILE_NAME  output: the release body
#   TRIVY_SCAN_REPORT_FILE_NAME               output: tarball holding the per-scan reports
#   TEST_REPORT_DIR                           test report directory, tarred when present
#
# Runner-provided: none.
set -euo pipefail

: "${TAG?TAG must be set}"
: "${ADDITIONAL_RELEASE_ARTIFACT:=}"
: "${RELEASE_CHANGELOG_FILE_NAME:?RELEASE_CHANGELOG_FILE_NAME must be set}"
: "${RELEASE_MIGRATION_FILE_NAME:?RELEASE_MIGRATION_FILE_NAME must be set}"
: "${CONSOLIDATED_README_FILE_NAME:?CONSOLIDATED_README_FILE_NAME must be set}"
: "${CONSOLIDATED_RELEASE_CHANGELOG_FILE_NAME:?CONSOLIDATED_RELEASE_CHANGELOG_FILE_NAME must be set}"
: "${TRIVY_SCAN_REPORT_FILE_NAME:?TRIVY_SCAN_REPORT_FILE_NAME must be set}"
: "${TEST_REPORT_DIR:?TEST_REPORT_DIR must be set}"

if [[ -d _artifacts ]]; then
  cp -a _artifacts/. . 2>/dev/null || true
fi

mkdir -p _release_assets

IMAGE_README=IMAGE_README.md
CHART_README=CHART_README.md
TF_README=TF_README.md

for FILE in IMAGE_INFO.md IMAGE_CVE.md; do
  if [[ -f "${FILE}" ]]; then
    cat "${FILE}" >> "${IMAGE_README}"
  fi
done
for FILE in CHART_INFO.md CHART_CVE.md; do
  if [[ -f "${FILE}" ]]; then
    cat "${FILE}" >> "${CHART_README}"
  fi
done
# A project whose Terraform roots scan as a matrix gets one TF_CVE-<root>.md
# per root (scan.yml names them), each titled with its root, in root order
# after the repository root's own TF_CVE.md.
shopt -s nullglob
TF_SUMMARIES=( TF_CVE.md TF_CVE-*.md )
shopt -u nullglob
for FILE in "${TF_SUMMARIES[@]}"; do
  if [[ -f "${FILE}" ]]; then
    cat "${FILE}" >> "${TF_README}"
  fi
done

: > "${CONSOLIDATED_README_FILE_NAME}"
for FILE in "${IMAGE_README}" "${CHART_README}" "${TF_README}" LICENSE_CVE.md SBOM_CVE.md; do
  if [[ -f "${FILE}" ]]; then
    cat "${FILE}" >> "${CONSOLIDATED_README_FILE_NAME}"
  fi
done

: > "${CONSOLIDATED_RELEASE_CHANGELOG_FILE_NAME}"
for FILE in "${RELEASE_CHANGELOG_FILE_NAME}" "${RELEASE_MIGRATION_FILE_NAME}" "${CONSOLIDATED_README_FILE_NAME}"; do
  if [[ -f "${FILE}" && -s "${FILE}" ]]; then
    {
      printf '\n'
      cat "${FILE}"
      printf '\n'
    } >> "${CONSOLIDATED_RELEASE_CHANGELOG_FILE_NAME}"
  fi
done

if [[ ! -s "${CONSOLIDATED_RELEASE_CHANGELOG_FILE_NAME}" ]]; then
  echo "::warning title=Release::No changelog, migration guide or scan report was available. The release notes will be minimal."
  echo "Release ${TAG}" > "${CONSOLIDATED_RELEASE_CHANGELOG_FILE_NAME}"
fi

# Deterministic archive: the same files always give the same bytes (sorted
# names, fixed mtime and owner, no gzip timestamp), so a re-run's asset has the
# digest of the one already published and publish.sh can leave it alone.
pack() {
  local OUT="$1"
  shift
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - "$@" | gzip -n > "${OUT}"
}

stage() {
  if [[ -f "${1}" ]]; then
    cp "${1}" _release_assets/
    echo "  + ${1}"
  fi
}

shopt -s nullglob
TRIVY_REPORTS=( ./*_trivy_scan_report.* )
shopt -u nullglob
if [[ ${#TRIVY_REPORTS[@]} -gt 0 ]]; then
  pack "${TRIVY_SCAN_REPORT_FILE_NAME}" "${TRIVY_REPORTS[@]}"
  stage "${TRIVY_SCAN_REPORT_FILE_NAME}"
fi

stage installed_pkgs.txt
stage sbom.cdx.json
stage "${RELEASE_CHANGELOG_FILE_NAME}"

# Only the released chart package (chart.yml · promote uploads <chart>-<TAG>.tgz).
# The candidate run also brings its own <chart>-<TAG>-<run>.<n>.tgz, which is
# not what was released and is not attached.
shopt -s nullglob
for CHART_TGZ in ./*-"${TAG}".tgz; do
  cp "${CHART_TGZ}" _release_assets/
  echo "  + ${CHART_TGZ}"
done
shopt -u nullglob

if [[ -d "${TEST_REPORT_DIR}" ]]; then
  pack "${TEST_REPORT_DIR}.tar.gz" "${TEST_REPORT_DIR}"
  stage "${TEST_REPORT_DIR}.tar.gz"
fi

# Unquoted on purpose: `additional-artifacts` is a space-separated list and the
# inline block split it the same way.
# shellcheck disable=SC2086
for ITEM in ${ADDITIONAL_RELEASE_ARTIFACT}; do
  if [[ -f "${ITEM}" ]]; then
    stage "${ITEM}"
  elif [[ -d "${ITEM}" ]]; then
    TAR_FILE="$(basename "${ITEM}").tar.gz"
    pack "${TAR_FILE}" -C "$(dirname "${ITEM}")" "$(basename "${ITEM}")"
    stage "${TAR_FILE}"
  else
    echo "::warning title=Release::Additional artifact '${ITEM}' does not exist."
  fi
done

echo "Staged $(find _release_assets -type f | wc -l | tr -d ' ') release assets."
