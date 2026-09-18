#!/usr/bin/env bash
# Fails when a Terraform README.md is out of date with its module inputs.
#
# Port of the GitLab `Terraform:Check:README` job: every directory under
# modules/ plus the repository root.
#
# Optional environment:
#   TF_README_FILE_NAME   default README.md
set -euo pipefail

: "${TF_README_FILE_NAME:=README.md}"
STALE=()

check_dir() {
  local DIR="${1}"
  local README_FILE="${DIR}/${TF_README_FILE_NAME}"

  if [[ ! -f "${README_FILE}" ]]; then
    echo "::error title=Terraform docs::${README_FILE} is missing."
    STALE+=("${README_FILE} (missing)")
    return
  fi

  local BEFORE AFTER
  BEFORE=$(md5sum "${README_FILE}")
  terraform-docs markdown table "${DIR}" --output-file "${TF_README_FILE_NAME}" --required
  AFTER=$(md5sum "${README_FILE}")

  if [[ "${BEFORE}" != "${AFTER}" ]]; then
    echo "::error title=Terraform docs::${README_FILE} is stale."
    STALE+=("${README_FILE}")
  else
    echo "✅ ${README_FILE} is up to date."
  fi
}

if [[ -d modules ]]; then
  for DIR in modules/*; do
    [[ -d "${DIR}" ]] || continue
    check_dir "${DIR}"
  done
fi
check_dir "."

if [[ ${#STALE[@]} -gt 0 ]]; then
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 🌍 Terraform documentation"
      echo ""
      echo "❌ Stale or missing generated docs:"
      # shellcheck disable=SC2016 # backticks are markdown, not command substitution
      printf -- '- `%s`\n' "${STALE[@]}"
      echo ""
      echo '```bash'
      echo "terraform-docs markdown table . --output-file ${TF_README_FILE_NAME} --recursive --required"
      echo '```'
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### 🌍 Terraform documentation\n\n✅ All generated READMEs are up to date.\n\n' >> "${GITHUB_STEP_SUMMARY}"
fi
