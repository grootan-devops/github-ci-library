#!/usr/bin/env bash
# Renders the dependency-resolution step summary for every language stack.
#
# Go, Java, Python and Node each carried a structurally identical copy of this
# block, differing only in wording, the resolve command and the log file name.
# Four copies meant a fix to the cache-state wording landed in one stack and
# not the other three.
#
# The step that calls this runs under `if: always()`, so the guards below use
# `${VAR?...}` (unset only) rather than the house `${VAR:?...}` (unset or
# empty): `steps.<id>.outcome` is an EMPTY string when the step never ran, and
# aborting there would turn an otherwise-green job red. The inline blocks this
# replaced ran under `set -u`, which also tolerated empty.
#
# Env:
#   STACK_LABEL       summary heading, e.g. "🐹 Go modules"
#   OUTCOME           the resolve/download step's outcome
#   CACHE_KEY         the cache key that was looked up
#   CACHE_HIT         "true" when the cache restored
#   SUCCESS_MESSAGE   sentence shown on success, e.g. "Modules resolved."
#   RESOLVE_COMMAND   the command that ran, e.g. "go mod download"
#   TOOL_LABEL        who reported the failure, e.g. "Go", "Maven", "npm"
#   LOG_FILE          log basename under ${RUNNER_TEMP}
#   REMEDY            optional extra paragraph on failure (default: none)
set -euo pipefail

: "${STACK_LABEL?STACK_LABEL must be set}"
: "${OUTCOME?OUTCOME must be set}"
: "${CACHE_KEY?CACHE_KEY must be set}"
: "${RESOLVE_COMMAND?RESOLVE_COMMAND must be set}"
: "${TOOL_LABEL?TOOL_LABEL must be set}"
: "${LOG_FILE?LOG_FILE must be set}"
: "${SUCCESS_MESSAGE?SUCCESS_MESSAGE must be set}"
: "${CACHE_HIT:=}"
: "${REMEDY:=}"

# Anything else means an earlier step failed and the resolve never ran.
if ! [[ "${OUTCOME}" =~ ^(success|failure)$ ]]; then
  exit 0
fi

CACHE_STATE="rebuilt — no entry matched"
if [[ "${CACHE_HIT}" == "true" ]]; then
  CACHE_STATE="restored"
fi

{
  echo "### ${STACK_LABEL}"
  echo ""
  if [[ "${OUTCOME}" == "success" ]]; then
    echo "✅ ${SUCCESS_MESSAGE} Cache \`${CACHE_KEY}\`: ${CACHE_STATE}."
  else
    echo "❌ \`${RESOLVE_COMMAND}\` failed. Cache \`${CACHE_KEY}\`: ${CACHE_STATE}. ${TOOL_LABEL} reported:"
    echo ""
    echo '```'
    tail -n 50 "${RUNNER_TEMP}/${LOG_FILE}" 2>/dev/null || echo "(no output was captured)"
    echo '```'
    if [[ -n "${REMEDY}" ]]; then
      echo ""
      echo "${REMEDY}"
    fi
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
