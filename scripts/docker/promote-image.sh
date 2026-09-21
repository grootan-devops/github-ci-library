#!/usr/bin/env bash
# Retag the scanned candidate image as the production release.
#
# A release must ship the exact image the scan looked at, so nothing is
# rebuilt here: crane copies the candidate manifest from the dev repository to
# the production tag. Which candidate that is has to be resolved rather than
# assumed -- the caller may name it exactly, or the release may have been cut
# from the highest `<tag>-<run>.<n>` candidate, or from a plain `<tag>`. A named
# candidate that is not in the registry is a failure, never a reason to search:
# the search cannot tell one build's candidate from another's. When none of
# those exist the promotion is refused instead of falling back to a
# rebuild, because an unscanned image reaching the production tag is the one
# outcome this job exists to prevent.
#
# `crane mutate` rewrites the version label, so the released digest is not the
# scanned candidate's digest. Both are reported, and the candidate is left in
# place in the dev repository so a failed promotion can simply be re-run.
#
# Exit codes: 0 promoted, 1 no candidate matched or the registry refused the
# retag. Both failures leave the production tag unchanged.
#
# Env:
#   REGISTRY_USERNAME  registry credential for crane
#   REGISTRY_PASSWORD  registry credential for crane
#   TAG                production tag to release as
#   CANDIDATE_TAG      exact candidate tag to promote; empty means search, and
#                      a tag that is set but absent fails the promotion
#   DEV_REPOSITORY     candidate repository, without the registry host
#   PROD_REPOSITORY    production repository, without the registry host
#
# Runner-provided: REGISTRY_HOST and IMAGE_INFO_FILE_NAME (workflow-level env),
# GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${REGISTRY_USERNAME?REGISTRY_USERNAME must be set}"
: "${REGISTRY_PASSWORD?REGISTRY_PASSWORD must be set}"
: "${TAG?TAG must be set}"
: "${CANDIDATE_TAG?CANDIDATE_TAG must be set}"
: "${DEV_REPOSITORY?DEV_REPOSITORY must be set}"
: "${PROD_REPOSITORY?PROD_REPOSITORY must be set}"
: "${REGISTRY_HOST?REGISTRY_HOST must be set}"
: "${IMAGE_INFO_FILE_NAME?IMAGE_INFO_FILE_NAME must be set}"

crane auth login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password "${REGISTRY_PASSWORD}"

DEV_IMAGE="${REGISTRY_HOST}/${DEV_REPOSITORY}"
PROD_IMAGE="${REGISTRY_HOST}/${PROD_REPOSITORY}"
SOURCE=""

if [[ -n "${CANDIDATE_TAG}" ]]; then
  # The caller named the exact candidate this release was cut from, so a miss
  # here is a broken run, not an ambiguous one. Searching on would promote some
  # other build -- an open pull request's candidate sorts higher just as easily
  # -- and the `scan-result` the caller passed does not attest to that image.
  # Leaving SOURCE empty drops through to the refusal below.
  if crane manifest "${DEV_IMAGE}:${CANDIDATE_TAG}" >/dev/null 2>&1; then
    SOURCE="${DEV_IMAGE}:${CANDIDATE_TAG}"
  fi
else
  # Match only the `<tag>-<run>.<attempt-or-pr>` shape that
  # scripts/init/resolve-version.sh mints for candidates. A bare `-` prefix also
  # swept up unrelated tags such as `<tag>-rc1`, any of which could sort last and
  # be released.
  CANDIDATE_TAGS="$(crane ls "${DEV_IMAGE}" 2>/dev/null | grep -E "^${TAG//./\\.}-[0-9]+\.[0-9]+$" | sort -V || true)"
  RC_TAG=""
  MATCH_COUNT=0
  if [[ -n "${CANDIDATE_TAGS}" ]]; then
    RC_TAG="$(tail -n1 <<<"${CANDIDATE_TAGS}")"
    MATCH_COUNT="$(grep -c '' <<<"${CANDIDATE_TAGS}")"
  fi
  if [[ -n "${RC_TAG}" ]] && crane manifest "${DEV_IMAGE}:${RC_TAG}" >/dev/null 2>&1; then
    SOURCE="${DEV_IMAGE}:${RC_TAG}"
    if [[ "${MATCH_COUNT}" -gt 1 ]]; then
      # Every build of this release version -- including open pull requests'
      # -- publishes the same tag shape to this repository, so the
      # highest-sorting one is a guess. Make the guess visible.
      echo "::warning title=Image promote::No candidate-tag was passed, so ${RC_TAG} was chosen as the highest-sorting of ${MATCH_COUNT} candidates in ${DEV_IMAGE} for ${TAG}. Open pull requests publish this same tag shape; pass 'candidate-tag' to name the scanned image exactly."
      echo "Candidates considered:"
      echo "${CANDIDATE_TAGS}"
    fi
  elif crane manifest "${DEV_IMAGE}:${TAG}" >/dev/null 2>&1; then
    SOURCE="${DEV_IMAGE}:${TAG}"
  fi
fi

if [[ -z "${SOURCE}" ]]; then
  echo "::error title=Image promote::No candidate image found in ${DEV_IMAGE} for ${TAG}. Nothing was scanned that could be promoted."
  {
    echo "### 🐳 Container Image"
    echo ""
    echo "❌ \`${TAG}\` was not promoted: no candidate in \`${DEV_IMAGE}\` matched \`${CANDIDATE_TAG:-${TAG}-*}\`. The production tag is unchanged."
    echo ""
    echo "Tags that do exist in the candidate repository:"
    echo ""
    echo '```'
    crane ls "${DEV_IMAGE}" 2>&1 | tail -n 20 || echo "(the candidate repository could not be listed either)"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

SOURCE_DIGEST="$(crane digest "${SOURCE}")"
echo "📦 Promoting ${SOURCE} (${SOURCE_DIGEST}) to ${PROD_IMAGE}:${TAG}"

if ! MUTATE_OUTPUT="$(crane mutate "${SOURCE}" --label "org.opencontainers.image.version=${TAG}" --tag "${PROD_IMAGE}:${TAG}" 2>&1)"; then
  echo "${MUTATE_OUTPUT}" >&2
  echo "::error title=Image promote::${PROD_IMAGE}:${TAG} was refused by the registry."
  {
    echo "### 🐳 Container Image"
    echo ""
    echo "❌ \`${PROD_IMAGE}:${TAG}\` was refused. The scanned candidate \`${SOURCE}\` (\`${SOURCE_DIGEST}\`) is unchanged in the dev repository, so a re-run can promote it once this is fixed. crane reported:"
    echo ""
    echo '```'
    tail -n 30 <<< "${MUTATE_OUTPUT}"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
echo "${MUTATE_OUTPUT}"

crane tag "${PROD_IMAGE}:${TAG}" latest
MAJOR="$(grep -Eo '^[0-9]+' <<<"${TAG}" || true)"
MINOR="$(grep -Eo '^[0-9]+\.[0-9]+' <<<"${TAG}" || true)"
if [[ -n "${MAJOR}" ]]; then
  crane tag "${PROD_IMAGE}:${TAG}" "${MAJOR}"
fi
if [[ -n "${MINOR}" ]]; then
  crane tag "${PROD_IMAGE}:${TAG}" "${MINOR}"
fi

PROD_DIGEST="$(crane digest "${PROD_IMAGE}:${TAG}")"
{
  echo "### 🐳 Container Image"
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  echo "| **Promoted from** | \`${SOURCE}\` |"
  echo "| **Released as** | \`${PROD_IMAGE}:${TAG}\` |"
  echo "| **Aliases** | \`latest\`${MAJOR:+, \`${MAJOR}\`}${MINOR:+, \`${MINOR}\`} |"
  echo "| **Digest** | \`${PROD_DIGEST}\` |"
  # `crane mutate` rewrites the version label, so the scanned
  # candidate's digest differs from the released one by design.
  echo "| **Scanned candidate digest** | \`${SOURCE_DIGEST}\` |"
  echo ""
} > "${IMAGE_INFO_FILE_NAME}"
cat "${IMAGE_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
