#!/usr/bin/env bash
# Publishes JUnit XML as a GitHub check run, a job summary, or both.
#
# Replaces a third-party JUnit-reporting action. Organisations commonly allow
# only GitHub-authored and Marketplace-verified actions, and a blocked action
# fails the whole run at startup, before a single job begins — so the library
# reports its own results through the Checks API using the yq, jq and gh that
# already ship in the build container.
#
# Required environment:
#   REPORT_GLOB       glob matching the JUnit XML reports to publish
#   CHECK_NAME        title of the check run and of the summary section
#
# Optional environment:
#   GH_TOKEN          token with checks:write. Without it the check run is
#                     skipped and only the job summary is written.
#   JOB_SUMMARY       true  writes a summary table (default true)
#   FAIL_ON_FAILURE   true  exits non-zero when a test failed (default false)
#   ANNOTATION_LEVEL  failure | warning | notice (default failure)
#   MAX_ANNOTATIONS   cap on annotations sent (default 50, GitHub's per-request limit)
set -euo pipefail

: "${REPORT_GLOB:?REPORT_GLOB is required}"
: "${CHECK_NAME:?CHECK_NAME is required}"
JOB_SUMMARY="${JOB_SUMMARY:-true}"
FAIL_ON_FAILURE="${FAIL_ON_FAILURE:-false}"
ANNOTATION_LEVEL="${ANNOTATION_LEVEL:-failure}"
MAX_ANNOTATIONS="${MAX_ANNOTATIONS:-50}"

shopt -s nullglob globstar
# shellcheck disable=SC2206 # deliberate globbing: REPORT_GLOB is a glob pattern
REPORTS=(${REPORT_GLOB})
shopt -u nullglob globstar

if [[ ${#REPORTS[@]} -eq 0 ]]; then
  echo "No JUnit report matched '${REPORT_GLOB}'; nothing to publish."
  if [[ "${JOB_SUMMARY}" == "true" ]]; then
    { echo "### ${CHECK_NAME}"; echo; echo "No test report was produced."; echo; } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 0
fi

# yq reads XML natively, so the reports are parsed rather than pattern-matched.
# Attribute names arrive with yq's `+@` prefix. `[] // []` normalises the
# single-element case, which XML-to-JSON collapses into an object.
# shellcheck disable=SC2016 # a jq program, not a shell expansion
NORMALISE='
  def arr: if . == null then [] elif type == "array" then . else [.] end;
  [ (.testsuites // .) | (.testsuite // .) | arr | .[]
    | . as $s
    | ($s.testcase | arr | .[]
        | {
            suite:     ($s."+@name" // ""),
            name:      (."+@name" // ""),
            classname: (."+@classname" // ""),
            time:      (."+@time" // ""),
            failure:   (.failure // .error // null),
            skipped:   (has("skipped"))
          })
  ]'

CASES="$(
  for REPORT in "${REPORTS[@]}"; do
    yq -p xml -o json '.' "${REPORT}" 2>/dev/null | jq -c "${NORMALISE}" 2>/dev/null || true
  done | jq -c -s 'add // []'
)"

TOTAL="$(jq 'length' <<< "${CASES}")"
SKIPPED="$(jq '[.[] | select(.skipped)] | length' <<< "${CASES}")"
FAILED="$(jq '[.[] | select(.failure != null)] | length' <<< "${CASES}")"
PASSED=$(( TOTAL - SKIPPED - FAILED ))

echo "Parsed ${TOTAL} test case(s): ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped."

# ------------------------------------------------------------- job summary
if [[ "${JOB_SUMMARY}" == "true" ]]; then
  {
    echo "### ${CHECK_NAME}"
    echo ""
    echo "| Total | Passed | Failed | Skipped |"
    echo "|:--:|:--:|:--:|:--:|"
    echo "| ${TOTAL} | ${PASSED} | ${FAILED} | ${SKIPPED} |"
    echo ""
    if [[ "${FAILED}" -gt 0 ]]; then
      echo "<details><summary>Failures</summary>"
      echo ""
      jq -r '.[] | select(.failure != null)
        | "- **\(.classname // "")\(if (.classname // "") != "" then " · " else "" end)\(.name)** — \((.failure["+@message"] // .failure | tostring) | gsub("\n"; " ") | .[0:300])"' <<< "${CASES}"
      echo ""
      echo "</details>"
      echo ""
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

# ---------------------------------------------------------------- check run
if [[ -n "${GH_TOKEN:-}" ]]; then
  ANNOTATIONS="$(
    jq -c --arg level "${ANNOTATION_LEVEL}" --argjson max "${MAX_ANNOTATIONS}" '
      [ .[] | select(.failure != null) ] | .[0:$max]
      | map({
          path: ".github",
          start_line: 1,
          end_line: 1,
          annotation_level: $level,
          title: ((.classname // "") + (if (.classname // "") != "" then " · " else "" end) + .name),
          message: ((.failure["+@message"] // .failure | tostring) | .[0:1000])
        })' <<< "${CASES}"
  )"

  if [[ "${FAILED}" -gt 0 ]]; then
    CONCLUSION="failure"
    SUMMARY="${FAILED} of ${TOTAL} test case(s) failed."
  else
    CONCLUSION="success"
    SUMMARY="${PASSED} of ${TOTAL} test case(s) passed, ${SKIPPED} skipped."
  fi

  if jq -n \
      --arg name "${CHECK_NAME}" \
      --arg sha "${GITHUB_SHA}" \
      --arg conclusion "${CONCLUSION}" \
      --arg summary "${SUMMARY}" \
      --argjson annotations "${ANNOTATIONS}" \
      '{name: $name, head_sha: $sha, status: "completed", conclusion: $conclusion,
        output: {title: $name, summary: $summary, annotations: $annotations}}' |
      gh api "repos/${GITHUB_REPOSITORY}/check-runs" --method POST \
        --header "Accept: application/vnd.github+json" --input - > /dev/null 2>&1; then
    echo "Published check run '${CHECK_NAME}'."
  else
    # A missing checks:write permission must not fail a job whose tests passed.
    echo "::warning title=${CHECK_NAME}::Could not publish the check run. The job summary still has the results."
  fi
fi

if [[ "${FAIL_ON_FAILURE}" == "true" && "${FAILED}" -gt 0 ]]; then
  echo "::error title=${CHECK_NAME}::${FAILED} test case(s) failed."
  exit 1
fi
