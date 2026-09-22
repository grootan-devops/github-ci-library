#!/usr/bin/env bash
# Emit the guard matrix for check.yml: one entry per guard that applies here.
#
# A guard whose subject does not exist in this repository -- no changelog, no
# chart, no image -- must never enter the run graph. Emitting it anyway and
# letting it skip leaves a permanently grey job, and a grey job reads exactly
# like a guard somebody quietly disabled. So the matrix is built from what is
# actually on disk and in the inputs, and only the applicable guards appear.
#
# The JSON printed here becomes `strategy.matrix.include` for the guard job. A
# malformed document does not fail loudly, it produces no guards at all, so
# every entry is appended with jq and the array stays valid by construction
# rather than by string concatenation.
#
# Exit codes: 0 matrix emitted; non-zero only on an unexpected jq or shell
# error, which fails discovery and, through it, the whole check.
#
# Env:
#   PROJECT_PATH          project root the subject files are looked for in (default: .)
#   CHANGELOG_FILE_NAME   changelog path, relative to PROJECT_PATH (default: ./CHANGELOG.md)
#   MIGRATION_FILE_NAME   migration guide path, relative to PROJECT_PATH (default: ./MIGRATION.md)
#   CHECK_MIGRATION       "true" runs the migration guard when the file exists (default: true)
#   CHECK_LIBRARY_PINNING "true" runs the reusable-workflow pinning guard (default: true)
#   CHART_NAME            chart name; empty disables both chart guards (default: empty)
#   IMAGE_TAG             image tag to guard; empty disables the image guard (default: empty)
#   IMAGE_REPOSITORY      production image repository; empty disables the image guard (default: empty)
#   GITHUB_OUTPUT         runner-provided; receives `include=<json>`
set -euo pipefail

: "${PROJECT_PATH:=.}"
: "${CHANGELOG_FILE_NAME:=./CHANGELOG.md}"
: "${MIGRATION_FILE_NAME:=./MIGRATION.md}"
: "${CHECK_MIGRATION:=true}"
: "${CHECK_LIBRARY_PINNING:=true}"
: "${CHART_NAME:=}"
: "${IMAGE_TAG:=}"
: "${IMAGE_REPOSITORY:=}"

cd "${PROJECT_PATH}"

TARGETS='[{"name":"Git Tag Unused","subject":"tag","script":"tag-check.sh"}]'

if [[ "${CHECK_LIBRARY_PINNING}" == "true" ]]; then
  TARGETS="$(jq -c '. + [{"name":"Library Pinning","subject":"library-pin","script":"library-pin-check.sh"}]' <<< "${TARGETS}")"
fi

if [[ -f "${CHANGELOG_FILE_NAME}" ]]; then
  TARGETS="$(jq -c '. + [{"name":"Changelog","subject":"changelog","script":"changelog-check.sh"}]' <<< "${TARGETS}")"
else
  echo "::warning title=Changelog::No ${CHANGELOG_FILE_NAME} in this repository — the changelog guard does not apply."
fi

if [[ "${CHECK_MIGRATION}" == "true" && -f "${MIGRATION_FILE_NAME}" ]]; then
  TARGETS="$(jq -c '. + [{"name":"Migration Guide","subject":"migration","script":"migration-check.sh"}]' <<< "${TARGETS}")"
fi

if [[ -n "${CHART_NAME}" ]]; then
  TARGETS="$(jq -c '. + [{"name":"Chart Version Unused","subject":"chart-version","script":"chart-version-check.sh"},{"name":"Chart Dependencies","subject":"chart-dependency","script":"chart-dependency-check.sh"}]' <<< "${TARGETS}")"
fi

if [[ -n "${IMAGE_TAG}" && -n "${IMAGE_REPOSITORY}" ]]; then
  TARGETS="$(jq -c '. + [{"name":"Image Tag Unused","subject":"image-tag","script":"image-tag-check.sh"}]' <<< "${TARGETS}")"
fi

echo "include=${TARGETS}" >> "${GITHUB_OUTPUT}"
