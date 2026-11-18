#!/usr/bin/env bash
# Shared release promotion for docker/promote-image.sh and buildah/promote-image.sh.
# Source this file after `crane auth login`; it performs no I/O on load.
#
# A release ships the exact image its pull request built and scanned, and
# nothing else:
#
# - The candidate is named, never searched for. init.yml names it from the
#   merged pull request's successful run. An empty name (a direct push, a pull
#   request with no successful run, a caller that does not pass candidate-tag)
#   or a name the registry does not hold refuses the release: every pull
#   request of a version publishes the same `<tag>-<run>.<n>` shape, so the
#   highest-sorting one is a guess that can ship an unscanned or rejected build.
# - `crane copy` keeps the digest, so the released digest IS the scanned one.
# - A production tag that already holds that digest is a re-run and is left as
#   it is; one that holds any other digest refuses the release.
# - `latest`, MAJOR and MINOR move only when no higher release is published in
#   their range, so a hotfix on an older line never rolls them back.
#
# Callers set: REGISTRY_HOST, DEV_REPOSITORY, PROD_REPOSITORY, TAG,
# CANDIDATE_TAG, IMAGE_INFO_FILE_NAME, GITHUB_STEP_SUMMARY.
# shellcheck disable=SC2153 # TAG and the rest come from the calling script's environment.

promotion_summary() {
  {
    echo "### 🐳 Container Image"
    echo ""
    printf '%s\n' "$@"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
}

require_exact_candidate() {
  local DEV_IMAGE="$1"
  if [[ -z "${CANDIDATE_TAG}" ]]; then
    echo "::error title=Image promote::No candidate was named for ${TAG}, so nothing is promoted. A release only ships the image its merged pull request built and scanned."
    promotion_summary \
      "❌ \`${TAG}\` was not promoted: no candidate was named. init.yml names it from the merged pull request's successful run, so a direct push, a pull request whose run did not succeed, or a release caller that does not pass \`candidate-tag\` has none. The production tag is unchanged." \
      "" \
      "Merge through a pull request whose run succeeded, or re-run that pull request's workflow and then this one. A monorepo child passes \`upstream-workflow\` to init.yml."
    return 1
  fi
  if ! crane manifest "${DEV_IMAGE}:${CANDIDATE_TAG}" >/dev/null 2>&1; then
    echo "::error title=Image promote::Candidate ${DEV_IMAGE}:${CANDIDATE_TAG} is not in the registry, so nothing is promoted."
    promotion_summary \
      "❌ \`${TAG}\` was not promoted: the named candidate \`${DEV_IMAGE}:${CANDIDATE_TAG}\` is not in the registry, or the registry could not be read. No other candidate is tried. The production tag is unchanged." \
      "" \
      "Tags that do exist in the candidate repository:" \
      "" \
      '```' \
      "$(crane ls "${DEV_IMAGE}" 2>&1 | tail -n 20 || echo "(the candidate repository could not be listed either)")" \
      '```'
    return 1
  fi
}

# Sets RELEASE_STATE to "absent" or "same"; returns 1 when the tag holds
# another digest. A lookup failure counts as absent, as in
# checks/image-tag-check.sh: the copy that follows surfaces a registry that
# cannot be reached.
existing_release_state() {
  local PROD_REF="$1" SOURCE_DIGEST="$2" PROD_DIGEST
  RELEASE_STATE="absent"
  if ! PROD_DIGEST="$(crane digest "${PROD_REF}" 2>/dev/null)"; then
    return 0
  fi
  if [[ "${PROD_DIGEST}" == "${SOURCE_DIGEST}" ]]; then
    RELEASE_STATE="same"
    return 0
  fi
  echo "::error title=Image promote::${PROD_REF} already holds ${PROD_DIGEST}, not the scanned candidate ${SOURCE_DIGEST}. A published release is never overwritten."
  promotion_summary \
    "❌ \`${PROD_REF}\` already holds \`${PROD_DIGEST}\`, a different image from the scanned candidate \`${SOURCE_DIGEST}\`. A published release is never overwritten: bump the version."
  return 1
}

# The highest X.Y.Z among the arguments, compared by version.
highest_core() {
  printf '%s\n' "$@" | sed '/^$/d' | sort -V | tail -n1
}

move_floating_aliases() {
  local PROD_IMAGE="$1" CORE TAGS CORES MAJOR MINOR ALIAS RANGE TOP
  ALIASES_MOVED=()
  ALIASES_KEPT=()
  CORE="$(grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+' <<<"${TAG}" || true)"
  if [[ -z "${CORE}" ]]; then
    echo "::notice title=Image promote::${TAG} is not a semantic version, so latest, MAJOR and MINOR are left where they are."
    return 0
  fi
  if ! TAGS="$(crane ls "${PROD_IMAGE}" 2>&1)"; then
    echo "${TAGS}" >&2
    echo "::error title=Image promote::Could not list ${PROD_IMAGE}, so the floating tags cannot be ordered safely. ${TAG} is published; re-run to place the aliases."
    promotion_summary "❌ \`${PROD_IMAGE}:${TAG}\` is published, but the repository could not be listed, so \`latest\`, MAJOR and MINOR were not moved. A re-run skips the copy and places them."
    return 1
  fi
  # Releases only: a `<x.y.z>-<run>.<n>` candidate sharing the repository is
  # not a release and must not hold the aliases back.
  CORES="$(grep -Ev '^v?[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$' <<<"${TAGS}" \
    | grep -Eo '^v?[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' | sort -uV || true)"
  MAJOR="${CORE%%.*}"
  MINOR="${CORE%.*}"
  for ALIAS in latest "${MAJOR}" "${MINOR}"; do
    case "${ALIAS}" in
      latest) RANGE="${CORES}" ;;
      "${MAJOR}") RANGE="$(grep -E "^${MAJOR}\." <<<"${CORES}" || true)" ;;
      *) RANGE="$(grep -E "^${MINOR//./\\.}\." <<<"${CORES}" || true)" ;;
    esac
    TOP="$(highest_core "${RANGE}" "${CORE}")"
    if [[ "${TOP}" == "${CORE}" ]]; then
      crane tag "${PROD_IMAGE}:${TAG}" "${ALIAS}"
      ALIASES_MOVED+=("${ALIAS}")
    else
      echo "Keeping ${ALIAS} on ${TOP}: it is higher than ${CORE}."
      ALIASES_KEPT+=("${ALIAS} (${TOP} is higher)")
    fi
  done
}

join_code() {
  local OUT="" ITEM
  for ITEM in "$@"; do
    OUT+="${OUT:+, }\`${ITEM}\`"
  done
  printf '%s' "${OUT:-none}"
}

promote_candidate_image() {
  local DEV_IMAGE="${REGISTRY_HOST}/${DEV_REPOSITORY}"
  local PROD_IMAGE="${REGISTRY_HOST}/${PROD_REPOSITORY}"
  local SOURCE SOURCE_DIGEST COPY_OUTPUT PROD_DIGEST

  require_exact_candidate "${DEV_IMAGE}" || return 1
  SOURCE="${DEV_IMAGE}:${CANDIDATE_TAG}"
  SOURCE_DIGEST="$(crane digest "${SOURCE}")"
  existing_release_state "${PROD_IMAGE}:${TAG}" "${SOURCE_DIGEST}" || return 1

  if [[ "${RELEASE_STATE}" == "same" ]]; then
    echo "${PROD_IMAGE}:${TAG} already holds the scanned candidate ${SOURCE_DIGEST}; skipping the copy."
  else
    echo "📦 Copying ${SOURCE} (${SOURCE_DIGEST}) to ${PROD_IMAGE}:${TAG}"
    if ! COPY_OUTPUT="$(crane copy "${SOURCE}" "${PROD_IMAGE}:${TAG}" 2>&1)"; then
      echo "${COPY_OUTPUT}" >&2
      echo "::error title=Image promote::${PROD_IMAGE}:${TAG} was refused by the registry."
      promotion_summary \
        "❌ \`${PROD_IMAGE}:${TAG}\` was refused. The scanned candidate \`${SOURCE}\` (\`${SOURCE_DIGEST}\`) is unchanged, so a re-run can promote it once this is fixed. crane reported:" \
        "" \
        '```' \
        "$(tail -n 30 <<<"${COPY_OUTPUT}")" \
        '```'
      return 1
    fi
  fi

  PROD_DIGEST="$(crane digest "${PROD_IMAGE}:${TAG}")"
  if [[ "${PROD_DIGEST}" != "${SOURCE_DIGEST}" ]]; then
    echo "::error title=Image promote::${PROD_IMAGE}:${TAG} resolves to ${PROD_DIGEST} after the copy, not ${SOURCE_DIGEST}."
    promotion_summary "❌ \`${PROD_IMAGE}:${TAG}\` resolves to \`${PROD_DIGEST}\` after the copy, not the scanned \`${SOURCE_DIGEST}\`. The aliases were not moved."
    return 1
  fi

  move_floating_aliases "${PROD_IMAGE}" || return 1

  {
    echo "### 🐳 Container Image"
    echo ""
    echo "| Property | Value |"
    echo "|---|---|"
    echo "| **Promoted from** | \`${SOURCE}\` |"
    echo "| **Released as** | \`${PROD_IMAGE}:${TAG}\` |"
    echo "| **Digest** | \`${PROD_DIGEST}\` (the scanned candidate's) |"
    echo "| **Aliases** | $(join_code "${ALIASES_MOVED[@]}") |"
    if [[ ${#ALIASES_KEPT[@]} -gt 0 ]]; then
      echo "| **Aliases left on a higher release** | $(join_code "${ALIASES_KEPT[@]}") |"
    fi
    if [[ "${RELEASE_STATE}" == "same" ]]; then
      echo "| **Re-run** | The tag already held this digest; the copy was skipped. |"
    fi
    echo ""
  } > "${IMAGE_INFO_FILE_NAME}"
  cat "${IMAGE_INFO_FILE_NAME}" >> "${GITHUB_STEP_SUMMARY}"
}
