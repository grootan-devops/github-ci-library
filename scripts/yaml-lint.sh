#!/usr/bin/env bash
# yamllint, using the project's own config when it ships one.
#
# Port of the GitLab `.YAML:Lint` job template.
#
# Optional environment:
#   LINT_YAML_FILES   files/globs to lint (default: every tracked *.yml / *.yaml)
set -euo pipefail

: "${LINT_YAML_FILES:=}"

if [[ -z "${LINT_YAML_FILES}" ]]; then
  mapfile -t YAML_TARGETS < <(git ls-files '*.yml' '*.yaml')
else
  # shellcheck disable=SC2206 # deliberate word splitting: a space-separated list of globs
  YAML_TARGETS=(${LINT_YAML_FILES})
fi

if [[ ${#YAML_TARGETS[@]} -eq 0 ]]; then
  echo "No YAML files to lint."
  exit 0
fi

echo "Linting: ${YAML_TARGETS[*]}"
# shellcheck source=scripts/lint-summary.sh
source "$(dirname "${BASH_SOURCE[0]}")/lint-summary.sh"
if [[ ! -f .yamllint.yml && ! -f .yamllint.yaml && ! -f .yamllint ]]; then
  run_linted "🧾 YAML lint" yamllint -s \
    -d "{extends: default, rules: {line-length: disable, document-start: disable, comments: disable, comments-indentation: disable}}" \
    "${YAML_TARGETS[@]}"
else
  run_linted "🧾 YAML lint" yamllint -s "${YAML_TARGETS[@]}"
fi
