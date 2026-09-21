#!/usr/bin/env bash
# Resolve the image reference this deployment will pin, after checking that
# every mandatory input and secret is present.
#
# The GitOps commit is pushed before Komodo is ever told to redeploy, so a
# value found missing after that point leaves the compose file naming an image
# the running stack was never asked to pull. Collecting every absent value
# here, before anything is cloned, keeps that half-applied state from
# happening, and names all of them in one run instead of one per retry.
#
# Deliberately no `:?` guards on the ten checked values: the MISSING list is
# the error path. It reports every absent input at once and writes the
# step-summary section the caller reads, where a guard would abort on the
# first one with a bare shell message and no summary at all.
#
# Exit codes: 0 resolved, 1 mandatory configuration missing.
#
# Env:
#   GITOPS_REPO     GitOps repository, <org>/<repo>
#   GITOPS_BRANCH   GitOps branch to update
#   COMPOSE_FILE    path to the compose file inside the GitOps repository
#   YQ_PATH         yq path to the service image in that compose file
#   KOMODO_SERVER   Komodo server URL
#   STACK_NAME      Komodo stack name to redeploy
#   KOMODO_KEY      Komodo API key
#   KOMODO_SECRET   Komodo API secret
#   IMAGE_TAG       container image tag to deploy
#   IMAGE_REPO      base container image repository
#   REGISTRY_HOST   container registry host (default: empty)
#   DEV_SUFFIX      appended to IMAGE_REPO for development artifacts
#                   (default: empty)
#
# Runner-provided: GITHUB_OUTPUT, GITHUB_STEP_SUMMARY.
#
# Outputs: new_image  the fully qualified image reference to deploy
set -euo pipefail

: "${GITOPS_REPO:=}"
: "${GITOPS_BRANCH:=}"
: "${COMPOSE_FILE:=}"
: "${YQ_PATH:=}"
: "${KOMODO_SERVER:=}"
: "${STACK_NAME:=}"
: "${KOMODO_KEY:=}"
: "${KOMODO_SECRET:=}"
: "${IMAGE_TAG:=}"
: "${IMAGE_REPO:=}"
: "${REGISTRY_HOST:=}"
: "${DEV_SUFFIX:=}"

MISSING=()

if [[ -z "${GITOPS_REPO}" ]]; then
  MISSING+=("gitops-repo")
fi

if [[ -z "${GITOPS_BRANCH}" ]]; then
  MISSING+=("gitops-branch")
fi

if [[ -z "${COMPOSE_FILE}" ]]; then
  MISSING+=("gitops-compose-file")
fi

if [[ -z "${YQ_PATH}" ]]; then
  MISSING+=("gitops-service-image-yq-path")
fi

if [[ -z "${KOMODO_SERVER}" ]]; then
  MISSING+=("komodo-server (or vars.KOMODO_SERVER)")
fi

if [[ -z "${STACK_NAME}" ]]; then
  MISSING+=("komodo-stack-name")
fi

if [[ -z "${KOMODO_KEY}" ]]; then
  MISSING+=("KOMODO_API_KEY secret")
fi

if [[ -z "${KOMODO_SECRET}" ]]; then
  MISSING+=("KOMODO_API_SECRET secret")
fi

if [[ -z "${IMAGE_TAG}" ]]; then
  MISSING+=("image-tag")
fi

if [[ -z "${IMAGE_REPO}" ]]; then
  MISSING+=("image-repository")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "::error::[HARD FAILURE] Missing mandatory deployment configuration: ${MISSING[*]}"
  {
    echo "### 🔎 Deployment prerequisites"
    echo ""
    echo "❌ Nothing was deployed. These inputs or secrets are not configured:"
    echo ""
    # shellcheck disable=SC2016 # backticks are markdown, not command substitution
    printf -- '- `%s`\n' "${MISSING[@]}"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi

NEW_IMAGE="${REGISTRY_HOST}/${IMAGE_REPO}${DEV_SUFFIX}:${IMAGE_TAG}"

{
  echo "new_image=${NEW_IMAGE}"
} | tee -a "${GITHUB_OUTPUT}"
