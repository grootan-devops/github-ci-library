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
hadolint "${HADOLINT_ARGS[@]}" --disable-ignore-pragma "${DOCKERFILE}"
