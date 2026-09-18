#!/usr/bin/env bash
# markdownlint (mdl) with the organisation's baseline rule exclusions.
#
# Port of the GitLab `.MD:Lint` job template.
#
# Optional environment:
#   LINT_MD_FILES        files/globs to lint (default: every tracked *.md)
#   MD_LINT_IGNORE_RULE  space-separated extra rules to exclude, e.g. "MD033 MD041"
set -euo pipefail

: "${LINT_MD_FILES:=}"
: "${MD_LINT_IGNORE_RULE:=}"

echo 'style "#{File.dirname(__FILE__)}/markdownlint.rb"' > .markdownlintrc

{
  echo "all"
  # MD013 line length, MD024 duplicate headings, MD007 list indent and MD047
  # trailing newline conflict with keepachangelog.com formatting.
  echo "exclude_rule 'MD013'"
  echo "exclude_rule 'MD024'"
  echo "exclude_rule 'MD007'"
  echo "exclude_rule 'MD047'"
  for RULE in ${MD_LINT_IGNORE_RULE}; do
    echo "exclude_rule '${RULE}'"
  done
} > markdownlint.rb

if [[ -z "${LINT_MD_FILES}" ]]; then
  mapfile -t MD_TARGETS < <(git ls-files '*.md')
else
  # shellcheck disable=SC2206 # deliberate word splitting: a space-separated list of globs
  MD_TARGETS=(${LINT_MD_FILES})
fi

if [[ ${#MD_TARGETS[@]} -eq 0 ]]; then
  echo "No markdown files to lint."
  exit 0
fi

echo "Linting: ${MD_TARGETS[*]}"
mdl --config .markdownlintrc "${MD_TARGETS[@]}"
