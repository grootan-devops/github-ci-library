#!/usr/bin/env bash
# markdownlint-cli2 with the organisation's baseline rule exclusions.
# Port of the GitLab `.MD:Lint` job template.
# Env: LINT_MD_FILES (globs, default every tracked *.md), MD_LINT_IGNORE_RULE (extra rules).
set -euo pipefail

: "${LINT_MD_FILES:=}"
: "${MD_LINT_IGNORE_RULE:=}"

MARKDOWNLINT_CONFIG_DIR="$(mktemp -d)"
MARKDOWNLINT_CONFIG="${MARKDOWNLINT_CONFIG_DIR}/.markdownlint-cli2.yaml"
trap 'rm -f "${MARKDOWNLINT_CONFIG}"; rmdir "${MARKDOWNLINT_CONFIG_DIR}"' EXIT

{
  echo "config:"
  # These four conflict with keepachangelog.com formatting.
  echo "  MD013: false"
  echo "  MD024: false"
  echo "  MD007: false"
  echo "  MD047: false"
  echo "  MD060: false"
  for RULE in ${MD_LINT_IGNORE_RULE}; do
    echo "  ${RULE}: false"
  done
} > "${MARKDOWNLINT_CONFIG}"

if [[ -z "${LINT_MD_FILES}" ]]; then
  # Canonical license texts are intentionally verbatim and are not Markdown.
  mapfile -t MD_TARGETS < <(git ls-files '*.md' ':!LICENSE.md')
else
  # shellcheck disable=SC2206 # deliberate word splitting: a space-separated list of globs
  MD_TARGETS=(${LINT_MD_FILES})
fi

if [[ ${#MD_TARGETS[@]} -eq 0 ]]; then
  echo "No markdown files to lint."
  exit 0
fi

echo "Linting: ${MD_TARGETS[*]}"
# shellcheck source=scripts/lint-summary.sh
source "$(dirname "${BASH_SOURCE[0]}")/lint-summary.sh"
run_linted "📝 Markdown lint" \
  npx --yes markdownlint-cli2@0.23.2 --config "${MARKDOWNLINT_CONFIG}" "${MD_TARGETS[@]}"
