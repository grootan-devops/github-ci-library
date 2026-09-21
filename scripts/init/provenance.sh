#!/usr/bin/env bash
# Find the candidate build that this release commit was merged from.
#
# A release does not rebuild: it promotes the image and chart that the merged
# pull request already built and scanned. That requires the pull request
# number, its head commit and the successful upstream run that carries the
# artifacts, and each of the three is resolved from whichever source is
# available -- the commit/pulls association, a merge commit's second parent, a
# squash commit subject, then the pull request itself. None of it is fatal:
# a commit pushed straight to the branch has no candidate run, and promotion
# then falls back to resolving the artifact by tag.
#
# `gh` is NOT installed in the toolkit container, only on the runner host, so
# every lookup talks to the REST API with curl and jq. Do not switch it back.
#
# Exit codes: 0 always, unless a shell or jq error aborts under errexit. The
# step inherits errexit from the workflow default shell, so this script sets it
# explicitly to keep the exit behaviour it had inline.
#
# Env:
#   GH_TOKEN             token for the REST API (default: empty, lookups then 401)
#   UPSTREAM_WORKFLOW    workflow file that builds candidates, e.g. pr.yml (default: empty)
#   BASE_IMAGE_TAG       resolved image tag without a suffix (default: empty)
#   BASE_CHART_VERSION   resolved chart version without a suffix (default: empty)
#   IGNORE_DOCKER        "true" when this run publishes no image (default: empty)
#   IGNORE_CHART         "true" when this run publishes no chart (default: empty)
set -euo pipefail

: "${GH_TOKEN:=}"
: "${UPSTREAM_WORKFLOW:=}"
: "${BASE_IMAGE_TAG:=}"
: "${BASE_CHART_VERSION:=}"
: "${IGNORE_DOCKER:=}"
: "${IGNORE_CHART:=}"

MERGED_PR_NUMBER=""
UPSTREAM_HEAD_SHA=""
UPSTREAM_RUN_ID=""
UPSTREAM_RUN_NUMBER=""

# The checkout is owned by a different uid than the container runs as, so git
# refuses it with "detected dubious ownership" and every git-based fallback
# below silently returns empty -- their stderr is discarded.
# The checkout is owned by a different uid than this container runs as, so git
# refuses it with "detected dubious ownership". actions/checkout writes its own
# safe.directory under a temporary HOME that this step does not inherit, and the
# mismatch is structural rather than path-specific, so accept any path.
git config --global --add safe.directory '*' 2>/dev/null || true

# `gh` is NOT installed in the toolkit container -- only on the runner host.
# Every lookup here was written `gh ... 2>/dev/null || true`, so "command not
# found" was indistinguishable from "no result": provenance silently resolved
# nothing on every containerised run. curl and jq are present, so talk to the
# REST API directly and keep the errors.
api() {
  local path="$1"; shift
  curl -sS -H "Authorization: Bearer ${GH_TOKEN}" \
       -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" \
       "${GITHUB_API_URL}${path}" "$@"
}

API_ERR="$(mktemp)"

PR_JSON="$(api "/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" 2>"${API_ERR}" \
  | jq -r '[.[]? | select(.merged_at != null)] | first // empty' 2>/dev/null || true)"
if [[ -n "${PR_JSON}" ]]; then
  MERGED_PR_NUMBER="$(jq -r '.number // empty' <<<"${PR_JSON}")"
  UPSTREAM_HEAD_SHA="$(jq -r '.head.sha // empty' <<<"${PR_JSON}")"
  if [[ -n "${MERGED_PR_NUMBER}" ]]; then
    echo "Resolved PR #${MERGED_PR_NUMBER} via commit/pulls association."
  fi
elif [[ -s "${API_ERR}" ]]; then
  echo "::notice title=Provenance::commits/pulls lookup: $(tr '\n' ' ' < "${API_ERR}" | cut -c1-200)"
fi

# A true merge commit carries the pull request head as its second parent. A squash
# merge and a direct push have one parent, and without --verify --quiet rev-parse
# PRINTS "HEAD^2" on stdout, which then poisons every lookup below.
if [[ -z "${UPSTREAM_HEAD_SHA}" ]]; then
  UPSTREAM_HEAD_SHA="$(git rev-parse --verify --quiet 'HEAD^2^{commit}' 2>/dev/null || true)"
  if [[ -n "${UPSTREAM_HEAD_SHA}" ]]; then
    echo "Resolved head commit ${UPSTREAM_HEAD_SHA} via HEAD^2."
  fi
fi
if [[ -n "${UPSTREAM_HEAD_SHA}" && ! "${UPSTREAM_HEAD_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Discarding unusable upstream commit '${UPSTREAM_HEAD_SHA}'."
  UPSTREAM_HEAD_SHA=""
fi

if [[ -z "${MERGED_PR_NUMBER}" && -n "${UPSTREAM_HEAD_SHA}" ]]; then
  MERGED_PR_NUMBER="$(api "/repos/${GITHUB_REPOSITORY}/commits/${UPSTREAM_HEAD_SHA}/pulls" 2>/dev/null \
    | jq -r '.[0].number // empty' 2>/dev/null || true)"
  if [[ -n "${MERGED_PR_NUMBER}" ]]; then
    echo "Resolved PR #${MERGED_PR_NUMBER} via upstream commit."
  fi
fi

# The squash path: the subject carries "(#N)" and there is no second parent.
if [[ -z "${MERGED_PR_NUMBER}" ]]; then
  CANDIDATE="$(git log -1 --pretty=%s 2>/dev/null | grep -oE '\(#[0-9]+\)' | tail -n1 | tr -dc '0-9' || true)"
  if [[ -n "${CANDIDATE}" ]]; then
    MERGED_PR_NUMBER="${CANDIDATE}"
    echo "Resolved PR #${MERGED_PR_NUMBER} from squash commit subject."
  fi
fi

# With the pull request known, its head commit is one read away. This is the hinge:
# no head commit means no candidate run, which means a notes-only release.
if [[ -n "${MERGED_PR_NUMBER}" && -z "${UPSTREAM_HEAD_SHA}" ]]; then
  : > "${API_ERR}"
  UPSTREAM_HEAD_SHA="$(api "/repos/${GITHUB_REPOSITORY}/pulls/${MERGED_PR_NUMBER}" 2>"${API_ERR}" \
    | jq -r '.head.sha // empty' 2>/dev/null || true)"
  if [[ -n "${UPSTREAM_HEAD_SHA}" ]]; then
    echo "Resolved head commit ${UPSTREAM_HEAD_SHA} from PR #${MERGED_PR_NUMBER}."
  else
    echo "::warning title=Provenance::Could not read PR #${MERGED_PR_NUMBER} to find its head commit, so no candidate run can be located and the release will carry notes only. The API reported: $(tr '\n' ' ' < "${API_ERR}" | cut -c1-300)"
  fi
fi

if [[ -n "${UPSTREAM_HEAD_SHA}" ]]; then
  RUNS_JSON="$(api "/repos/${GITHUB_REPOSITORY}/actions/workflows/${UPSTREAM_WORKFLOW}/runs?head_sha=${UPSTREAM_HEAD_SHA}&status=success&per_page=1" 2>/dev/null || true)"
  UPSTREAM_RUN_ID="$(jq -r '.workflow_runs[0].id // empty' <<<"${RUNS_JSON:-{}}" 2>/dev/null || true)"
  UPSTREAM_RUN_NUMBER="$(jq -r '.workflow_runs[0].run_number // empty' <<<"${RUNS_JSON:-{}}" 2>/dev/null || true)"
  if [[ -n "${UPSTREAM_RUN_ID}" ]]; then
    echo "Upstream run ${UPSTREAM_RUN_ID} (${UPSTREAM_WORKFLOW}) will supply candidate artifacts."
  else
    echo "::warning title=Provenance::No successful '${UPSTREAM_WORKFLOW}' run found for ${UPSTREAM_HEAD_SHA}. Pre-release artifacts will not be attached to the release."
  fi
fi

rm -f "${API_ERR}"

if [[ -z "${MERGED_PR_NUMBER}" ]]; then
  # No pull request is the normal, correct state for a commit pushed straight to
  # the branch: there is no candidate run to inherit artifacts from. Only a
  # commit that LOOKS like a merge and still did not resolve is a problem.
  SUBJECT="$(git log -1 --pretty=%s 2>/dev/null || true)"
  if [[ -n "${UPSTREAM_HEAD_SHA}" || "${SUBJECT}" =~ \(#[0-9]+\)|^Merge\  ]]; then
    echo "::warning title=Provenance::Could not resolve the merged pull request for ${GITHUB_SHA}, though the commit looks like a merge. Promotion falls back to the newest matching tag."
  else
    echo "::notice title=Provenance::${GITHUB_SHA} was pushed directly, not merged from a pull request, so there is no candidate run. Promotion resolves the image by tag and the release carries notes only."
  fi
fi

CANDIDATE_SUFFIX=""
if [[ -n "${UPSTREAM_RUN_NUMBER}" && -n "${MERGED_PR_NUMBER}" ]]; then
  CANDIDATE_SUFFIX="-${UPSTREAM_RUN_NUMBER}.${MERGED_PR_NUMBER}"
fi

CANDIDATE_IMAGE_TAG=""
CANDIDATE_CHART_VERSION=""
if [[ -n "${CANDIDATE_SUFFIX}" ]]; then
  if [[ "${IGNORE_DOCKER}" != "true" && -n "${BASE_IMAGE_TAG}" ]]; then
    CANDIDATE_IMAGE_TAG="${BASE_IMAGE_TAG}${CANDIDATE_SUFFIX}"
  fi
  if [[ "${IGNORE_CHART}" != "true" && -n "${BASE_CHART_VERSION}" ]]; then
    CANDIDATE_CHART_VERSION="${BASE_CHART_VERSION}${CANDIDATE_SUFFIX}"
  fi
  echo "Exact promotion candidate: image '${CANDIDATE_IMAGE_TAG:-n/a}', chart '${CANDIDATE_CHART_VERSION:-n/a}'."
fi

{
  echo "MERGED_PR_NUMBER=${MERGED_PR_NUMBER}"
  echo "UPSTREAM_HEAD_SHA=${UPSTREAM_HEAD_SHA}"
  echo "UPSTREAM_RUN_ID=${UPSTREAM_RUN_ID}"
  echo "UPSTREAM_RUN_NUMBER=${UPSTREAM_RUN_NUMBER}"
  echo "CANDIDATE_IMAGE_TAG=${CANDIDATE_IMAGE_TAG}"
  echo "CANDIDATE_CHART_VERSION=${CANDIDATE_CHART_VERSION}"
} | tee -a "${GITHUB_OUTPUT}"
