#!/usr/bin/env bash
# Guard: biome.json exists at the Node project root before Biome runs.
#
# Biome is the only formatter and linter this workflow runs, and without a
# config it falls back to its built-in defaults: it still exits 0, so a
# project that never added biome.json gets a green lint job that checked
# almost nothing. Failing here, with the starter config printed into the step
# summary, is the difference between "lint passed" and "lint was never
# configured".
#
# Exit codes: 0 biome.json present. 1 missing.
#
# Env:
#   PROJECT_PATH         Node project root, used in the error message only
#   GITHUB_STEP_SUMMARY  GitHub-provided; appended to on the failure path
set -euo pipefail

: "${PROJECT_PATH:?PROJECT_PATH must be set}"

if [[ -f biome.json ]]; then
  echo "biome.json found."
  exit 0
fi
echo "::error title=Biome::biome.json not found in ${PROJECT_PATH}. Create it at the project root."
{
  echo "### 📗 Node lint: biome"
  echo ""
  echo "❌ \`biome.json\` is missing. Create it at the project root:"
  echo ""
  echo '```json'
  echo '{'
  # shellcheck disable=SC2016 # $schema is a JSON key, not a shell variable
  echo '  "$schema": "https://biomejs.dev/schemas/2.3.11/schema.json",'
  echo '  "formatter": { "lineWidth": 320 },'
  echo '  "files": {'
  echo '    "includes": ["**/*.ts", "**/*.tsx", "**/*.js", "**/*.jsx", "**/*.json", "**/*.html", "**/*.css", "**/*.scss", "!!node_modules", "!!dist", "!!coverage"]'
  echo '  }'
  echo '}'
  echo '```'
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
exit 1
