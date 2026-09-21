#!/usr/bin/env bash
# Guard: every reusable-workflow call pins a stable release tag.
#
# A caller on `@dev`, `@main` or a commit SHA silently changes underneath the
# repository: the pipeline that passed yesterday is not the pipeline that runs
# today, and a release cut from it cannot be reproduced. Only a published tag
# is a fixed point.
#
# Scope: job-level `uses: <owner>/<repo>/.github/workflows/<file>.yml@<ref>`.
# Step-level action pins (actions/checkout@v7) are a separate concern and are
# not touched here.
#
# Env:
#   ALLOW_UNSTABLE_LIBRARY_REFS  "true" downgrades the failure to a warning.
#                                Testing only -- see the README.
set -euo pipefail

ALLOW_UNSTABLE_LIBRARY_REFS="${ALLOW_UNSTABLE_LIBRARY_REFS:-false}"
# Workflows live at the repository root, never under project-path: a monorepo
# child shares its parent's .github/ and must not scan its own subdirectory.
LIBRARY_PIN_ROOT="${LIBRARY_PIN_ROOT:-${GITHUB_WORKSPACE:-.}}"
WORKFLOW_DIR="${LIBRARY_PIN_ROOT}/.github/workflows"

if [[ ! -d "${WORKFLOW_DIR}" ]]; then
  echo "No ${WORKFLOW_DIR}; nothing to check."
  exit 0
fi

# A stable release tag: 1, 1.2, 1.2.3, optionally v-prefixed. A pre-release
# suffix (-rc.1, -beta) is deliberately rejected: it is not a stable release.
STABLE_TAG='^v?[0-9]+(\.[0-9]+){0,2}$'

OFFENDERS=""
CHECKED=0

while IFS= read -r LINE; do
  FILE="${LINE%%:*}"
  REST="${LINE#*:}"
  SPEC="$(printf '%s' "${REST}" | sed -E 's;.*uses:[[:space:]]*;;; s;[[:space:]]*(#.*)?$;;' | tr -d "\"'")"
  REPO="${SPEC%%/.github/workflows/*}"
  REF="${SPEC##*@}"
  if [[ -z "${REF}" || "${REF}" == "${SPEC}" ]]; then
    continue
  fi
  CHECKED=$((CHECKED + 1))

  if [[ "${REF}" =~ ${STABLE_TAG} ]]; then
    continue
  fi

  if [[ "${REF}" =~ ^[0-9a-f]{7,40}$ ]]; then
    WHY="a commit SHA"
  elif [[ "${REF}" =~ - ]]; then
    WHY="a pre-release tag"
  else
    WHY="a branch"
  fi
  OFFENDERS+="$(basename "${FILE}") -> ${REPO}@${REF} (${WHY})"$'\n'
done < <(grep -rnE '^\s*uses:.*/\.github/workflows/.*@' "${WORKFLOW_DIR}" 2>/dev/null || true)

if [[ -z "${OFFENDERS}" ]]; then
  echo "All ${CHECKED} reusable-workflow calls pin a stable release tag."
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 📌 Library pinning"
      echo ""
      echo "✅ All ${CHECKED} reusable-workflow calls pin a stable release tag."
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 0
fi

COUNT="$(grep -c . <<<"${OFFENDERS}")"

if [[ "${ALLOW_UNSTABLE_LIBRARY_REFS,,}" == "true" ]]; then
  echo "::warning title=Library pinning::${COUNT} reusable-workflow call(s) do not pin a stable tag. Failing is suppressed by allow-unstable-library-refs, which is for testing only."
  printf '%s' "${OFFENDERS}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 📌 Library pinning"
      echo ""
      echo "⚠️ ${COUNT} call(s) float. **\`allow-unstable-library-refs\` is enabled**, so this did not fail the run — it is a testing escape hatch and must not stay on."
      echo ""
      echo '```'
      printf '%s' "${OFFENDERS}"
      echo '```'
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 0
fi

echo "::error title=Library pinning::${COUNT} reusable-workflow call(s) pin a branch, a commit or a pre-release instead of a stable release tag."
printf '%s' "${OFFENDERS}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 📌 Library pinning"
    echo ""
    echo "❌ ${COUNT} reusable-workflow call(s) do not pin a stable release tag:"
    echo ""
    echo '```'
    printf '%s' "${OFFENDERS}"
    echo '```'
    echo ""
    echo "A branch or commit moves underneath the repository, so the pipeline that passed"
    echo "yesterday is not the one that runs today and a release cannot be reproduced."
    echo "Pin a published tag: \`git ls-remote --tags <library>\` lists them."
    echo ""
    echo "\`allow-unstable-library-refs: true\` suppresses this while testing a library branch."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi
exit 1
