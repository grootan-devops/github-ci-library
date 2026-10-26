#!/usr/bin/env bash
# Guard: the release image tag must not already exist in the production repository.
#
# With vars.PROJECT_REGISTRY_NAME the release is copied to every repository
# IMAGE_REPOSITORY lists, so a tag already taken in any of them would be
# overwritten there: every one is checked. The primary keeps its optional
# login (anonymous when it has no credentials); every other registry must log
# in, so a missing credential cannot pass for "the tag is free".
#
# Env:
#   IMAGE_REGISTRY, IMAGE_REGISTRY_USERNAME, IMAGE_REGISTRY_PASSWORD, or
#   PROJECT_REGISTRY_NAME and REGISTRY_CONFIG
#                              the registries and their credentials -- see
#                              scripts/registry/lib.sh
#   IMAGE_REPOSITORY           production image repository: the path in
#                              IMAGE_REGISTRY, or with a group the full
#                              <registry>/<path> repositories
#   IMAGE_TAG                  image tag being guarded
set -euo pipefail

: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${IMAGE_REPOSITORY:?IMAGE_REPOSITORY is required}"

if [[ ! "${IMAGE_TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::notice::Image tag '${IMAGE_TAG}' is a candidate build. Skipping the collision check."
  exit 0
fi

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"
registry_resolve image "${IMAGE_REPOSITORY}" || exit 1

TAKEN=()
UNCHECKED=()
FREE=()
for I in "${!REGISTRY_HOSTS[@]}"; do
  LABEL="${REGISTRY_HOSTS[${I}]}/${REGISTRY_REPOS[${I}]}"
  LOGIN_ARGS=()
  if [[ ${I} -eq 0 ]]; then
    LOGIN_ARGS=(--optional)
  fi
  if ! registry_login "${LOGIN_ARGS[@]}" crane "${I}"; then
    echo "::error title=Image::Could not authenticate to ${LABEL}."
    UNCHECKED+=("${LABEL}")
    continue
  fi
  TARGET="${REGISTRY_HOSTS[${I}]}/${REGISTRY_REPOS[${I}]}:${IMAGE_TAG}"
  if crane manifest "${TARGET}" >/dev/null 2>&1; then
    echo "::error title=Image::'${TARGET}' already exists in the production repository. Bump the application version."
    TAKEN+=("${TARGET}")
  else
    echo "Nothing is published at '${TARGET}' yet; the release may claim it."
    FREE+=("${TARGET}")
  fi
done

{
  echo "### 🐳 Image tag"
  echo ""
  for TARGET in "${TAKEN[@]}"; do
    echo "❌ \`${TARGET}\` is already taken by a published image. Bump the application version."
    echo ""
  done
  for LABEL in "${UNCHECKED[@]}"; do
    echo "❌ Could not log in to \`${LABEL}\`, so \`${IMAGE_TAG}\` cannot be confirmed available there. Check its credentials -- \`secrets.IMAGE_REGISTRY_USERNAME\` / \`secrets.IMAGE_REGISTRY_PASSWORD\`, or its registry in the \`REGISTRY_CONFIG\` group -- and that the caller passes \`secrets: inherit\`."
    echo ""
  done
  for TARGET in "${FREE[@]}"; do
    echo "✅ Nothing is published at \`${TARGET}\` — free to publish."
    echo ""
  done
} >> "${GITHUB_STEP_SUMMARY}"

if [[ ${#TAKEN[@]} -gt 0 || ${#UNCHECKED[@]} -gt 0 ]]; then
  exit 1
fi
