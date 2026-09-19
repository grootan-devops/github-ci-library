#!/usr/bin/env bash
# hadolint with the organisation's baseline ignore set.
#
# Port of the GitLab `Docker:Lint` job. The default ignores cover rules that a
# packaging-only Dockerfile legitimately trips (pinned versions come from the
# base image, not from the package manager invocation).
#
# Optional environment:
#   DOCKERFILE        default Dockerfile
#   HADOLINT_IGNORE   comma-separated extra rules, e.g. "DL3059,SC2086"
set -euo pipefail

: "${DOCKERFILE:=Dockerfile}"
: "${HADOLINT_IGNORE:=}"
DEFAULT_HADOLINT="DL3008,DL3013,DL3016,DL3018,DL3028,DL3033,DL3037,DL3041,DL3062"

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "::error title=Docker lint::${DOCKERFILE} not found."
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 🐳 Dockerfile lint"
      echo ""
      echo "❌ \`${DOCKERFILE}\` does not exist in \`$(pwd)\`. Add it, or point \`vars.DOCKERFILE\` at the right path."
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

if [[ -n "${HADOLINT_IGNORE}" ]]; then
  FULL_HADOLINT_IGNORE="${DEFAULT_HADOLINT},${HADOLINT_IGNORE}"
else
  FULL_HADOLINT_IGNORE="${DEFAULT_HADOLINT}"
fi

HADOLINT_ARGS=()
IFS=',' read -r -a IGNORES <<< "${FULL_HADOLINT_IGNORE}"
for RULE in "${IGNORES[@]}"; do
  RULE="$(xargs <<<"${RULE}")"
  if [[ -n "${RULE}" ]]; then
    HADOLINT_ARGS+=(--ignore "${RULE}")
  fi
done

echo "hadolint ${HADOLINT_ARGS[*]} --disable-ignore-pragma ${DOCKERFILE}"

# Capture rather than stream, so the findings can go to the job summary as well
# as the log. Every other check in the library reports into the summary; the
# Dockerfile lint should not be the one that makes you open the raw log.
set +e
FINDINGS="$(hadolint "${HADOLINT_ARGS[@]}" --disable-ignore-pragma "${DOCKERFILE}" 2>&1)"
RESULT=$?
set -e

if [[ -n "${FINDINGS}" ]]; then
  echo "${FINDINGS}"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 🐳 Dockerfile lint"
    echo ""
    echo "\`${DOCKERFILE}\`, ignoring: \`${FULL_HADOLINT_IGNORE}\`"
    echo ""
    if [[ "${RESULT}" -eq 0 ]]; then
      echo "✅ No findings."
    elif [[ -z "${FINDINGS}" ]]; then
      # An empty fenced block is a dead end; hadolint that exits without a word
      # has usually failed to parse the file rather than found something.
      echo "❌ hadolint exited ${RESULT} without printing anything. Check that \`${DOCKERFILE}\` is a parseable Dockerfile."
    else
      echo "❌ hadolint reported findings:"
      echo ""
      echo '```'
      # Cap it: a summary has a 1MB budget and a wall of findings helps nobody.
      echo "${FINDINGS}" | tail -n 50
      echo '```'
    fi
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi

exit "${RESULT}"
