#!/usr/bin/env bash
# Read the library's own release version from the VERSION file.
#
# Everything downstream in this repository's CI hangs off this one string: the
# release guards, the git tag, and the refs callers pin to. A missing, empty or
# malformed VERSION would otherwise surface much later as a tag nobody can
# reproduce, so the run stops here instead and says which of the two faults it
# hit.
#
# Exit codes: 0 resolved (TAG written to GITHUB_OUTPUT), 1 VERSION is missing,
# empty, or not MAJOR.MINOR.PATCH.
#
# Env:
#   GITHUB_OUTPUT         GitHub-provided; receives TAG
#   GITHUB_STEP_SUMMARY   GitHub-provided; receives the version summary
set -euo pipefail

if [[ ! -s VERSION ]]; then
  echo "::error title=Version::VERSION file is missing or empty."
  # shellcheck disable=SC2016 # backticks are markdown, not command substitution
  printf '### 🏷️ Library version\n\n❌ `VERSION` is missing or empty, so nothing downstream has a tag to work with. It must hold a bare semantic version, e.g. `2.4.0`.\n\n' >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

TAG="$(tr -d '[:space:]' < VERSION)"
if [[ ! "${TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error title=Version::'${TAG}' is not a semantic version."
  {
    echo "### 🏷️ Library version"
    echo ""
    echo "❌ \`VERSION\` holds \`${TAG}\`, which is not \`MAJOR.MINOR.PATCH\`. The release guards and the git tag both derive from it, so the run stops here."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

echo "TAG=${TAG}" >> "${GITHUB_OUTPUT}"
{
  echo "### 🏷️ Library version"
  echo ""
  echo "Releasing as \`${TAG}\` on merge."
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
