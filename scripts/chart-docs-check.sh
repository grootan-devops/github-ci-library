#!/usr/bin/env bash
# Fails when chart/README.md is out of date with values.yaml.
#
# Port of the GitLab `Chart:Check:README` job: regenerate with helm-docs and
# compare checksums, so the committed README is always the generated one.
#
# Optional environment:
#   CHART_DIR   default ./chart
set -euo pipefail

: "${CHART_DIR:=./chart}"
HELM_DOCS_ARGS=(--template-files "README.gotmpl" --sort-values-order file --document-dependency-values)

cd "${CHART_DIR}"

if [[ ! -f README.md ]]; then
  echo "::error title=Chart docs::${CHART_DIR}/README.md is missing. Generate it with: helm-docs -c ${CHART_DIR}/ ${HELM_DOCS_ARGS[*]}"
  exit 1
fi

MD5_CHART_DOCS=$(md5sum README.md)
helm-docs "${HELM_DOCS_ARGS[@]}"
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
