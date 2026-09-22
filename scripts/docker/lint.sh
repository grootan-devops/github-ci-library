#!/usr/bin/env bash
# hadolint with the organisation's baseline ignore set.
# Port of the GitLab `Docker:Lint` job.
# Env: DOCKERFILE (default Dockerfile), HADOLINT_IGNORE (comma-separated extra rules).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/docker/hadolint-ignores.sh
source "${SCRIPT_DIR}/hadolint-ignores.sh"

: "${DOCKERFILE:=Dockerfile}"
: "${HADOLINT_IGNORE:=}"
DEFAULT_HADOLINT="${HADOLINT_DEFAULT_IGNORE}"

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
    echo "\`${DOCKERFILE}\`${HADOLINT_IGNORE:+, also ignoring \`${HADOLINT_IGNORE}\`}"
    echo ""
    if [[ "${RESULT}" -eq 0 ]]; then
      echo "✅ No findings."
    elif [[ -z "${FINDINGS}" ]]; then
      echo "❌ hadolint exited ${RESULT} without printing anything. Check that \`${DOCKERFILE}\` is a parseable Dockerfile."
    else
      echo "❌ hadolint reported findings:"
      echo ""
      echo '```'
      # GITHUB_STEP_SUMMARY has a 1MB budget.
      echo "${FINDINGS}" | tail -n 50
      echo '```'
    fi
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi

exit "${RESULT}"
