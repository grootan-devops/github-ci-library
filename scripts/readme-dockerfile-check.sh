#!/usr/bin/env bash
# hadolint every ```dockerfile block in a markdown file, so a documented example cannot
# drift from the standard the same linter enforces on a consumer's Dockerfile.
# Usage: readme-dockerfile-check.sh [file.md ...]   (default: README.md)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/hadolint-ignores.sh
source "${SCRIPT_DIR}/hadolint-ignores.sh"

FILES=("$@")
[[ ${#FILES[@]} -eq 0 ]] && FILES=("README.md")

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

HADOLINT_ARGS=()
IFS=',' read -r -a IGNORES <<< "${HADOLINT_DEFAULT_IGNORE}"
for RULE in "${IGNORES[@]}"; do
  HADOLINT_ARGS+=(--ignore "${RULE}")
done

TOTAL=0
FAILED=0
REPORT="${WORK}/report"
: > "${REPORT}"

for MD in "${FILES[@]}"; do
  if [[ ! -f "${MD}" ]]; then
    echo "::error title=README Dockerfile check::${MD} not found."
    exit 1
  fi

  mapfile -t STARTS < <(grep -n '^```dockerfile$' "${MD}" | cut -d: -f1)
  for START in "${STARTS[@]}"; do
    END="$(awk -v s="${START}" 'NR>s && /^```$/ {print NR; exit}' "${MD}")"
    [[ -z "${END}" ]] && continue
    BLOCK="${WORK}/${MD//\//_}-L${START}.Dockerfile"
    awk -v s="${START}" -v e="${END}" 'NR>s && NR<e' "${MD}" > "${BLOCK}"
    TOTAL=$((TOTAL + 1))

    if ! OUT="$(hadolint "${HADOLINT_ARGS[@]}" --disable-ignore-pragma "${BLOCK}" 2>&1)"; then
      FAILED=$((FAILED + 1))
      {
        echo "**\`${MD}\` line ${START}**"
        echo ""
        echo '```'
        echo "${OUT//${BLOCK}/${MD}:${START}}"
        echo '```'
        echo ""
      } >> "${REPORT}"
      echo "::error file=${MD},line=${START}::Dockerfile example fails hadolint."
      echo "${OUT//${BLOCK}/${MD}:${START}}"
    fi
  done
done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 🐳 README Dockerfile examples"
    echo ""
    if [[ "${FAILED}" -eq 0 ]]; then
      echo "✅ ${TOTAL} example$([[ ${TOTAL} -eq 1 ]] || echo s) lint clean."
    else
      echo "❌ ${FAILED} of ${TOTAL} examples have findings."
      echo ""
      cat "${REPORT}"
    fi
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi

echo "Checked ${TOTAL} example(s); ${FAILED} with findings."
[[ "${FAILED}" -eq 0 ]]
