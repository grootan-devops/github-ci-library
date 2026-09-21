#!/usr/bin/env bash
# Point the GitOps compose file at the newly built image and push the commit.
#
# The compose file in the GitOps repository is the only record of what the
# stack is supposed to be running, so it is edited in a throwaway shallow
# clone rather than in the caller's workspace: nothing here should be able to
# leave a stray worktree or an uncommitted edit behind in the project repo.
#
# The no-change case is not an error. A redeploy of the same tag is a normal
# request, so when yq rewrites the file to what it already said, the current
# HEAD is reported as the commit and the run continues to the Komodo trigger
# instead of failing on an empty commit.
#
# NEW_IMAGE is passed in rather than recomputed: it is the exact reference the
# validate job proved resolvable in the registry, and recomputing it here from
# the same inputs would silently drift if either side changed.
#
# Runs from the caller's working directory, so REPO_DIR lands beside the
# checked-out project exactly as the inline block put it.
#
# Exit codes: 0 committed or already up to date, 1 the compose file named by
# COMPOSE_FILE does not exist in the GitOps repository.
#
# Env:
#   GITOPS_REPO     GitOps repository, <org>/<repo>
#   GITOPS_BRANCH   GitOps branch to clone and push
#   COMPOSE_FILE    path to the compose file inside that repository
#   YQ_PATH         yq path to the service image in that compose file
#   STACK_NAME      Komodo stack name, quoted into the commit message
#   GITOPS_TOKEN    token with push access to the GitOps repository
#   NEW_IMAGE       fully qualified image reference to write
#   ENVIRONMENT     target environment, carried for parity with the caller
#                   (default: empty)
#
# Runner-provided: GITHUB_ENV, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, RUNNER_TEMP.
#
# Outputs: commit_sha, previous_image
set -euo pipefail

: "${GITOPS_REPO:?GITOPS_REPO must be set}"
: "${GITOPS_BRANCH:?GITOPS_BRANCH must be set}"
: "${YQ_PATH:?YQ_PATH must be set}"
# Not guarded: an empty COMPOSE_FILE already lands on the `-f` branch below,
# which reports what the GitOps repository does contain. A guard here would
# replace that with a bare shell message.
: "${COMPOSE_FILE:=}"
: "${STACK_NAME:?STACK_NAME must be set}"
: "${GITOPS_TOKEN:?GITOPS_TOKEN must be set}"
: "${NEW_IMAGE:?NEW_IMAGE must be set}"
: "${ENVIRONMENT:=}"

REPO_DIR="_gitops_worktree"

# The push token stays off the git command line and out of the clone. Embedded
# in the URL it would be an argv element readable from /proc while the clone
# runs, and git would then write it verbatim as remote.origin.url into
# ${REPO_DIR}/.git/config -- a plaintext push-capable credential sitting in the
# caller's workspace for every later step of the job, which GitHub's secret
# masking does not redact once it is read back out of a file. Instead git reads
# it from a 0600 file outside the workspace, and the trap removes both that file
# and the worktree however this script exits.
CRED_FILE="$(mktemp "${RUNNER_TEMP}/gitops-credentials.XXXXXX")"
# The empty helper first clears whatever the runner image or a previous
# actions/checkout already configured: `git -c credential.helper=` appends
# rather than replaces, so without the reset an inherited helper answers first
# and the clone authenticates as some other identity.
GIT_CRED_OPTS=(-c credential.helper= -c "credential.helper=store --file=${CRED_FILE}")
trap 'rm -rf "${REPO_DIR}" "${CRED_FILE}"' EXIT

# Still cleared up front: a run killed before its trap fired leaves one behind.
rm -rf "${REPO_DIR}"

printf 'https://x-access-token:%s@github.com\n' "${GITOPS_TOKEN}" > "${CRED_FILE}"

echo "Cloning GitOps repo '${GITOPS_REPO}' (branch: ${GITOPS_BRANCH})..."
git "${GIT_CRED_OPTS[@]}" \
  clone --depth 1 --branch "${GITOPS_BRANCH}" \
  "https://github.com/${GITOPS_REPO}.git" "${REPO_DIR}"

TARGET_COMPOSE="${REPO_DIR}/${COMPOSE_FILE}"
if [[ ! -f "${TARGET_COMPOSE}" ]]; then
  echo "::error::Compose file '${COMPOSE_FILE}' not found in GitOps repository."
  {
    echo "## 🦎 Komodo GitOps Deployment Summary"
    echo ""
    echo "❌ \`${COMPOSE_FILE}\` does not exist in \`${GITOPS_REPO}\` on \`${GITOPS_BRANCH}\`, so nothing was committed and the stack is unchanged. These are at the repository root:"
    echo ""
    echo '```'
    ls -1 "${REPO_DIR}"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

CURRENT_IMAGE="$(yq -r "${YQ_PATH}" "${TARGET_COMPOSE}" 2>/dev/null || echo "")"
echo "Current image: ${CURRENT_IMAGE:-<empty>}"
echo "New image:     ${NEW_IMAGE}"

# strenv, not interpolation: NEW_IMAGE comes from the caller's image-tag input,
# and a double quote in it would close the yq string and leave the rest to be
# parsed as yq syntax -- enough to write an unrelated key into the compose file
# that then gets committed and pushed. Exported here so strenv can read it even
# if a caller set it without exporting; unexported it would resolve to null and
# yq would quietly blank the image.
export NEW_IMAGE
yq -i "${YQ_PATH} = strenv(NEW_IMAGE)" "${TARGET_COMPOSE}"

COMMIT_SHA=""
if git -C "${REPO_DIR}" diff --quiet; then
  echo "No changes detected in ${COMPOSE_FILE}. Image is already up to date."
  COMMIT_SHA="$(git -C "${REPO_DIR}" rev-parse HEAD)"
else
  echo "Changes detected:"
  git -C "${REPO_DIR}" diff "${COMPOSE_FILE}"

  git -C "${REPO_DIR}" config user.name "github-actions[bot]"
  git -C "${REPO_DIR}" config user.email "github-actions[bot]@users.noreply.github.com"
  git -C "${REPO_DIR}" add "${COMPOSE_FILE}"
  git -C "${REPO_DIR}" commit -m "chore(gitops): update ${STACK_NAME} image to ${NEW_IMAGE} [skip ci]"
  git -C "${REPO_DIR}" "${GIT_CRED_OPTS[@]}" push origin "${GITOPS_BRANCH}"
  COMMIT_SHA="$(git -C "${REPO_DIR}" rev-parse HEAD)"
  echo "Pushed GitOps commit ${COMMIT_SHA} to ${GITOPS_BRANCH}."
fi

echo "commit_sha=${COMMIT_SHA}" >> "${GITHUB_OUTPUT}"
echo "previous_image=${CURRENT_IMAGE}" >> "${GITHUB_OUTPUT}"
echo "NEW_IMAGE_REF=${NEW_IMAGE}" >> "${GITHUB_ENV}"
