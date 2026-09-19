#!/usr/bin/env bash
# Guard: the release git tag must not already exist on the remote.
set -euo pipefail

: "${TAG:?TAG is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

AUTH_HEADER="$(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 -w0)"
if ! REMOTE_TAGS="$(git -c http.extraheader="AUTHORIZATION: basic ${AUTH_HEADER}" \
  ls-remote --tags --refs "https://github.com/${GITHUB_REPOSITORY}.git" 2>&1)"; then
  echo "::error title=Git tag::Could not list remote tags. Refusing to report a tag as available without checking."
  echo "${REMOTE_TAGS}" >&2
  {
    echo "### 🏷️ Git tag"
    echo ""
    echo "❌ Could not list the remote tags of \`${GITHUB_REPOSITORY}\`, so \`${TAG}\` cannot be confirmed available. git reported:"
    echo ""
    echo '```'
    tail -n 20 <<< "${REMOTE_TAGS}"
    echo '```'
    echo ""
    echo "Check that the token passed as \`GH_TOKEN\` still has \`contents: read\` on this repository."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

MATCH="$(grep -E "refs/tags/v?${TAG//./\\.}$" <<< "${REMOTE_TAGS}" || true)"
if [[ -n "${MATCH}" ]]; then
  EXISTING_SHA="$(awk '{print $1}' <<< "${MATCH}" | head -n1)"
  if [[ "${EXISTING_SHA}" == "${GITHUB_SHA}" ]]; then
    echo "::notice::Git tag '${TAG}' already points at this commit. Treating this as a re-run of its own release."
    { echo "### 🏷️ Git tag"; echo; echo "✅ \`${TAG}\` already points at this commit — re-run of its own release."; echo; } >> "${GITHUB_STEP_SUMMARY}"
    exit 0
  fi
  echo "::error title=Git tag::Tag '${TAG}' already exists, pointing at ${EXISTING_SHA}. Bump the version in your chart or manifest."
  { echo "### 🏷️ Git tag"; echo; echo "❌ \`${TAG}\` is taken by \`${EXISTING_SHA:0:7}\`. Bump the version."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

echo "No git tag '${TAG}' exists yet; the release may create it."
{ echo "### 🏷️ Git tag"; echo; echo "✅ No git tag \`${TAG}\` yet — free to create."; echo; } >> "${GITHUB_STEP_SUMMARY}"
