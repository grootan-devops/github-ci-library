#!/usr/bin/env bash
# Run the SonarQube scanner and, when asked, wait on the quality gate.
#
# The project key is derived here rather than passed in because a monorepo child
# analyses the same repository as its parent: without a slug of its subdirectory
# appended, both would report into one SonarQube project and overwrite each
# other's measures. The key is written to GITHUB_ENV *before* the scanner runs so
# the summary step can still name the project when the scan itself fails.
#
# Exit codes: the scanner's own. A failing quality gate must fail the job, so
# errexit is lifted only long enough to read the status out of PIPESTATUS past
# the `tee`, and is then re-raised as this script's exit code.
#
# Env:
#   SONAR_URL          SonarQube server URL
#   SONAR_TOKEN        SonarQube authentication token
#   WAIT               "true" to block on, and fail with, the quality gate
#   VAR_PROJECT_KEY    repository/organisation default project key (default: empty)
#   PROJECT_VERSION    version reported to SonarQube (default: empty)
#   SUBPATH            monorepo child path, slugged onto the key (default: empty)
set -euo pipefail

: "${SONAR_URL:?SONAR_URL must be set}"
: "${SONAR_TOKEN:?SONAR_TOKEN must be set}"
: "${WAIT:?WAIT must be set}"

: "${VAR_PROJECT_KEY:=}"
: "${PROJECT_VERSION:=}"
: "${SUBPATH:=}"

PROJECT_KEY="${VAR_PROJECT_KEY:-${GITHUB_REPOSITORY//\//_}}"
if [[ -n "${SUBPATH}" && "${SUBPATH}" != "." ]]; then
  SLUG="$(tr -c 'a-zA-Z0-9_.:-' '-' <<<"${SUBPATH}" | sed 's/-\+/-/g;s/^-//;s/-$//')"
  PROJECT_KEY="${PROJECT_KEY}_${SLUG}"
fi
echo "Analysing as project key '${PROJECT_KEY}'."

SCANNER_ARGS=(
  "-Dsonar.projectKey=${PROJECT_KEY}"
  "-Dsonar.host.url=${SONAR_URL}"
  "-Dsonar.token=${SONAR_TOKEN}"
  "-Dsonar.qualitygate.wait=${WAIT}"
  "-Dsonar.links.ci=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions"
  "-Dsonar.links.scm=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
)
if [[ -n "${PROJECT_VERSION}" ]]; then
  SCANNER_ARGS+=("-Dsonar.projectVersion=${PROJECT_VERSION}")
fi
if [[ -f sonar.properties ]]; then
  SCANNER_ARGS+=("-Dproject.settings=sonar.properties")
fi

# Exported before the scanner runs: the summary needs the key even on failure.
echo "SONAR_PROJECT_KEY=${PROJECT_KEY}" >> "${GITHUB_ENV}"

set +e
sonar-scanner "${SCANNER_ARGS[@]}" 2>&1 | tee "${RUNNER_TEMP}/sonar-scanner.log"
SCANNER_RESULT="${PIPESTATUS[0]}"
set -e
exit "${SCANNER_RESULT}"
