#!/usr/bin/env bash
# Resolve which files this lint matrix leg lints, or mark the leg as skippable.
#
# The `discover` job builds the matrix by looking at the repository once, but
# every lint leg then runs in its own container with its own working directory.
# A target can therefore be on the matrix and still be absent by the time the
# leg starts. Deciding that here -- and publishing `skip=true` -- keeps the
# linter step from being reached at all, so an absent Dockerfile or changelog
# reads as "nothing to lint" in the run graph instead of as a linter failure
# nobody can act on. The concrete file list is handed to the linter through
# GITHUB_ENV, because yaml-lint.sh and markdown-lint.sh read LINT_YAML_FILES
# and LINT_MD_FILES from the environment rather than from arguments.
#
# Exit codes: 0 always -- an absent target is a skip, never a failure.
#
# Env:
#   SUBJECT              matrix leg: dockerfile, chart-values, yaml, changelog
#                        or migration
#   DOCKERFILE           Dockerfile path, relative to the working directory
#                        (default: empty, which resolves to a skip)
#   CHART_DIR            chart directory holding values.yaml (default: empty)
#   CHANGELOG_FILE_NAME  changelog path (default: empty)
#   MIGRATION_FILE_NAME  migration guide path (default: empty)
#   INPUT_YAML_FILES     space-separated YAML globs; empty lints every tracked
#                        YAML file (default: empty)
#   INPUT_MD_FILES       space-separated markdown globs; empty falls back to
#                        CHANGELOG_FILE_NAME (default: empty)
#
# Writes LINT_YAML_FILES / LINT_MD_FILES to GITHUB_ENV, and the `skip` output
# to GITHUB_OUTPUT.
set -euo pipefail

: "${SUBJECT:?SUBJECT must be set}"
: "${DOCKERFILE:=}"
: "${CHART_DIR:=}"
: "${CHANGELOG_FILE_NAME:=}"
: "${MIGRATION_FILE_NAME:=}"
: "${INPUT_YAML_FILES:=}"
: "${INPUT_MD_FILES:=}"

SKIP=false
case "${SUBJECT}" in
  dockerfile)
    if [[ ! -f "${DOCKERFILE}" ]]; then
      SKIP=true
    fi
    ;;
  chart-values)
    if [[ -f "${CHART_DIR}/values.yaml" ]]; then
      echo "LINT_YAML_FILES=${CHART_DIR}/values.yaml" >> "${GITHUB_ENV}"
    else
      SKIP=true
    fi
    ;;
  yaml)
    echo "LINT_YAML_FILES=${INPUT_YAML_FILES}" >> "${GITHUB_ENV}"
    ;;
  changelog)
    if [[ -f "${CHANGELOG_FILE_NAME}" ]]; then
      echo "LINT_MD_FILES=${INPUT_MD_FILES:-${CHANGELOG_FILE_NAME}}" >> "${GITHUB_ENV}"
    else
      SKIP=true
    fi
    ;;
  migration)
    if [[ -f "${MIGRATION_FILE_NAME}" ]]; then
      echo "LINT_MD_FILES=${MIGRATION_FILE_NAME}" >> "${GITHUB_ENV}"
    else
      SKIP=true
    fi
    ;;
esac

echo "skip=${SKIP}" >> "${GITHUB_OUTPUT}"
if [[ "${SKIP}" == "true" ]]; then
  echo "Nothing to lint for '${SUBJECT}'."
fi
