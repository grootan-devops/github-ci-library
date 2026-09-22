#!/usr/bin/env bash
# Append the "📦 <stack> build" section to the job step summary.
#
# golang-build, java-build, node-build and python-build all close their build
# job with the same three-way summary: the tail of the build log when the
# compile failed, an inventory of what was produced when it worked, and a
# warning when it worked but produced nothing. That last case is the one worth
# the code -- upload-artifact is configured to ignore an empty match, so a build
# that quietly writes no output uploads an empty artifact and the mistake only
# surfaces much later, in the job that tries to consume it. Only the labels and
# the way output is measured differ between the four stacks, so they share this
# script rather than four near-copies that drift apart one wording fix at a time.
#
# Runs with the build job's working directory, so every glob and directory below
# is relative to the project root, exactly as the inline blocks were.
#
# Exit codes: 0 always, including when COMPILE_OUTCOME says the build never ran.
# The step that calls this runs under `if: always()`, so a non-zero exit here
# would fail an otherwise green job. The `?` guards below deliberately fire on
# an UNSET variable only, never on an empty one: empty is a value a caller can
# legitimately supply, and the inline blocks rendered it without complaint.
#
# Env:
#   STACK_LABEL      stack name in the heading, e.g. "Go"
#   BUILD_COMMAND    the build command, quoted back into the summary
#   COMPILE_OUTCOME  outcome of the build step; anything other than success or
#                    failure means an earlier step failed and the build never
#                    ran, and nothing is written at all
#   ARTIFACT_NAME    name of the upload-artifact entry, e.g. "go-binaries"
#   ARTIFACT_DIR     directory the build writes into, no trailing slash
#   SUMMARY_MODE     "files" tables every produced file with its size (default),
#                    "directory" reports ARTIFACT_DIR's total size and file count
#   ARTIFACT_GLOB    files mode only: space-separated globs relative to the
#                    working directory, e.g. "target/*.jar target/*.war"
#   ARTIFACT_COLUMN  files mode only: first column heading (default: "Artifact")
#   TOOL_LABEL       subject of the failure sentence (default: "It"), e.g. "Maven"
#   EMPTY_PHRASE     what a successful-but-empty build did not write
#                    (default: "nothing"), e.g. "no JAR or WAR"
#
# Runner-provided: RUNNER_TEMP (holds build.log), GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${STACK_LABEL?STACK_LABEL must be set}"
: "${BUILD_COMMAND?BUILD_COMMAND must be set}"
: "${COMPILE_OUTCOME?COMPILE_OUTCOME must be set}"
: "${ARTIFACT_NAME?ARTIFACT_NAME must be set}"
: "${ARTIFACT_DIR?ARTIFACT_DIR must be set}"
: "${SUMMARY_MODE:=files}"
: "${ARTIFACT_COLUMN:=Artifact}"
: "${TOOL_LABEL:=It}"
: "${EMPTY_PHRASE:=nothing}"

# Early return: anything other than success or failure means an earlier step
# failed and the build never ran, so there is no build to summarise.
if [[ ! "${COMPILE_OUTCOME}" =~ ^(success|failure)$ ]]; then
  exit 0
fi

ARTIFACT_PATTERNS=()
FILE_COUNT=0

case "${SUMMARY_MODE}" in
  files)
    : "${ARTIFACT_GLOB:?ARTIFACT_GLOB must be set when SUMMARY_MODE is files}"
    # Split on whitespace only. The patterns must reach compgen and the listing
    # loop unexpanded, so they cannot be expanded here.
    read -r -a ARTIFACT_PATTERNS <<< "${ARTIFACT_GLOB}"
    ;;
  directory)
    FILE_COUNT="$(find "${ARTIFACT_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')" || FILE_COUNT=0
    ;;
  *)
    echo "SUMMARY_MODE must be 'files' or 'directory', got '${SUMMARY_MODE}'" >&2
    exit 1
    ;;
esac

# True when at least one pattern matches something on disk.
any_artifact_matches() {
  local PATTERN
  for PATTERN in "${ARTIFACT_PATTERNS[@]}"; do
    if compgen -G "${PATTERN}" > /dev/null; then
      return 0
    fi
  done
  return 1
}

list_artifacts() {
  local PATTERN F
  echo "| ${ARTIFACT_COLUMN} | Size |"
  echo "|---|---|"
  for PATTERN in "${ARTIFACT_PATTERNS[@]}"; do
    # Unquoted on purpose: this is where the glob expands, pattern by pattern, in
    # the order given. A pattern that matches nothing survives literally and the
    # -f test below drops it.
    # shellcheck disable=SC2086
    for F in ${PATTERN}; do
      if [[ ! -f "${F}" ]]; then
        continue
      fi
      echo "| \`$(basename "${F}")\` | $(du -h "${F}" | cut -f1) |"
    done
  done
}

warn_empty_artifact() {
  echo "⚠️ \`${BUILD_COMMAND}\` succeeded but wrote ${EMPTY_PHRASE} to \`${ARTIFACT_DIR}/\`, so the \`${ARTIFACT_NAME}\` artifact will be empty."
}

{
  echo "### 📦 ${STACK_LABEL} build"
  echo ""
  if [[ "${COMPILE_OUTCOME}" != "success" ]]; then
    echo "❌ \`${BUILD_COMMAND}\` failed. ${TOOL_LABEL} reported:"
    echo ""
    echo '```'
    tail -n 50 "${RUNNER_TEMP}/build.log" 2>/dev/null || echo "(no output was captured)"
    echo '```'
  elif [[ "${SUMMARY_MODE}" == "directory" ]]; then
    if [[ "${FILE_COUNT}" -gt 0 ]]; then
      echo "✅ Output \`${ARTIFACT_DIR}/\` — $(du -sh "${ARTIFACT_DIR}" | cut -f1) across ${FILE_COUNT} files."
    else
      warn_empty_artifact
    fi
  elif any_artifact_matches; then
    list_artifacts
  else
    warn_empty_artifact
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
