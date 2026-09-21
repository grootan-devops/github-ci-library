#!/usr/bin/env bash
# Append the "🐳 Container Image" failure section to the job step summary.
#
# When the build fails, BuildKit's own error is buried in the log of a
# composite action whose output cannot be read back from a later step. Without
# this section the summary is simply empty, and the first thing anyone notices
# is that the scan or the promotion had no candidate to work on. Restating the
# Dockerfile, context, stage and the resolved build arguments here is usually
# enough to tell a wrong-path mistake from a genuine compile failure without
# opening the log at all.
#
# Exit codes: 0 always. The step that calls this runs under `if: failure()`,
# so the job is already failing; a non-zero exit here would only replace the
# real error with this script's.
#
# Env:
#   REPO           image repository the build targeted, without the registry
#   TAG            tag the build would have published
#   BUILD_CONTEXT  build context passed to docker/build-push-action
#   BUILD_FILE     path of the Dockerfile that was built
#   BUILD_TARGET   Dockerfile stage; empty means the final stage
#   BUILD_ARGS     newline-separated build arguments the step resolved to
#   PUSH_OUTCOME   outcome of the build-and-push step
#
# Runner-provided: REGISTRY_HOST (workflow-level env), GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${REPO?REPO must be set}"
: "${TAG?TAG must be set}"
: "${BUILD_CONTEXT?BUILD_CONTEXT must be set}"
: "${BUILD_FILE?BUILD_FILE must be set}"
: "${BUILD_TARGET?BUILD_TARGET must be set}"
: "${BUILD_ARGS?BUILD_ARGS must be set}"
: "${PUSH_OUTCOME?PUSH_OUTCOME must be set}"
: "${REGISTRY_HOST?REGISTRY_HOST must be set}"

{
  echo "### 🐳 Container Image"
  echo ""
  echo "❌ \`${REGISTRY_HOST}/${REPO}:${TAG}\` was not built. No candidate exists for the scan or the promotion to consume."
  echo ""
  echo "| Input | Value |"
  echo "|---|---|"
  echo "| **Dockerfile** | \`${BUILD_FILE}\` |"
  echo "| **Context** | \`${BUILD_CONTEXT}\` |"
  echo "| **Stage** | \`${BUILD_TARGET:-(final)}\` |"
  echo "| **Build & push step** | \`${PUSH_OUTCOME}\` |"
  echo ""
  if [[ -n "${BUILD_ARGS}" ]]; then
    echo "<details><summary>Build arguments the base images resolved to</summary>"
    echo ""
    echo '```'
    echo "${BUILD_ARGS}"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
  fi
  echo "BuildKit's own error is in the **Build & Push Image** step of the log; a composite action's output cannot be read back from here."
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
