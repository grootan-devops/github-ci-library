#!/usr/bin/env bash
# Copy an image from the primary repository to every other repository.
#
# Every repository must hold the bytes that were scanned, under one digest. So
# nothing is rebuilt or re-pushed from a build here: crane copies the primary's
# manifest, by digest, to each other repository, and the copy's digest is
# checked against the source. Each registry is logged in to once, with its own
# credentials, so repositories on one registry share that login. Every
# repository is tried before the step fails, so one run names every one that
# needs attention, and a re-run simply copies again.
#
# Env:
#   REPOSITORY            with vars.PROJECT_REGISTRY_NAME, the full <registry>/<path>
#                         repositories, the primary first; otherwise the one path in
#                         vars.IMAGE_REGISTRY, and there is nothing to copy
#   TAG                   tag to copy from the primary and to write everywhere else
#   ALIASES               "true" also tags latest, MAJOR and MINOR, as a release does
#                         (default: false)
#   IMAGE_INFO_FILE_NAME  markdown summary the copies are appended to
#                         (default: IMAGE_INFO.md)
#   PROJECT_REGISTRY_NAME, REGISTRY_CONFIG, IMAGE_REGISTRY -- see lib.sh
#   GITHUB_STEP_SUMMARY   GitHub-provided; appended to
#
# Exit codes: 0 copied, or there is only one repository; 1 a registry refused
# the login, the copy or an alias tag, or a copy's digest differs; 2 the
# configuration is invalid.
set -euo pipefail

: "${REPOSITORY:?REPOSITORY must be set}"
: "${TAG:?TAG must be set}"
: "${ALIASES:=false}"
: "${IMAGE_INFO_FILE_NAME:=IMAGE_INFO.md}"

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS=0
registry_resolve image "${REPOSITORY}" || STATUS=$?
if [[ ${STATUS} -ne 0 ]]; then
  exit "${STATUS}"
fi
if [[ ${#REGISTRY_HOSTS[@]} -eq 1 ]]; then
  echo "One repository is configured; there is nothing to copy."
  exit 0
fi

SOURCE="${REGISTRY_HOSTS[0]}/${REGISTRY_REPOS[0]}"
registry_login crane 0 || exit 1
if ! DIGEST="$(crane digest "${SOURCE}:${TAG}" 2>&1)" || [[ ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error title=Image copy::${SOURCE}:${TAG} cannot be read from the primary registry, so nothing was copied: ${DIGEST}"
  exit 1
fi

ALIAS_TAGS=()
if [[ "${ALIASES}" == "true" ]]; then
  ALIAS_TAGS+=(latest)
  MAJOR="$(grep -Eo '^[0-9]+' <<< "${TAG}" || true)"
  MINOR="$(grep -Eo '^[0-9]+\.[0-9]+' <<< "${TAG}" || true)"
  if [[ -n "${MAJOR}" ]]; then
    ALIAS_TAGS+=("${MAJOR}")
  fi
  if [[ -n "${MINOR}" ]]; then
    ALIAS_TAGS+=("${MINOR}")
  fi
fi

ROWS=()
FAILED=()
for ((I = 1; I < ${#REGISTRY_HOSTS[@]}; I++)); do
  TARGET="${REGISTRY_HOSTS[${I}]}/${REGISTRY_REPOS[${I}]}"
  if ! registry_login crane "${I}"; then
    FAILED+=("${TARGET}")
    continue
  fi
  echo "Copying ${SOURCE}@${DIGEST} to ${TARGET}:${TAG}..."
  if ! OUTPUT="$(crane copy "${SOURCE}@${DIGEST}" "${TARGET}:${TAG}" 2>&1)"; then
    tail -n 20 <<< "${OUTPUT}" >&2
    echo "::error title=Image copy::${TARGET}:${TAG} was refused."
    FAILED+=("${TARGET}")
    continue
  fi
  COPIED="$(crane digest "${TARGET}:${TAG}" 2>/dev/null || true)"
  if [[ "${COPIED}" != "${DIGEST}" ]]; then
    echo "::error title=Image copy::${TARGET}:${TAG} resolves to '${COPIED}', not ${DIGEST}."
    FAILED+=("${TARGET}")
    continue
  fi
  ALIAS_FAILED=""
  for ALIAS in "${ALIAS_TAGS[@]}"; do
    if ! crane tag "${TARGET}:${TAG}" "${ALIAS}" >/dev/null 2>&1; then
      echo "::error title=Image copy::${TARGET}:${ALIAS} could not be tagged."
      ALIAS_FAILED="true"
    fi
  done
  if [[ -n "${ALIAS_FAILED}" ]]; then
    FAILED+=("${TARGET}")
    continue
  fi
  echo "✅ ${TARGET}:${TAG} is ${DIGEST}."
  ROWS+=("| \`${TARGET}:${TAG}\` | \`${DIGEST}\` |")
done

{
  echo "#### 🔁 Other repositories"
  echo ""
  echo "| Reference | Digest |"
  echo "|---|---|"
  for ROW in "${ROWS[@]}"; do
    echo "${ROW}"
  done
  for TARGET in "${FAILED[@]}"; do
    echo "| ❌ \`${TARGET}\` | not copied; the log names the reason |"
  done
  if [[ ${#ALIAS_TAGS[@]} -gt 0 && ${#ROWS[@]} -gt 0 ]]; then
    echo ""
    echo "Each copy is also tagged \`${ALIAS_TAGS[*]}\`."
  fi
  echo ""
} | tee -a "${IMAGE_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  JOINED="$(printf '%s, ' "${FAILED[@]}")"
  echo "::error title=Image copy::${SOURCE}:${TAG} was not copied to: ${JOINED%, }. Every other repository was tried; re-run once they are fixed."
  exit 1
fi
