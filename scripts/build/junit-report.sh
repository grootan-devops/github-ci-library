#!/usr/bin/env bash
# Publishes JUnit XML as a GitHub check run and/or a job summary, via the Checks API.
# GH_TOKEN needs checks:write; without it only the job summary is written.
# MAX_ANNOTATIONS caps at 50, GitHub's per-request annotation limit.
set -euo pipefail

: "${REPORT_GLOB:?REPORT_GLOB is required}"
: "${CHECK_NAME:?CHECK_NAME is required}"
JOB_SUMMARY="${JOB_SUMMARY:-true}"
FAIL_ON_FAILURE="${FAIL_ON_FAILURE:-false}"
ANNOTATION_LEVEL="${ANNOTATION_LEVEL:-failure}"
MAX_ANNOTATIONS="${MAX_ANNOTATIONS:-50}"
MAX_LISTED_FAILURES="${MAX_LISTED_FAILURES:-20}"

shopt -s nullglob globstar
# shellcheck disable=SC2206 # deliberate globbing: REPORT_GLOB is a glob pattern
REPORTS=(${REPORT_GLOB})
shopt -u nullglob globstar

if [[ ${#REPORTS[@]} -eq 0 ]]; then
  echo "No JUnit report matched '${REPORT_GLOB}'; nothing to publish."
  if [[ "${JOB_SUMMARY}" == "true" ]]; then
    {
      echo "### ${CHECK_NAME}"
      echo ""
      echo "No test report matched \`${REPORT_GLOB}\`. Either the test command did not run, or it failed before writing JUnit XML — the test step's own output says which."
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 0
fi

# yq prefixes XML attributes with `+@`; XML-to-JSON collapses a single element
# into an object, which `arr` normalises.
# shellcheck disable=SC2016 # a jq program, not a shell expansion
NORMALISE='
  def arr: if . == null then [] elif type == "array" then . else [.] end;
  [ (.testsuites // .) | (.testsuite // .) | arr | .[]
    | . as $S
    | ($S.testcase | arr | .[]
        | {
            suite:     ($S."+@name" // ""),
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

if [[ "${JOB_SUMMARY}" == "true" ]]; then
  {
    echo "### ${CHECK_NAME}"
    echo ""
    echo "| Total | Passed | Failed | Skipped |"
    echo "|:--:|:--:|:--:|:--:|"
    echo "| ${TOTAL} | ${PASSED} | ${FAILED} | ${SKIPPED} |"
    echo ""
    if [[ "${FAILED}" -gt 0 ]]; then
      echo "<details><summary>Failures (showing up to ${MAX_LISTED_FAILURES} of ${FAILED})</summary>"
      echo ""
      jq -r --argjson MAX "${MAX_LISTED_FAILURES}" '[.[] | select(.failure != null)] | .[0:$MAX] | .[]
        | "- **\(.classname // "")\(if (.classname // "") != "" then " · " else "" end)\(.name)** — \((.failure["+@message"] // .failure | tostring) | gsub("\n"; " ") | .[0:300])"' <<< "${CASES}"
      if [[ "${FAILED}" -gt "${MAX_LISTED_FAILURES}" ]]; then
        echo ""
        echo "_…and $(( FAILED - MAX_LISTED_FAILURES )) more. Every case is in the uploaded test report._"
      fi
      echo ""
      echo "</details>"
      echo ""
    fi
  } >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ -n "${GH_TOKEN:-}" ]]; then
  ANNOTATIONS="$(
    jq -c --arg LEVEL "${ANNOTATION_LEVEL}" --argjson MAX "${MAX_ANNOTATIONS}" '
      [ .[] | select(.failure != null) ] | .[0:$MAX]
      | map({
          path: ".github",
          start_line: 1,
          end_line: 1,
          annotation_level: $LEVEL,
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
      --arg NAME "${CHECK_NAME}" \
      --arg SHA "${GITHUB_SHA}" \
      --arg CONCLUSION "${CONCLUSION}" \
      --arg SUMMARY "${SUMMARY}" \
      --argjson ANNOTATIONS "${ANNOTATIONS}" \
      '{name: $NAME, head_sha: $SHA, status: "completed", conclusion: $CONCLUSION,
        output: {title: $NAME, summary: $SUMMARY, annotations: $ANNOTATIONS}}' |
      curl -sSf -X POST \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        --data-binary @- \
        "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/check-runs" \
        > /dev/null 2>&1; then
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
