#!/usr/bin/env bash
# Resolve every version, tag, registry and repository this pipeline will use.
#
# Runs once, first, for the whole pipeline: the application version is read from
# whichever manifest the project actually ships, the chart and image targets are
# derived from it, and the result is written to GITHUB_OUTPUT so that no
# downstream job recomputes any of it and no caller has to pass it in. A release
# branch publishes to the production repositories under the bare version; every
# other run publishes to the dev repositories under a run-scoped candidate
# suffix, so a candidate can never overwrite a published artifact.
#
# Exit codes: 0 resolved, 1 no discoverable version (a summary explains which
# manifests were searched).
#
# Env:
#   PROJECT_PATH                  project root, "." outside a monorepo
#   CHART_DIR                     chart directory, relative to PROJECT_PATH or the repo root
#   CHART_FILE                    chart manifest filename, normally Chart.yaml
#   DOCKERFILE                    Dockerfile filename, relative to PROJECT_PATH or the repo root
#   IGNORE_CHART_INPUT            auto | true | false (default: empty, treated as auto)
#   IGNORE_DOCKER_INPUT           auto | true | false (default: empty, treated as auto)
#   INPUT_TAG                     explicit version override (default: empty, discover instead)
#   REGISTRY_HOST                 vars.IMAGE_REGISTRY (default: empty)
#   IMAGE_REPOSITORY_INPUT        vars.IMAGE_REPOSITORY (default: empty)
#   IMAGE_DEV_REPOSITORY_SUFFIX   candidate image repository suffix (default: empty, then /dev)
#   CHART_REPOSITORY_INPUT        vars.CHART_REPOSITORY (default: empty)
#   CHART_DEV_REPOSITORY_SUFFIX   candidate chart repository suffix (default: empty)
#   RELEASE_VERSION_SUFFIX        suffix appended to the release tag (default: empty)
#   MASTER_BRANCH_REGEX           protected branches treated as release branches
#                                 (default: empty; the workflow passes ^(.*/)?master$)
#   DEFAULT_BRANCH                the repository default branch (default: empty)
#   PR_NUMBER                     pull request number on a pull_request run (default: empty)
#   REF_PROTECTED                 github.ref_protected (default: false)
set -euo pipefail

: "${PROJECT_PATH:?PROJECT_PATH must be set}"
: "${CHART_DIR:?CHART_DIR must be set}"
: "${CHART_FILE:?CHART_FILE must be set}"
: "${DOCKERFILE:?DOCKERFILE must be set}"

: "${IGNORE_CHART_INPUT:=}"
: "${IGNORE_DOCKER_INPUT:=}"
: "${INPUT_TAG:=}"
: "${REGISTRY_HOST:=}"
: "${IMAGE_REPOSITORY_INPUT:=}"
: "${IMAGE_DEV_REPOSITORY_SUFFIX:=}"
: "${CHART_REPOSITORY_INPUT:=}"
: "${CHART_DEV_REPOSITORY_SUFFIX:=}"
: "${RELEASE_VERSION_SUFFIX:=}"
: "${MASTER_BRANCH_REGEX:=}"
: "${DEFAULT_BRANCH:=}"
: "${PR_NUMBER:=}"
: "${REF_PROTECTED:=false}"

CHART_FILE_PATH="${PROJECT_PATH}/${CHART_DIR}/${CHART_FILE}"
if [[ ! -f "${CHART_FILE_PATH}" && -f "${CHART_DIR}/${CHART_FILE}" ]]; then
  CHART_FILE_PATH="${CHART_DIR}/${CHART_FILE}"
fi

DOCKERFILE_PATH="${PROJECT_PATH}/${DOCKERFILE}"
if [[ ! -f "${DOCKERFILE_PATH}" && -f "${DOCKERFILE}" ]]; then
  DOCKERFILE_PATH="${DOCKERFILE}"
fi

resolve_ignore() {
  local VALUE="${1,,}" DETECTED="${2}"
  case "${VALUE}" in
    true|false) echo "${VALUE}" ;;
    auto|"")    echo "${DETECTED}" ;;
    *)
      echo "::error::Invalid value '${1}'. Expected one of: auto, true, false." >&2
      return 1
      ;;
  esac
}

CHART_DETECTED="true"
if [[ -f "${CHART_FILE_PATH}" ]]; then
  CHART_DETECTED="false"
fi
DOCKER_DETECTED="true"
if [[ -f "${DOCKERFILE_PATH}" ]]; then
  DOCKER_DETECTED="false"
fi

IGNORE_CHART="$(resolve_ignore "${IGNORE_CHART_INPUT}" "${CHART_DETECTED}")"
IGNORE_DOCKER="$(resolve_ignore "${IGNORE_DOCKER_INPUT}" "${DOCKER_DETECTED}")"

echo "Chart.yaml:  ${CHART_FILE_PATH} (ignore-chart=${IGNORE_CHART})"
echo "Dockerfile:  ${DOCKERFILE_PATH} (ignore-docker=${IGNORE_DOCKER})"

HAS_DOCKERFILE="false"
if [[ "${IGNORE_DOCKER}" != "true" && -f "${DOCKERFILE_PATH}" ]]; then
  HAS_DOCKERFILE="true"
fi

CHART_NAME=""
CHART_FILE_VERSION=""
CHART_FILE_APP_VERSION=""
if [[ "${IGNORE_CHART}" != "true" && -f "${CHART_FILE_PATH}" ]]; then
  CHART_NAME="$(yq -r '.name // ""' "${CHART_FILE_PATH}")"
  CHART_FILE_VERSION="$(yq -r '.version // ""' "${CHART_FILE_PATH}")"
  CHART_FILE_APP_VERSION="$(yq -r '.appVersion // ""' "${CHART_FILE_PATH}")"
fi

LANG_VERSION=""
LANG_SOURCE=""
# A VERSION file is the only manifest a non-language project has -- a skills or
# docs repository ships no package.json, pyproject.toml or pom.xml, and without
# this it cannot resolve a version at all. Checked first: where a project has
# both, the VERSION file is the deliberate statement.
if [[ -s "${PROJECT_PATH}/VERSION" ]]; then
  LANG_VERSION="$(tr -d '[:space:]' < "${PROJECT_PATH}/VERSION")"
  LANG_SOURCE="VERSION"
fi
if [[ -z "${LANG_VERSION}" && -f "${PROJECT_PATH}/package.json" ]]; then
  LANG_VERSION="$(jq -r '.version // empty' "${PROJECT_PATH}/package.json")"
  LANG_SOURCE="package.json"
fi
if [[ -z "${LANG_VERSION}" && -f "${PROJECT_PATH}/pyproject.toml" ]]; then
  LANG_VERSION="$(yq -p toml -r '.project.version // .tool.poetry.version // ""' "${PROJECT_PATH}/pyproject.toml" 2>/dev/null || true)"
  if [[ -z "${LANG_VERSION}" || "${LANG_VERSION}" == "null" ]]; then
    LANG_VERSION="$(grep -E '^version[[:space:]]*=[[:space:]]*"' "${PROJECT_PATH}/pyproject.toml" \
      | head -n1 | sed -E 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/' || true)"
  fi
  LANG_SOURCE="pyproject.toml"
fi
if [[ -z "${LANG_VERSION}" && -f "${PROJECT_PATH}/pom.xml" ]]; then
  LANG_VERSION="$(yq -p xml -r '.project.version // .project.parent.version // ""' "${PROJECT_PATH}/pom.xml" 2>/dev/null || true)"
  # shellcheck disable=SC2016 # the pattern matches a literal Maven placeholder
  if [[ -z "${LANG_VERSION}" || "${LANG_VERSION}" == "null" || "${LANG_VERSION}" == *'${'* ]]; then
    LANG_VERSION="$(mvn -f "${PROJECT_PATH}/pom.xml" help:evaluate \
      -Dexpression=project.version -q -DforceStdout --batch-mode 2>/dev/null | tail -n1 || true)"
  fi
  LANG_SOURCE="pom.xml"
fi
if [[ "${LANG_VERSION}" == "null" ]]; then
  LANG_VERSION=""
fi

if [[ -n "${LANG_VERSION}" ]]; then
  echo "Discovered application version ${LANG_VERSION} from ${LANG_SOURCE}."
  RELEASE_VERSION="${LANG_VERSION}"
  CHART_RELEASE_VERSION="${LANG_VERSION}"
elif [[ -n "${CHART_FILE_VERSION}" || -n "${CHART_FILE_APP_VERSION}" ]]; then
  CHART_RELEASE_VERSION="${CHART_FILE_VERSION}"
  if [[ "${HAS_DOCKERFILE}" == "true" ]]; then
    echo "Discovered application version from Chart.yaml .appVersion (Dockerfile present)."
    RELEASE_VERSION="${CHART_FILE_APP_VERSION}"
  else
    echo "Discovered application version from Chart.yaml .version (no Dockerfile)."
    RELEASE_VERSION="${CHART_FILE_VERSION}"
  fi
else
  RELEASE_VERSION=""
  CHART_RELEASE_VERSION=""
fi

if [[ -n "${INPUT_TAG}" ]]; then
  echo "Explicit tag override: ${INPUT_TAG}"
  RELEASE_VERSION="${INPUT_TAG}"
  CHART_RELEASE_VERSION="${INPUT_TAG}"
fi

if [[ -z "${RELEASE_VERSION}" ]]; then
  echo "::error title=Version discovery::No version found. Provide VERSION, Chart.yaml, package.json, pyproject.toml, pom.xml, or the 'tag' input."
  {
    echo "## 🚀 CI/CD Version & Target Discovery"
    echo ""
    echo "❌ No application version could be discovered, so there is nothing to tag, build or publish."
    echo ""
    echo "| Manifest | Looked for | Present |"
    echo "|---|---|---|"
    for CANDIDATE in VERSION package.json pyproject.toml pom.xml; do
      if [[ -f "${PROJECT_PATH}/${CANDIDATE}" ]]; then
        FOUND="yes, but it declares no version"
      else
        FOUND="no"
      fi
      echo "| \`${CANDIDATE}\` | \`${PROJECT_PATH}/${CANDIDATE}\` | ${FOUND} |"
    done
    if [[ -f "${CHART_FILE_PATH}" ]]; then
      FOUND="yes, but it declares no version/appVersion"
    else
      FOUND="no"
    fi
    echo "| \`${CHART_FILE}\` | \`${CHART_FILE_PATH}\` | ${FOUND} |"
    echo ""
    echo "Add a version to one of them, or pass the \`tag\` input explicitly."
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit 1
fi
if [[ -z "${CHART_RELEASE_VERSION}" ]]; then
  CHART_RELEASE_VERSION="${RELEASE_VERSION}"
fi

IS_RELEASE_BRANCH="false"
if [[ "${GITHUB_REF}" == "refs/heads/${DEFAULT_BRANCH}" ]]; then
  IS_RELEASE_BRANCH="true"
elif [[ "${GITHUB_REF}" == refs/heads/* && "${REF_PROTECTED}" == "true" \
        && "${GITHUB_REF_NAME}" =~ ${MASTER_BRANCH_REGEX} ]]; then
  IS_RELEASE_BRANCH="true"
fi

IS_MANUAL="false"
case "${GITHUB_EVENT_NAME}" in
  workflow_dispatch|repository_dispatch|schedule) IS_MANUAL="true" ;;
esac

if [[ "${IS_RELEASE_BRANCH}" == "true" && "${IS_MANUAL}" == "true" ]]; then
  echo "::warning title=Manual run::Manual trigger on release branch '${GITHUB_REF_NAME}' - forcing a candidate suffix and the dev repositories so a published artifact cannot be overwritten."
  VERSION_SUFFIX="-${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}"
  IS_RELEASE="false"
elif [[ "${IS_RELEASE_BRANCH}" == "true" ]]; then
  VERSION_SUFFIX=""
  IS_RELEASE="true"
elif [[ "${GITHUB_EVENT_NAME}" == "pull_request" ]]; then
  VERSION_SUFFIX="-${GITHUB_RUN_NUMBER}.${PR_NUMBER}"
  IS_RELEASE="false"
else
  VERSION_SUFFIX="-${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}"
  IS_RELEASE="false"
fi

IMAGE_REPO="${IMAGE_REPOSITORY_INPUT}"
IMAGE_DEV_SUFFIX="${IMAGE_DEV_REPOSITORY_SUFFIX:-/dev}"
# Docker Hub has no nested repositories, so `<repo>/dev` is not a valid target.
case "${REGISTRY_HOST}" in
  docker.io|index.docker.io|registry-1.docker.io)
    NORMALISED_DEV_SUFFIX="${IMAGE_DEV_SUFFIX//\//-}"
    if [[ "${NORMALISED_DEV_SUFFIX}" != "${IMAGE_DEV_SUFFIX}" ]]; then
      echo "::notice title=Dev repository::Docker Hub does not support nested repositories. Using '${NORMALISED_DEV_SUFFIX}' instead of '${IMAGE_DEV_SUFFIX}' for development images."
    fi
    IMAGE_DEV_SUFFIX="${NORMALISED_DEV_SUFFIX}"
    ;;
esac
IMAGE_DEV_REPO="${IMAGE_REPO}${IMAGE_DEV_SUFFIX}"
CHART_REPO="${CHART_REPOSITORY_INPUT}"
CHART_DEV_SUFFIX="${CHART_DEV_REPOSITORY_SUFFIX:-/dev}"
# Docker Hub's Helm OCI layout is different from its image layout: the push
# target is the namespace root and Helm appends the chart name itself. There
# is therefore no separate chart development repository on Docker Hub. The
# candidate version suffix already separates candidate artifacts from stable
# releases in the shared chart repository.
case "${REGISTRY_HOST}" in
  docker.io|index.docker.io|registry-1.docker.io)
    if [[ -n "${CHART_DEV_SUFFIX}" ]]; then
      echo "::notice title=Dev chart repository::Docker Hub stores candidate and release Helm charts in the same namespace-root repository; the chart version distinguishes them. Ignoring chart development suffix '${CHART_DEV_SUFFIX}'."
    fi
    CHART_DEV_SUFFIX=""
    ;;
esac
CHART_DEV_REPO="${CHART_REPO}${CHART_DEV_SUFFIX}"

if [[ "${IS_RELEASE}" == "true" ]]; then
  IMAGE_PUSH_REPOSITORY="${IMAGE_REPO}"
  CHART_PUSH_REPOSITORY="${CHART_REPO}"
else
  IMAGE_PUSH_REPOSITORY="${IMAGE_DEV_REPO}"
  CHART_PUSH_REPOSITORY="${CHART_DEV_REPO}"
fi

TAG="${RELEASE_VERSION}"
if [[ -n "${RELEASE_VERSION_SUFFIX}" ]]; then
  TAG="${RELEASE_VERSION}-${RELEASE_VERSION_SUFFIX}"
fi

IMAGE_PUSH_TAG="${RELEASE_VERSION}${VERSION_SUFFIX}"
CHART_PUSH_VERSION="${CHART_RELEASE_VERSION}${VERSION_SUFFIX}"
CHART_APP_VERSION="${IMAGE_PUSH_TAG}"

MAJOR_VERSION="$(grep -Eo '^[0-9]+' <<<"${IMAGE_PUSH_TAG}" || true)"
MINOR_VERSION="$(grep -Eo '^[0-9]+\.[0-9]+' <<<"${IMAGE_PUSH_TAG}" || true)"

{
  echo "REGISTRY=${REGISTRY_HOST}"
  echo "TAG=${TAG}"
  echo "RELEASE_VERSION=${RELEASE_VERSION}"
  echo "VERSION_SUFFIX=${VERSION_SUFFIX}"
  echo "IS_RELEASE=${IS_RELEASE}"
  echo "IGNORE_CHART=${IGNORE_CHART}"
  echo "IGNORE_DOCKER=${IGNORE_DOCKER}"
  echo "IMAGE_TAG=${RELEASE_VERSION}"
  echo "IMAGE_PUSH_TAG=${IMAGE_PUSH_TAG}"
  echo "IMAGE_REPOSITORY=${IMAGE_REPO}"
  echo "IMAGE_DEV_REPOSITORY=${IMAGE_DEV_REPO}"
  echo "IMAGE_PUSH_REPOSITORY=${IMAGE_PUSH_REPOSITORY}"
  echo "CHART_NAME=${CHART_NAME}"
  echo "CHART_VERSION=${CHART_RELEASE_VERSION}"
  echo "CHART_APP_VERSION=${CHART_APP_VERSION}"
  echo "CHART_PUSH_VERSION=${CHART_PUSH_VERSION}"
  echo "CHART_REPOSITORY=${CHART_REPO}"
  echo "CHART_DEV_REPOSITORY=${CHART_DEV_REPO}"
  echo "CHART_PUSH_REPOSITORY=${CHART_PUSH_REPOSITORY}"
  echo "CHART_DIR=${CHART_DIR}"
  echo "PROJECT_PATH=${PROJECT_PATH}"
  echo "MAJOR_VERSION=${MAJOR_VERSION}"
  echo "MINOR_VERSION=${MINOR_VERSION}"
} | tee -a "${GITHUB_OUTPUT}"
