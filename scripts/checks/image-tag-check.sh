#!/usr/bin/env bash
# Guard: the release image tag must not already exist in the production repository.
set -euo pipefail

: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"

if [[ ! "${IMAGE_TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::notice::Image tag '${IMAGE_TAG}' is a candidate build. Skipping the collision check."
  { echo "### 🐳 Image tag"; echo; echo "✅ \`${IMAGE_TAG}\` is a candidate build — collision check skipped."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 0
fi

if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
  # Capture crane's words: a bad credential and an unreachable registry both exit 1.
  if ! LOGIN_OUTPUT="$(crane auth login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password "${REGISTRY_PASSWORD}" 2>&1)"; then
    echo "::error title=Image::Could not authenticate to ${REGISTRY_HOST}."
    echo "${LOGIN_OUTPUT}" >&2
    {
      echo "### 🐳 Image tag"
      echo ""
      echo "❌ Could not log in to \`${REGISTRY_HOST}\` as \`${REGISTRY_USERNAME}\`, so \`${IMAGE_TAG}\` cannot be confirmed available. crane reported:"
      echo ""
      echo '```'
      tail -n 20 <<< "${LOGIN_OUTPUT}"
      echo '```'
      echo ""
      echo "Check \`secrets.IMAGE_REGISTRY_USERNAME\` / \`secrets.IMAGE_REGISTRY_PASSWORD\` and that the caller passes \`secrets: inherit\`."
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
    exit 1
  fi
fi

TARGET="${REGISTRY_HOST}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
if crane manifest "${TARGET}" >/dev/null 2>&1; then
  echo "::error title=Image::'${TARGET}' already exists in the production repository. Bump the application version."
  { echo "### 🐳 Image tag"; echo; echo "❌ \`${TARGET}\` is already taken by a published image. Bump the application version."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

echo "Nothing is published at '${TARGET}' yet; the release may claim it."
{ echo "### 🐳 Image tag"; echo; echo "✅ Nothing is published at \`${TARGET}\` — free to publish."; echo; } >> "${GITHUB_STEP_SUMMARY}"
