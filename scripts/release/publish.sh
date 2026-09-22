#!/usr/bin/env bash
# Create or update the GitHub release for TAG and attach the staged assets.
#
# Two things here are load-bearing and easy to undo by accident. First, the
# release body is truncated at 124000 characters: GitHub's release API hard-fails
# with HTTP 422 at 125000, and a consolidated changelog that swept up several
# scan reports goes over that regularly, so the body is cut and the full text is
# attached as an asset instead of losing the release. `iconv -c` runs over the cut
# because `head -c` counts bytes and can slice a multi-byte character in half,
# which the API also rejects. Second, every `gh` call passes an explicit
# `--repo`: this job deliberately has no checkout of the consumer repository, so
# `gh` has no git remote to infer the target from.
#
# Re-running the workflow for a tag that already has a release updates it rather
# than failing, because a release is often re-cut after a notes-only fix.
#
# Exit codes: 0 on success, otherwise `gh`'s own exit code, so a caller that
# inspects the step outcome sees what gh reported.
#
# Env:
#   TAG                          release tag
#   DRAFT                        "true" creates the release as a draft
#   PRERELEASE                   "true" marks the release as a prerelease
#   GH_TOKEN                     token gh authenticates with
#   RELEASE_CHANGELOG_FILE_NAME  basename of the raw changelog, which is
#                                deliberately excluded from the asset list -- its
#                                content is already the release body
#
# Runner-provided: GITHUB_REPOSITORY, GITHUB_SHA, RUNNER_TEMP,
# GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${TAG:?TAG must be set}"
: "${DRAFT:=false}"
: "${PRERELEASE:=false}"
: "${RELEASE_CHANGELOG_FILE_NAME:?RELEASE_CHANGELOG_FILE_NAME must be set}"

NOTES_FILE=payload/CONSOLIDATED_RELEASE_CHANGELOG.md
if [[ ! -s "${NOTES_FILE}" ]]; then
  echo "::warning title=Release::No consolidated release notes were collected. Publishing '${TAG}' with a minimal body."
  mkdir -p payload
  echo "Release ${TAG}" > "${NOTES_FILE}"
fi

NOTES_LIMIT=124000
NOTES_CHARS="$(wc -m < "${NOTES_FILE}" | tr -d ' ')"
if [[ "${NOTES_CHARS}" -gt "${NOTES_LIMIT}" ]]; then
  echo "::warning title=Release::Release notes are ${NOTES_CHARS} characters, over GitHub's ${NOTES_LIMIT} limit. The body is truncated; the full notes stay attached as an asset."
  TRUNCATED="${RUNNER_TEMP}/release-notes-truncated.md"
  head -c "${NOTES_LIMIT}" "${NOTES_FILE}" | iconv -f utf-8 -t utf-8 -c > "${TRUNCATED}"
  {
    echo ""
    echo "---"
    echo ""
    echo "> These notes were truncated at ${NOTES_LIMIT} characters, which is GitHub's"
    echo "> limit for a release body. The complete text is attached to this release as"
    echo "> \`$(basename "${NOTES_FILE}")\`."
  } >> "${TRUNCATED}"
  mkdir -p payload/_release_assets
  cp -f "${NOTES_FILE}" "payload/_release_assets/$(basename "${NOTES_FILE}")" 2>/dev/null || true
  NOTES_FILE="${TRUNCATED}"
fi

ARGS=(--repo "${GITHUB_REPOSITORY}"
      --title "Release ${TAG}"
      --notes-file "${NOTES_FILE}"
      --target "${GITHUB_SHA}")
if [[ "${DRAFT}" == "true" ]]; then
  ARGS+=(--draft)
fi
if [[ "${PRERELEASE}" == "true" ]]; then
  ARGS+=(--prerelease)
fi

shopt -s nullglob
ASSETS=()
for ASSET in payload/_release_assets/*; do
  if [[ "$(basename "${ASSET}")" == "$(basename "${RELEASE_CHANGELOG_FILE_NAME}")" ]]; then
    continue
  fi
  ASSETS+=("${ASSET}")
done
shopt -u nullglob

# Edit the release, then upload assets only when there are any. Exit status is
# the edit's code when the edit fails, 0 when there is nothing to upload and
# otherwise the upload's code -- the same contract as the `edit && { empty ||
# upload }` chain this replaces. Runs with errexit off, so the edit failing
# reaches the explicit check rather than killing the subshell.
edit_existing_release() {
  local EDIT_RESULT
  gh release edit "${TAG}" "${ARGS[@]}"
  EDIT_RESULT=$?
  if [[ "${EDIT_RESULT}" -ne 0 ]]; then
    return "${EDIT_RESULT}"
  fi
  if [[ ${#ASSETS[@]} -eq 0 ]]; then
    return 0
  fi
  gh release upload "${TAG}" "${ASSETS[@]}" --repo "${GITHUB_REPOSITORY}" --clobber
}

# Re-running an existing release updates it rather than failing.
set +e
if gh release view "${TAG}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
  echo "::notice title=Release::'${TAG}' already exists. Updating it."
  GH_OUTPUT="$(edit_existing_release 2>&1)"
else
  GH_OUTPUT="$(gh release create "${TAG}" "${ARGS[@]}" "${ASSETS[@]}" 2>&1)"
fi
GH_RESULT=$?
set -e

if [[ -n "${GH_OUTPUT}" ]]; then
  echo "${GH_OUTPUT}"
fi
if [[ "${GH_RESULT}" -ne 0 ]]; then
  echo "::error title=Release::gh refused to publish '${TAG}'."
  {
    echo "## 🚀 Release ${TAG}"
    echo ""
    echo "❌ The release was not published. \`gh\` reported:"
    echo ""
    echo '```'
    tail -n 30 <<< "${GH_OUTPUT}"
    echo '```'
    echo ""
    echo "The git tag may already have been created by the release guards; check before re-running."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit "${GH_RESULT}"
fi
