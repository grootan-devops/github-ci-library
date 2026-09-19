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
  crane auth login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password "${REGISTRY_PASSWORD}"
fi

TARGET="${REGISTRY_HOST}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
if crane manifest "${TARGET}" >/dev/null 2>&1; then
  echo "::error title=Image::'${TARGET}' already exists in the production repository. Bump the application version."
  { echo "### 🐳 Image tag"; echo; echo "❌ \`${TARGET}\` is already published. Bump the application version."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

echo "Container image tag '${IMAGE_TAG}' is available."
{ echo "### 🐳 Image tag"; echo; echo "✅ \`${TARGET}\` is available."; echo; } >> "${GITHUB_STEP_SUMMARY}"
