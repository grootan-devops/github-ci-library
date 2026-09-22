#!/usr/bin/env bash
# Guard: scan the git history for committed secrets with betterleaks.
#
# On a pull request only the commits the branch introduces are scanned, so a
# long-lived repository does not re-read its whole history on every push. That
# narrowing is only safe when the range actually resolves: a shallow checkout,
# a force-push or a rebased head can leave the base or the head commit out of
# this clone, and a range that resolves to no commits would report a clean
# scan while having looked at nothing. Every unresolvable case therefore falls
# back to the full history and warns, never to an empty scan.
#
# Exit codes: betterleaks' own, unchanged -- 0 clean, non-zero findings or a
# scanner error. This step is a security gate, so the exit code is the verdict.
#
# Env:
#   FULL_HISTORY  "true" scans the whole history even on a pull request
#   BASE_SHA      pull request base commit; empty off a pull request
#   HEAD_SHA      pull request head commit, falling back to the pushed commit
#
# Runner-provided: GITHUB_EVENT_NAME, GITHUB_WORKSPACE, GITHUB_ENV, RUNNER_TEMP.
#
# Exports SCAN_SCOPE and SCAN_COMMITS through GITHUB_ENV for the summary step.
set -euo pipefail

: "${FULL_HISTORY?FULL_HISTORY must be set}"
: "${BASE_SHA?BASE_SHA must be set}"
: "${HEAD_SHA?HEAD_SHA must be set}"

# Without safe.directory git refuses the checkout as dubiously owned and
# betterleaks scans zero bytes; it shells out to git, so pass it in the env.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="${GITHUB_WORKSPACE}"
git config --system --add safe.directory "${GITHUB_WORKSPACE}" 2>/dev/null || true
git config --global --add safe.directory "${GITHUB_WORKSPACE}" || true

# An unresolvable range falls back to the full history, never to nothing.
RANGE_ARGS=()
SCAN_SCOPE="full history"

if [[ "${GITHUB_EVENT_NAME}" == "pull_request" && "${FULL_HISTORY}" != "true" ]]; then
  if [[ -z "${BASE_SHA}" ]]; then
    echo "::warning title=Secret scan::No pull request base commit available. Scanning the full history instead."
  elif ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
    echo "::warning title=Secret scan::Base commit ${BASE_SHA} is not in this checkout. Scanning the full history instead."
  elif ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
    echo "::warning title=Secret scan::Head commit ${HEAD_SHA} is not in this checkout. Scanning the full history instead."
  elif [[ -z "$(git rev-list "${BASE_SHA}..${HEAD_SHA}" 2>/dev/null)" ]]; then
    echo "::warning title=Secret scan::Range ${BASE_SHA}..${HEAD_SHA} resolves to no commits. Scanning the full history instead."
  else
    SCAN_SCOPE="pull request range ${BASE_SHA}..${HEAD_SHA}"
    RANGE_ARGS=(--log-opts "${BASE_SHA}..${HEAD_SHA}")
  fi
fi

echo "Scanning ${SCAN_SCOPE}"
echo "SCAN_SCOPE=${SCAN_SCOPE}" >> "${GITHUB_ENV}"

if [[ ${#RANGE_ARGS[@]} -gt 0 ]]; then
  COMMIT_COUNT="$(git rev-list --count "${BASE_SHA}..${HEAD_SHA}")"
else
  COMMIT_COUNT="$(git rev-list --count HEAD)"
fi
echo "SCAN_COMMITS=${COMMIT_COUNT}" >> "${GITHUB_ENV}"

betterleaks git . "${RANGE_ARGS[@]}" \
  --redact --verbose --no-banner --no-color --platform github --ignore-gitleaks-allow \
  2>&1 | tee "${RUNNER_TEMP}/betterleaks.log"
exit "${PIPESTATUS[0]}"
