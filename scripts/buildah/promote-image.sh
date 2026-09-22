#!/usr/bin/env bash
# Retags an already-scanned candidate image as the production release.
#
# A release must ship the bytes the scan looked at, so this never rebuilds: it
# finds the candidate in the dev repository and retags it. The search is
# widest-first on purpose -- the exact candidate tag the caller passed, then
# the newest `<version>-*` release candidate, then the bare version -- because
# a pipeline that cut an RC and a pipeline that tagged directly both have to
# resolve to something, and promoting the wrong tag is worse than not promoting
# at all. When nothing matches, the production tag is left untouched and the
# run summary lists the tags that do exist, which is almost always enough to
# see which pipeline never published its candidate.
#
# `crane mutate` rewrites the version label, so the released digest differs
# from the scanned candidate's by design; both are recorded in the summary.
#
# Env:
#   REGISTRY_HOST         registry holding both repositories
#   REGISTRY_USERNAME     registry credentials
#   REGISTRY_PASSWORD     registry credentials
#   DEV_REPOSITORY        candidate repository to promote from
#   PROD_REPOSITORY       production repository to promote into
#   TAG                   production tag to release as
#   CANDIDATE_TAG         exact candidate tag to prefer (default: empty, which
#                         falls back to the newest "<TAG>-*" then "<TAG>")
#   IMAGE_INFO_FILE_NAME  markdown summary written into the working directory
#
# Exit codes: 0 promoted, 1 no candidate found or the registry refused the
# retag.
set -euo pipefail

# Unset-only guards (`?`, not `:?`): the block these came from ran under
# `set -u`, where an empty value was not fatal at this point.
: "${REGISTRY_HOST?REGISTRY_HOST must be set}"
: "${REGISTRY_USERNAME?REGISTRY_USERNAME must be set}"
: "${REGISTRY_PASSWORD?REGISTRY_PASSWORD must be set}"
: "${DEV_REPOSITORY?DEV_REPOSITORY must be set}"
: "${PROD_REPOSITORY?PROD_REPOSITORY must be set}"
: "${TAG?TAG must be set}"
: "${IMAGE_INFO_FILE_NAME?IMAGE_INFO_FILE_NAME must be set}"
# An empty CANDIDATE_TAG is meaningful -- it selects the fallback search.
: "${CANDIDATE_TAG:=}"

crane auth login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password "${REGISTRY_PASSWORD}"

DEV_IMAGE="${REGISTRY_HOST}/${DEV_REPOSITORY}"
PROD_IMAGE="${REGISTRY_HOST}/${PROD_REPOSITORY}"
SOURCE=""

if [[ -n "${CANDIDATE_TAG}" ]] && crane manifest "${DEV_IMAGE}:${CANDIDATE_TAG}" >/dev/null 2>&1; then
  SOURCE="${DEV_IMAGE}:${CANDIDATE_TAG}"
else
  RC_TAG="$(crane ls "${DEV_IMAGE}" 2>/dev/null | grep -E "^${TAG//./\\.}-" | sort -V | tail -n1 || true)"
  if [[ -n "${RC_TAG}" ]] && crane manifest "${DEV_IMAGE}:${RC_TAG}" >/dev/null 2>&1; then
    SOURCE="${DEV_IMAGE}:${RC_TAG}"
  elif crane manifest "${DEV_IMAGE}:${TAG}" >/dev/null 2>&1; then
    SOURCE="${DEV_IMAGE}:${TAG}"
  fi
fi

if [[ -z "${SOURCE}" ]]; then
  echo "::error title=Image promote::No candidate image found in ${DEV_IMAGE} for ${TAG}."
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
  echo "| **Digest** | \`${PROD_DIGEST}\` |"
  # `crane mutate` rewrites the version label, so the scanned
  # candidate's digest differs from the released one by design.
  echo "| **Scanned candidate digest** | \`${SOURCE_DIGEST}\` |"
  echo ""
} > "${IMAGE_INFO_FILE_NAME}"
cat "${IMAGE_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
