#!/usr/bin/env bash
# Guard: chart dependencies resolve to a stable repository AND pin a stable version.
#
# The repository half stops a release depending on the dev channel. The version
# half stops it depending on a moving target: a range like `^1.2.0` or `~1.2`,
# or a `-rc`/`-alpha` pre-release, re-resolves on every `helm dependency update`,
# so the chart that passed review is not the chart that ships.
#
# Two mikefarah-yq traps, both of which made the previous version pass blind:
#   * no `--arg` flag -- it exits "unknown flag", and with stderr discarded that
#     read as "no offenders", so this guard never inspected a dependency.
#     Values reach the expression through strenv() instead.
#   * `"\(.a) -> \(.b)"` interpolation is evaluated even for nodes select()
#     filtered out, yielding a phantom " -> " row. Plain + concatenation is
#     used instead, and it also avoids a nested-quote lexer error.
#
# Env:
#   ALLOW_UNSTABLE_LIBRARY_REFS  "true" downgrades a failure to a warning.
#                                Testing only -- see the README.
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-.}"
CHART_DIR="${CHART_DIR:-./chart}"
CHART_DEV_REPOSITORY_SUFFIX="${CHART_DEV_REPOSITORY_SUFFIX:-/dev}"
CHART_REGISTRY="${CHART_REGISTRY:-}"
ALLOW_UNSTABLE_LIBRARY_REFS="${ALLOW_UNSTABLE_LIBRARY_REFS:-false}"
CHART_FILE="${PROJECT_PATH}/${CHART_DIR}/Chart.yaml"

if [[ ! -f "${CHART_FILE}" ]]; then
  echo "No chart at ${CHART_FILE}; nothing to check."
  exit 0
fi

summarise() {
  if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
    return 0
  fi
  {
    echo "### ⎈ Chart dependencies"
    echo ""
    echo "$1"
    if [[ -n "${2:-}" ]]; then
      echo ""
      echo '```'
      printf '%s\n' "${2}"
      echo '```'
    fi
    if [[ -n "${3:-}" ]]; then
      echo ""
      echo "${3}"
    fi
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
}

FAILED=false

# Keep the dependency guard aligned with init.yml. Docker Hub stores candidate
# and release charts in one namespace-root repository, so there is no separate
# development chart path to reject. Other registries retain the `/dev` path.
case "${CHART_REGISTRY}" in
  docker.io|index.docker.io|registry-1.docker.io)
    CHART_DEV_REPOSITORY_SUFFIX=""
    ;;
esac

# --- 1. no dependency may resolve to the development repository -------------
if [[ "${CHART_REGISTRY}" == "docker.io" || "${CHART_REGISTRY}" == "index.docker.io" || "${CHART_REGISTRY}" == "registry-1.docker.io" ]]; then
  echo "::notice title=Chart dependency::Docker Hub uses one namespace-root chart repository for candidate and release versions; the development-repository dependency check is not applicable."
elif [[ -n "${CHART_REPOSITORY:-}" && -n "${CHART_DEV_REPOSITORY_SUFFIX}" ]]; then
  export DEV_PATH="${CHART_REPOSITORY}${CHART_DEV_REPOSITORY_SUFFIX}"
  DEV_OFFENDERS="$(yq -r '
    .dependencies[]?
    | select((.repository // "") | test(strenv(DEV_PATH)))
    | .name + " -> " + (.repository // "")' "${CHART_FILE}")"
  if [[ -n "${DEV_OFFENDERS}" ]]; then
    FAILED=true
    echo "::error title=Chart dependency::A dependency resolves to the development repository '${DEV_PATH}'."
    printf '%s\n' "${DEV_OFFENDERS}"
    summarise "❌ These dependencies point at the development repository \`${DEV_PATH}\`:" \
      "${DEV_OFFENDERS}" "Depend on published stable releases instead."
  fi
else
  echo "::notice title=Chart dependency::CHART_REPOSITORY or CHART_DEV_REPOSITORY_SUFFIX is unset, so the development-repository check is skipped."
fi

# --- 2. every dependency pins an exact version ------------------------------
# 1, 1.2, 1.2.3, optionally v-prefixed. A range operator or a pre-release
# suffix is not a fixed point.
FLOATING="$(yq -r '
  .dependencies[]?
  | select(((.version // "") | test("^v?[0-9]+(\.[0-9]+){0,2}$")) | not)
  | .name + " -> " + ((.version // "unset") | tostring)' "${CHART_FILE}")"

if [[ -n "${FLOATING}" ]]; then
  if [[ "${ALLOW_UNSTABLE_LIBRARY_REFS,,}" == "true" ]]; then
    echo "::warning title=Chart dependency::Dependency version(s) are not an exact pin. Failing is suppressed by allow-unstable-library-refs, which is for testing only."
    printf '%s\n' "${FLOATING}"
    summarise "⚠️ These dependencies do not pin an exact version. **\`allow-unstable-library-refs\` is enabled**, so this did not fail the run — it is a testing escape hatch and must not stay on." \
      "${FLOATING}"
  else
    FAILED=true
    echo "::error title=Chart dependency::Dependency version(s) are a range or a pre-release, not an exact pin."
    printf '%s\n' "${FLOATING}"
    summarise "❌ These dependencies do not pin an exact version:" "${FLOATING}" \
      "A range re-resolves on every \`helm dependency update\`, so the chart that passed review is not the chart that ships. Pin the exact version you tested."
  fi
fi

if [[ "${FAILED}" == "true" ]]; then
  exit 1
fi

echo "All chart dependencies resolve to stable repositories and pin an exact version."
summarise "✅ All dependencies resolve to stable repositories and pin an exact version."
