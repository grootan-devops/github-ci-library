#!/usr/bin/env bash
# markdownlint-cli2 with the organisation's baseline rule exclusions.
#
# Port of the GitLab `.MD:Lint` job template.
#
# Optional environment:
#   LINT_MD_FILES        files/globs to lint (default: every tracked *.md)
#   MD_LINT_IGNORE_RULE  space-separated extra rules to exclude, e.g. "MD033 MD041"
set -euo pipefail

: "${LINT_MD_FILES:=}"
: "${MD_LINT_IGNORE_RULE:=}"

MARKDOWNLINT_CONFIG_DIR="$(mktemp -d)"
MARKDOWNLINT_CONFIG="${MARKDOWNLINT_CONFIG_DIR}/.markdownlint-cli2.yaml"
trap 'rm -f "${MARKDOWNLINT_CONFIG}"; rmdir "${MARKDOWNLINT_CONFIG_DIR}"' EXIT

{
  echo "config:"
  # MD013 line length, MD024 duplicate headings, MD007 list indent and MD047
  # trailing newline conflict with keepachangelog.com formatting.
  echo "  MD013: false"
  echo "  MD024: false"
  echo "  MD007: false"
  echo "  MD047: false"
  # MD060 was introduced after the previous mdl baseline and would make this
  # migration unexpectedly enforce table-column alignment.
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
npx --yes markdownlint-cli2@0.23.2 --config "${MARKDOWNLINT_CONFIG}" "${MD_TARGETS[@]}"
