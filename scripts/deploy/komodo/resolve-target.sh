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
#   IMAGE_HOST, IMAGE_STABLE, IMAGE_DEV  the selected image destination: host, release
#                   and candidate repository (scripts/registry/auth.sh deploy)
#   DEV_SUFFIX      overrides the candidate suffix (default: the configured one)
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
: "${IMAGE_HOST:=}"
: "${IMAGE_STABLE:=}"
: "${IMAGE_DEV:=}"
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
  MISSING+=("komodo-server")
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

if [[ -z "${IMAGE_STABLE}" ]]; then
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


# The candidate repository to read: the selected destination's dev path, or the stable
# path plus the dev-repository-suffix input when the caller overrides it. Docker Hub has
# no nested repositories: an image suffix uses `-` there, and charts keep candidates in
# the release repository.
dev_repository() {
  local KIND="$1" HOST="$2" STABLE="$3" DEV="$4"
  if [[ -z "${DEV_SUFFIX}" ]]; then
    printf '%s\n' "${DEV}"
    return 0
  fi
  case "${HOST}" in
    docker.io|index.docker.io|registry-1.docker.io)
      if [[ "${KIND}" == "chart" ]]; then
        printf '%s\n' "${STABLE}"
      else
        printf '%s\n' "${STABLE}${DEV_SUFFIX//\//-}"
      fi
      return 0
      ;;
  esac
  printf '%s\n' "${STABLE}${DEV_SUFFIX}"
}

NEW_IMAGE="${IMAGE_HOST}/$(dev_repository image "${IMAGE_HOST}" "${IMAGE_STABLE}" "${IMAGE_DEV}"):${IMAGE_TAG}"

{
  echo "new_image=${NEW_IMAGE}"
} | tee -a "${GITHUB_OUTPUT}"
