#!/usr/bin/env bash
# Append a caller-supplied `KEY=VALUE` block to the job environment.
#
# Five workflows carried a byte-identical copy of this loop, nine times over,
# because it is short enough to look not worth extracting and just long enough
# to get wrong. The parsing is deliberate on three points:
#
#   - `IFS='='` with two `read` targets splits on the FIRST `=` only, so a value
#     containing `=` (a base64 blob, a connection string) survives intact.
#   - The key is trimmed of surrounding whitespace so an indented block works,
#     but the value is not: a trailing space may be significant.
#   - A blank line or a `#` comment is skipped rather than exported as an empty
#     key, which GITHUB_ENV would otherwise reject for the whole step.
#
# Env:
#   BUILD_ENV  newline-separated KEY=VALUE pairs (default: empty)
set -euo pipefail

: "${BUILD_ENV:=}"

if [[ -z "${BUILD_ENV}" ]]; then
  exit 0
fi

while IFS='=' read -r KEY VAL; do
  KEY="${KEY#"${KEY%%[![:space:]]*}"}"
  KEY="${KEY%"${KEY##*[![:space:]]}"}"
  if [[ -z "${KEY}" || "${KEY}" =~ ^# ]]; then
    continue
  fi
  printf '%s=%s\n' "${KEY}" "${VAL}" >> "${GITHUB_ENV}"
done <<< "${BUILD_ENV}"
