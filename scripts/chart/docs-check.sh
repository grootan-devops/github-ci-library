#!/usr/bin/env bash
# Fails when chart/README.md is out of date with values.yaml: regenerate with
# helm-docs and compare checksums. GitLab counterpart: `Chart:Check:README`.
set -euo pipefail

: "${CHART_DIR:=./chart}"
HELM_DOCS_ARGS=(--template-files "README.gotmpl" --sort-values-order file --document-dependency-values)

cd "${CHART_DIR}"

summarise() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "${1}" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

if [[ ! -f README.md ]]; then
  echo "::error title=Chart docs::${CHART_DIR}/README.md is missing. Generate it with: helm-docs -c ${CHART_DIR}/ ${HELM_DOCS_ARGS[*]}"
  summarise "### ⎈ Chart documentation
❌ \`${CHART_DIR}/README.md\` does not exist. Generate and commit it:

\`\`\`bash
helm-docs -c ${CHART_DIR}/ ${HELM_DOCS_ARGS[*]}
\`\`\`"
  exit 1
fi

MD5_CHART_DOCS=$(md5sum README.md)
# Capture helm-docs' own words: a parse failure is not a stale README.
if ! HELM_DOCS_OUTPUT="$(helm-docs "${HELM_DOCS_ARGS[@]}" 2>&1)"; then
  echo "${HELM_DOCS_OUTPUT}" >&2
  echo "::error title=Chart docs::helm-docs could not regenerate ${CHART_DIR}/README.md."
  summarise "### ⎈ Chart documentation
❌ \`helm-docs\` could not regenerate \`${CHART_DIR}/README.md\`, so it could not be compared. helm-docs reported:

\`\`\`
$(tail -n 30 <<< "${HELM_DOCS_OUTPUT}")
\`\`\`"
  exit 1
fi
echo "${HELM_DOCS_OUTPUT}"
MD5_NEW_CHART_DOCS=$(md5sum README.md)

if [[ "${MD5_CHART_DOCS}" != "${MD5_NEW_CHART_DOCS}" ]]; then
  echo "::error title=Chart docs::${CHART_DIR}/README.md is stale. Run: helm-docs -c ${CHART_DIR}/ ${HELM_DOCS_ARGS[*]}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### ⎈ Chart documentation"
      echo ""
      echo "❌ \`${CHART_DIR}/README.md\` is out of date with \`values.yaml\`."
      echo ""
      echo '```bash'
      echo "helm-docs -c ${CHART_DIR}/ ${HELM_DOCS_ARGS[*]}"
      echo '```'
      echo ""
      echo "<details><summary>Diff</summary>"
      echo ""
      echo '```diff'
      git --no-pager diff -- README.md || true
      echo '```'
      echo ""
      echo "</details>"
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

echo "✅ Chart README.md is up to date."
