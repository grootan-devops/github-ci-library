#!/usr/bin/env bash
# Reports which stage of the image build failed, with that stage's log.
#
# Runs under `if: failure()`, so every value it reads may be the empty string
# a step that never ran reports. The guards below therefore use
# `${VAR?...}` (unset only) rather than `${VAR:?...}` (unset or empty): an
# abort here would replace the diagnostic with no output at all, which is the
# opposite of what the step is for.
#
# Env:
#   REGISTRY_HOST   registry the image would have been published to
#   REPO, TAG       the image that was not published
#   BASE_REPO, BASE_TAG   resolved base image, or empty if that step failed
#   BASE_OUTCOME, BUILD_OUTCOME, PUSH_OUTCOME   step outcomes
set -euo pipefail

: "${REPO?REPO must be set}"
: "${TAG?TAG must be set}"
: "${REGISTRY_HOST:=}"
: "${BASE_REPO:=}"
: "${BASE_TAG:=}"
: "${BASE_OUTCOME:=}"
: "${BUILD_OUTCOME:=}"
: "${PUSH_OUTCOME:=}"

set -euo pipefail
# Name the stage from the step that actually failed. A step that never
# ran reports an empty outcome, so a two-way split on the build's
# outcome blamed the registry push for every earlier failure, then
# tailed a push log that was never written.
LOG=""
if [[ "${BUILD_OUTCOME}" == "failure" ]]; then
  STAGE="the buildah assembly"
  LOG="${RUNNER_TEMP}/buildah.log"
elif [[ "${PUSH_OUTCOME}" == "failure" ]]; then
  STAGE="the push to the registry"
  LOG="${RUNNER_TEMP}/podman-push.log"
elif [[ "${BASE_OUTCOME}" == "failure" ]]; then
  STAGE="resolving the base image"
else
  STAGE="a step outside the build and the push"
fi
{
  echo "### 🐳 Container Image"
  echo ""
  echo "❌ \`${REGISTRY_HOST}/${REPO}:${TAG}\` was not published: ${STAGE} failed. It was being assembled from \`${BASE_REPO:-unresolved}:${BASE_TAG:-unresolved}\`. No candidate exists for the scan or the promotion to consume."
  echo ""
  if [[ -n "${LOG}" ]]; then
    echo '```'
    tail -n 50 "${LOG}" 2>/dev/null || echo "(the failing step ran before any output was captured)"
    echo '```'
    echo ""
  fi
} >> "${GITHUB_STEP_SUMMARY}"
