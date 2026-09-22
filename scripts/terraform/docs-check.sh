#!/usr/bin/env bash
# Fails when a Terraform README.md is out of date with its module inputs — every
# directory under modules/ plus the root. GitLab counterpart: `Terraform:Check:README`.
set -euo pipefail

: "${TF_README_FILE_NAME:=README.md}"
STALE=()
UNREADABLE=()

check_dir() {
  local DIR="${1}"
  local README_FILE="${DIR}/${TF_README_FILE_NAME}"

  if [[ ! -f "${README_FILE}" ]]; then
    echo "::error title=Terraform docs::${README_FILE} is missing."
    STALE+=("${README_FILE} (missing)")
    return
  fi

  local BEFORE AFTER OUTPUT
  BEFORE=$(md5sum "${README_FILE}")
  # Capture terraform-docs' own words: a module it cannot parse is not a stale README.
  if ! OUTPUT="$(terraform-docs markdown table "${DIR}" --output-file "${TF_README_FILE_NAME}" --required 2>&1)"; then
    echo "${OUTPUT}" >&2
    echo "::error title=Terraform docs::terraform-docs could not read ${DIR}."
    UNREADABLE+=("${README_FILE}:::$(tail -n 5 <<< "${OUTPUT}")")
    return
  fi
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
    if [[ ! -d "${DIR}" ]]; then
      continue
    fi
    check_dir "${DIR}"
  done
fi
check_dir "."

if [[ ${#STALE[@]} -gt 0 || ${#UNREADABLE[@]} -gt 0 ]]; then
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 🌍 Terraform documentation"
      echo ""
      if [[ ${#UNREADABLE[@]} -gt 0 ]]; then
        echo "❌ terraform-docs could not read these modules, so their documentation was never compared:"
        echo ""
        echo '```'
        for ENTRY in "${UNREADABLE[@]}"; do
          echo "${ENTRY%%:::*}"
          echo "${ENTRY#*:::}"
        done
        echo '```'
        echo ""
      fi
      if [[ ${#STALE[@]} -gt 0 ]]; then
        echo "❌ Stale or missing generated docs:"
        # shellcheck disable=SC2016 # backticks are markdown, not command substitution
        printf -- '- `%s`\n' "${STALE[@]}"
        echo ""
        echo '```bash'
        echo "terraform-docs markdown table . --output-file ${TF_README_FILE_NAME} --recursive --required"
        echo '```'
        echo ""
      fi
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### 🌍 Terraform documentation\n\n✅ All generated READMEs are up to date.\n\n' >> "${GITHUB_STEP_SUMMARY}"
fi
