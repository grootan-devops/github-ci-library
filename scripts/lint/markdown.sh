#!/usr/bin/env bash
# markdownlint-cli2 with the organisation's baseline rule exclusions.
# Port of the GitLab `.MD:Lint` job template.
# Env: LINT_MD_FILES (space-separated globs, default every tracked *.md).
set -euo pipefail

: "${LINT_MD_FILES:=}"

MARKDOWNLINT_CONFIG_DIR="$(mktemp -d)"
MARKDOWNLINT_CONFIG="${MARKDOWNLINT_CONFIG_DIR}/.markdownlint-cli2.yaml"
trap 'rm -f "${MARKDOWNLINT_CONFIG}"; rmdir "${MARKDOWNLINT_CONFIG_DIR}"' EXIT

{
  echo "config:"
  # These four conflict with keepachangelog.com formatting.
  echo "  MD013: false" # line-length
  echo "  MD024: false" # no-duplicate-heading
  echo "  MD007: false" # ul-indent
  echo "  MD047: false" # single-trailing-newline
} > "${MARKDOWNLINT_CONFIG}"

if [[ -z "${LINT_MD_FILES}" ]]; then
  # Canonical license texts are intentionally verbatim and are not Markdown.
  mapfile -t MD_TARGETS < <(git ls-files '*.md' ':!LICENSE.md')
else
  # Expand caller-supplied globs here so `**/*.md` reaches nested files and
  # negated patterns remain available to markdownlint-cli2.
  shopt -s globstar nullglob
  read -r -a MD_PATTERNS <<< "${LINT_MD_FILES}"
  MD_TARGETS=()
  for PATTERN in "${MD_PATTERNS[@]}"; do
    if [[ "${PATTERN}" == '!'* ]]; then
      MD_TARGETS+=("${PATTERN}")
      continue
    fi
    # shellcheck disable=SC2206 # deliberate glob expansion from the input contract
    MATCHES=( ${PATTERN} )
    if [[ ${#MATCHES[@]} -gt 0 ]]; then
      MD_TARGETS+=("${MATCHES[@]}")
    else
      MD_TARGETS+=("${PATTERN}")
    fi
  done
fi

# Keep canonical license texts out of Markdown lint even when a caller supplies
# an explicit `*.md` target. They are legally maintained verbatim, not authored
# as Markdown documentation.
FILTERED_MD_TARGETS=()
for TARGET in "${MD_TARGETS[@]}"; do
  if [[ "${TARGET}" == "LICENSE.md" || "${TARGET}" == */LICENSE.md ]]; then
    continue
  fi
  FILTERED_MD_TARGETS+=("${TARGET}")
done
MD_TARGETS=("${FILTERED_MD_TARGETS[@]}")

if [[ ${#MD_TARGETS[@]} -eq 0 ]]; then
  echo "No markdown files to lint."
  exit 0
fi

echo "Linting: ${MD_TARGETS[*]}"
# shellcheck source=scripts/lint/summary.sh
source "$(dirname "${BASH_SOURCE[0]}")/summary.sh"
run_linted "📝 Markdown lint" \
  npx --yes markdownlint-cli2@0.23.2 --config "${MARKDOWNLINT_CONFIG}" "${MD_TARGETS[@]}"
