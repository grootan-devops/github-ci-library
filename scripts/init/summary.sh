#!/usr/bin/env bash
# Write the run's resolved version, targets and promotion source to the job summary.
#
# Reporting only: everything here was already decided and published to
# GITHUB_OUTPUT by the resolve step. It exists so that a reader of the run can
# see, without opening a log, which tag was cut, whether it is a release or a
# candidate, where the image and chart are being pushed, and -- on a release --
# which pull request and upstream run the promoted artifacts come from. The
# failure paths of the earlier steps write their own summary section, so this
# one only runs once a version has been resolved.
#
# Exit codes: 0 always.
#
# Env:
#   IGNORE_CHART              "true" when this run publishes no chart (default: empty)
#   IGNORE_DOCKER             "true" when this run publishes no image (default: empty)
#   IS_RELEASE                "true" on a production release (default: empty)
#   PR_NUMBER                 pull request number on a pull_request run (default: empty)
#   TAG                       resolved release tag (default: empty)
#   VERSION_SUFFIX            candidate suffix, empty on a release (default: empty)
#   IMAGE_REGISTRY            image registry host (default: empty)
#   IMAGE_PUSH_TAG            image tag this run publishes (default: empty)
#   IMAGE_PUSH_REPOSITORY     image repository this run pushes to (default: empty)
#   IMAGE_REPOSITORY          production image repository (default: empty)
#   CHART_PUSH_VERSION        chart version this run publishes (default: empty)
#   CHART_REGISTRY            chart registry host (default: empty)
#   CHART_PUSH_REPOSITORY     chart repository this run pushes to (default: empty)
#   CHART_REPOSITORY          production chart repository (default: empty)
#   MERGED_PR_NUMBER          pull request this release commit came from (default: empty)
#   UPSTREAM_HEAD_SHA         that pull request's head commit (default: empty)
#   UPSTREAM_RUN_ID           run that built the candidate artifacts (default: empty)
#   CANDIDATE_IMAGE_TAG       exact candidate image tag to promote (default: empty)
#   CANDIDATE_CHART_VERSION   exact candidate chart version to promote (default: empty)
set -euo pipefail

: "${IGNORE_CHART:=}"
: "${IGNORE_DOCKER:=}"
: "${IS_RELEASE:=}"
: "${PR_NUMBER:=}"
: "${TAG:=}"
: "${VERSION_SUFFIX:=}"
: "${IMAGE_REGISTRY:=}"
: "${IMAGE_PUSH_TAG:=}"
: "${IMAGE_PUSH_REPOSITORY:=}"
: "${IMAGE_REPOSITORY:=}"
: "${CHART_PUSH_VERSION:=}"
: "${CHART_REGISTRY:=}"
: "${CHART_PUSH_REPOSITORY:=}"
: "${CHART_REPOSITORY:=}"
: "${MERGED_PR_NUMBER:=}"
: "${UPSTREAM_HEAD_SHA:=}"
: "${UPSTREAM_RUN_ID:=}"
: "${CANDIDATE_IMAGE_TAG:=}"
: "${CANDIDATE_CHART_VERSION:=}"

case "${GITHUB_EVENT_NAME}" in
  workflow_dispatch) TRIGGER="Manual" ;;
  pull_request)      TRIGGER="Pull request #${PR_NUMBER}" ;;
  push)              TRIGGER="Push to \`${GITHUB_REF_NAME}\`" ;;
  schedule)          TRIGGER="Schedule" ;;
  *)                 TRIGGER="${GITHUB_EVENT_NAME}" ;;
esac

WANT_IMAGE=false
if [[ "${IGNORE_DOCKER}" != "true" ]]; then
  WANT_IMAGE=true
fi
WANT_CHART=false
if [[ "${IGNORE_CHART}" != "true" ]]; then
  WANT_CHART=true
fi

{
  echo "## 🚀 Version & Targets"
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  echo "| **Trigger** | ${TRIGGER} |"
  echo "| **Release tag** | \`${TAG}\` |"
  if [[ "${IS_RELEASE}" == "true" ]]; then
    echo "| **Build type** | 🚀 Production release |"
  else
    echo "| **Build type** | 🔍 Candidate \`${VERSION_SUFFIX}\` |"
  fi
  if [[ "${WANT_IMAGE}" == "true" ]]; then
    echo "| **Image tag** | \`${IMAGE_PUSH_TAG}\` |"
  fi
  if [[ "${WANT_CHART}" == "true" ]]; then
    echo "| **Chart version** | \`${CHART_PUSH_VERSION}\` |"
  fi

  if [[ "${WANT_IMAGE}" == "true" || "${WANT_CHART}" == "true" ]]; then
    echo ""
    echo "| Artifact | Pushes to | Production |"
    echo "|---|---|---|"
    if [[ "${WANT_IMAGE}" == "true" ]]; then
      echo "| Image | \`${IMAGE_REGISTRY}/${IMAGE_PUSH_REPOSITORY}\` | \`${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}\` |"
    fi
    if [[ "${WANT_CHART}" == "true" ]]; then
      echo "| Chart | \`${CHART_REGISTRY}/${CHART_PUSH_REPOSITORY}\` | \`${CHART_REGISTRY}/${CHART_REPOSITORY}\` |"
    fi
  fi

  if [[ "${IS_RELEASE}" == "true" ]]; then
    echo ""
    echo "### 🔗 Promotion source"
    echo ""
    echo "| Property | Value |"
    echo "|---|---|"
    if [[ -n "${MERGED_PR_NUMBER}" ]]; then
      echo "| Merged pull request | [#${MERGED_PR_NUMBER}](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${MERGED_PR_NUMBER}) |"
    else
      echo "| Merged pull request | ⚠️ unresolved |"
    fi
    echo "| Upstream commit | \`${UPSTREAM_HEAD_SHA:-unresolved}\` |"
    if [[ -n "${UPSTREAM_RUN_ID}" ]]; then
      echo "| Upstream run | [${UPSTREAM_RUN_ID}](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${UPSTREAM_RUN_ID}) |"
    else
      echo "| Upstream run | ⚠️ unresolved |"
    fi
    if [[ "${WANT_IMAGE}" == "true" ]]; then
      if [[ -n "${CANDIDATE_IMAGE_TAG}" ]]; then
        echo "| Image candidate | \`${CANDIDATE_IMAGE_TAG}\` |"
      else
        echo "| Image candidate | ⚠️ unresolved, promotion searches by tag |"
      fi
    fi
    if [[ "${WANT_CHART}" == "true" ]]; then
      if [[ -n "${CANDIDATE_CHART_VERSION}" ]]; then
        echo "| Chart candidate | \`${CANDIDATE_CHART_VERSION}\` |"
      else
        echo "| Chart candidate | ⚠️ unresolved, promotion searches by version |"
      fi
    fi
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
