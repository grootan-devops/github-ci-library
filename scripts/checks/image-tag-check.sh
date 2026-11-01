#!/usr/bin/env bash
# Guard: the release image tag must not already exist in any production repository.
#
# Needs a job prepared by scripts/registry/auth.sh: the destinations and credentials
# come from the registry settings it exported.
#
# Env:
#   IMAGE_TAG                  image tag being guarded
set -euo pipefail

: "${IMAGE_TAG:?IMAGE_TAG is required}"

if [[ ! "${IMAGE_TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::notice::Image tag '${IMAGE_TAG}' is a candidate build. Skipping the collision check."
  exit 0
fi

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"
TARGETS=$(registry_targets image) || exit 1

TAKEN=()
FREE=()
while IFS=$'\t' read -r HOST STABLE _; do
  TARGET="${HOST}/${STABLE}:${IMAGE_TAG}"
  if registry_exists "${TARGET}"; then
    TAKEN+=("${TARGET}")
  else
    RESULT=$?
    if [[ "${RESULT}" -ne 1 ]]; then
      {
        echo "### 🐳 Image tag"
        echo ""
        echo "❌ \`${HOST}\` could not be asked about \`${TARGET}\`, so \`${IMAGE_TAG}\` cannot be confirmed available. Check the registry credentials (\`REGISTRY_CONFIG\` or \`IMAGE_REGISTRY_USERNAME\` / \`IMAGE_REGISTRY_PASSWORD\`) and that the caller passes \`secrets: inherit\`."
        echo ""
      } >> "${GITHUB_STEP_SUMMARY}"
      exit 1
    fi
    FREE+=("${TARGET}")
  fi
done <<<"${TARGETS}"

if [[ "${#TAKEN[@]}" -gt 0 ]]; then
  echo "::error title=Image::${TAKEN[*]} already exists. Bump the application version."
  {
    echo "### 🐳 Image tag"
    echo ""
    for TARGET in "${TAKEN[@]}"; do
      echo "- ❌ \`${TARGET}\` is already taken by a published image."
    done
    echo ""
    echo "Bump the application version."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

echo "Nothing is published at ${FREE[*]} yet; the release may claim it."
{
  echo "### 🐳 Image tag"
  echo ""
  for TARGET in "${FREE[@]}"; do
    echo "- ✅ Nothing is published at \`${TARGET}\` — free to publish."
  done
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
