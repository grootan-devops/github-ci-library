#!/usr/bin/env bash
# Registry handling shared by the image, chart, check, scan and deploy workflows.
#
# Destinations come from IMAGE_REPOSITORY / CHART_REPOSITORY (vars). A full ref
# (`host/path`) names its registry; a path uses IMAGE_REGISTRY / CHART_REGISTRY;
# with neither, GitHub Container Registry is used: ghcr.io/<owner>/<repo>, charts
# under /helm. Several refs (spaces or commas) publish to several registries; the
# first is the primary.
#
# Env:
#   IMAGE_REGISTRY, IMAGE_REPOSITORY, IMAGE_DEV_REPOSITORY_SUFFIX (default /dev)
#   CHART_REGISTRY, CHART_REPOSITORY, CHART_DEV_REPOSITORY_SUFFIX (default /dev)
#   REGISTRY_CONFIG          secret, YAML or JSON: <host>: {username, password, dev}
#   REGISTRY_CONFIG_PUBLIC   the same without credentials, exported by auth.sh
#   IMAGE_ / CHART_ / CHART_DEPENDENCY_REGISTRY_USERNAME / _PASSWORD
#   REGISTRY_TOKEN           github.token, for ghcr.io
#   GITHUB_ACTOR, GITHUB_REPOSITORY

registry_is_docker_hub() {
  case "${1,,}" in
    docker.io|index.docker.io|registry-1.docker.io) return 0 ;;
  esac
  return 1
}

# REF_HOST and REF_PATH of a repository ref. The first segment is a host when it has a
# dot or a port, or is localhost; otherwise REF_HOST is empty and the ref is a path.
registry_split_ref() {
  local REF="${1#oci://}" FIRST
  FIRST="${REF%%/*}"
  if [[ "${REF}" == */* && ( "${FIRST}" == *.* || "${FIRST}" == *:* || "${FIRST}" == localhost ) ]]; then
    REF_HOST="${FIRST,,}"
    REF_PATH="${REF#*/}"
  else
    REF_HOST=""
    REF_PATH="${REF}"
  fi
}

# REGISTRY_CONFIG (or, after auth.sh, its credential-free copy) as compact JSON.
registry_config_json() {
  local RAW="${REGISTRY_CONFIG:-${REGISTRY_CONFIG_PUBLIC:-}}" JSON
  if [[ -z "${RAW}" ]]; then
    echo '{}'
    return 0
  fi
  if ! JSON=$(printf '%s' "${RAW}" | yq -p=yaml -o=json -I=0 '.' 2>/dev/null) \
      || [[ "$(jq -r 'type' <<<"${JSON}")" != "object" ]]; then
    echo "::error title=Registry configuration::REGISTRY_CONFIG must map registry hosts to their settings, as YAML or JSON." >&2
    return 1
  fi
  printf '%s\n' "${JSON}"
}

# The REGISTRY_CONFIG entry for a host, as JSON (`{}` when there is none). Hosts match
# without case, and the Docker Hub names match each other.
registry_config_entry() {
  local HOST="${1,,}" HUB=false
  registry_is_docker_hub "${HOST}" && HUB=true
  registry_config_json | jq -c --arg HOST "${HOST}" --argjson HUB "${HUB}" '
    [to_entries[] | select((.key | ascii_downcase) as $KEY
      | $KEY == $HOST or ($HUB and ($KEY | IN("docker.io", "index.docker.io", "registry-1.docker.io"))))]
    | (.[0].value // {})'
}

# The candidate suffix for a host: its REGISTRY_CONFIG `dev`, else IMAGE_ or
# CHART_DEV_REPOSITORY_SUFFIX. Docker Hub has no nested repositories, so there an image
# suffix uses `-` instead of `/`, and charts keep candidates in the release repository.
registry_dev_suffix() {
  local KIND="$1" HOST="$2" ENTRY SUFFIX
  ENTRY=$(registry_config_entry "${HOST}") || return 1
  if [[ "$(jq -r 'has("dev")' <<<"${ENTRY}")" == "true" ]]; then
    jq -r '.dev // ""' <<<"${ENTRY}"
    return 0
  fi
  if [[ "${KIND}" == "chart" ]]; then
    SUFFIX="${CHART_DEV_REPOSITORY_SUFFIX:-/dev}"
  else
    SUFFIX="${IMAGE_DEV_REPOSITORY_SUFFIX:-/dev}"
  fi
  if registry_is_docker_hub "${HOST}"; then
    if [[ "${KIND}" == "chart" ]]; then
      SUFFIX=""
    else
      SUFFIX="${SUFFIX//\//-}"
    fi
  fi
  printf '%s\n' "${SUFFIX}"
}

# One line per destination, primary first: HOST<TAB>STABLE_PATH<TAB>DEV_PATH.
registry_targets() {
  local KIND="$1" LIST DEFAULT_HOST ENTRY HOST REPO SUFFIX SEEN=" " COUNT=0 OWN="${GITHUB_REPOSITORY,,}"
  if [[ "${KIND}" == "chart" ]]; then
    LIST="${CHART_REPOSITORY:-}"
    DEFAULT_HOST="${CHART_REGISTRY:-}"
  else
    LIST="${IMAGE_REPOSITORY:-}"
    DEFAULT_HOST="${IMAGE_REGISTRY:-}"
  fi
  if [[ -z "${LIST//[ ,]/}" ]]; then
    if [[ -n "${DEFAULT_HOST}" ]]; then
      echo "::error title=Registry configuration::${KIND^^}_REGISTRY is set, so ${KIND^^}_REPOSITORY must name the path." >&2
      return 1
    fi
    LIST="${OWN}"
    [[ "${KIND}" == "chart" ]] && LIST="${OWN}/helm"
  fi
  for ENTRY in ${LIST//,/ }; do
    registry_split_ref "${ENTRY}"
    HOST="${REF_HOST:-${DEFAULT_HOST:-ghcr.io}}"
    HOST="${HOST,,}"
    REPO="${REF_PATH%/}"
    if [[ -z "${REPO}" || "${HOST}" == *[[:space:]@/]* ]]; then
      echo "::error title=Registry configuration::'${ENTRY}' is not a repository ref (host/path)." >&2
      return 1
    fi
    [[ "${SEEN}" == *" ${HOST}/${REPO} "* ]] && continue
    SEEN+="${HOST}/${REPO} "
    SUFFIX=$(registry_dev_suffix "${KIND}" "${HOST}") || return 1
    printf '%s\t%s\t%s\n' "${HOST}" "${REPO}" "${REPO}${SUFFIX}"
    COUNT=$((COUNT + 1))
  done
  if [[ "${COUNT}" -eq 0 ]]; then
    echo "::error title=Registry configuration::No ${KIND} destination: set ${KIND^^}_REPOSITORY." >&2
    return 1
  fi
}

# The Docker config.json keys for a host.
registry_auth_keys() {
  if registry_is_docker_hub "$1"; then
    echo "https://index.docker.io/v1/ index.docker.io docker.io registry-1.docker.io"
  else
    echo "${1,,}"
  fi
}

# Write one Docker config.json with every credential the job needs, into DIR (default a
# new temporary directory), and export DOCKER_CONFIG, HELM_REGISTRY_CONFIG and
# REGISTRY_AUTH_FILE so docker, buildx, crane, Trivy, helm and buildah read it. For the
# same host a later source wins: GITHUB_TOKEN for ghcr.io, the IMAGE_, CHART_ and
# CHART_DEPENDENCY_REGISTRY_USERNAME/PASSWORD pairs, then REGISTRY_CONFIG.
registry_auth() {
  local DIR="${1:-}" XTRACE=false AUTHS='{}' CONFIG_JSON HOST USERNAME PASSWORD
  [[ $- == *x* ]] && XTRACE=true && set +x
  registry_auth_add() {
    local KEY TOKEN
    [[ -n "$1" && -n "$2" && -n "$3" ]] || return 0
    TOKEN=$(printf '%s:%s' "$2" "$3" | base64 | tr -d '\n')
    for KEY in $(registry_auth_keys "$1"); do
      AUTHS=$(jq -c --arg KEY "${KEY}" --arg TOKEN "${TOKEN}" '.[$KEY] = {auth: $TOKEN}' <<<"${AUTHS}")
    done
  }
  registry_auth_add ghcr.io "${GITHUB_ACTOR:-}" "${REGISTRY_TOKEN:-}"
  registry_auth_add "${IMAGE_REGISTRY:-}" "${IMAGE_REGISTRY_USERNAME:-}" "${IMAGE_REGISTRY_PASSWORD:-}"
  registry_auth_add "${CHART_REGISTRY:-}" "${CHART_REGISTRY_USERNAME:-}" "${CHART_REGISTRY_PASSWORD:-}"
  registry_auth_add "${CHART_DEPENDENCY_REGISTRY:-}" "${CHART_DEPENDENCY_REGISTRY_USERNAME:-}" "${CHART_DEPENDENCY_REGISTRY_PASSWORD:-}"
  if ! CONFIG_JSON=$(registry_config_json); then
    [[ "${XTRACE}" == true ]] && set -x
    return 1
  fi
  while IFS=$'\t' read -r HOST USERNAME PASSWORD; do
    registry_auth_add "${HOST}" "${USERNAME}" "${PASSWORD}"
  done < <(jq -r 'to_entries[] | select(.value.username and .value.password)
    | [.key, .value.username, .value.password] | @tsv' <<<"${CONFIG_JSON}")
  [[ -n "${DIR}" ]] || DIR=$(mktemp -d)
  mkdir -p "${DIR}"
  jq -n --argjson AUTHS "${AUTHS}" '{auths: $AUTHS}' > "${DIR}/config.json"
  chmod 600 "${DIR}/config.json"
  export DOCKER_CONFIG="${DIR}"
  export HELM_REGISTRY_CONFIG="${DIR}/config.json"
  export REGISTRY_AUTH_FILE="${DIR}/config.json"
  [[ "${XTRACE}" == true ]] && set -x
  return 0
}

# 0 when a ref exists, 1 when the registry says it does not, 2 when it cannot tell.
registry_exists() {
  local OUTPUT
  if OUTPUT=$(crane digest "$1" 2>&1); then
    return 0
  fi
  case "${OUTPUT}" in
    *MANIFEST_UNKNOWN*|*NAME_UNKNOWN*|*"not found"*|*"NOT_FOUND"*|*" 404 "*) return 1 ;;
  esac
  echo "::error title=Registry lookup::Cannot look up $1: ${OUTPUT##*$'\n'}" >&2
  return 2
}

# Copy SRC to DEST by digest and confirm DEST holds that digest. A DEST already at the
# digest is left alone, so a rerun is a no-op.
registry_copy() {
  local SRC="$1" DEST="$2" DIGEST CURRENT
  if ! DIGEST=$(crane digest "${SRC}" 2>/dev/null); then
    echo "::error title=Registry copy::Cannot read ${SRC}." >&2
    return 1
  fi
  CURRENT=$(crane digest "${DEST}" 2>/dev/null || true)
  if [[ "${CURRENT}" == "${DIGEST}" ]]; then
    echo "${DEST} already holds ${DIGEST}."
    return 0
  fi
  if ! crane copy "${SRC}" "${DEST}" >/dev/null 2>&1 \
      || [[ "$(crane digest "${DEST}" 2>/dev/null)" != "${DIGEST}" ]]; then
    echo "::error title=Registry copy::Copy of ${SRC} to ${DEST} failed or changed its digest." >&2
    return 1
  fi
  echo "Copied ${SRC} to ${DEST} (${DIGEST})."
}

# Give every destination after the primary what the primary holds at TAG, in its stable
# or dev repository, plus the ALIAS tags. Charts live at <repository>/<CHART_NAME>.
# All destinations are tried; the failed ones are listed at the end.
registry_mirror() {
  local KIND="$1" WHICH="$2" TAG="$3" TARGETS HOST STABLE DEV REPO SRC="" ALIAS NOT_COPIED=()
  shift 3
  TARGETS=$(registry_targets "${KIND}") || return 1
  while IFS=$'\t' read -r HOST STABLE DEV; do
    REPO="${HOST}/${STABLE}"
    [[ "${WHICH}" == "dev" ]] && REPO="${HOST}/${DEV}"
    [[ "${KIND}" == "chart" ]] && REPO="${REPO}/${CHART_NAME}"
    if [[ -z "${SRC}" ]]; then
      SRC="${REPO}:${TAG}"
      continue
    fi
    if ! registry_copy "${SRC}" "${REPO}:${TAG}"; then
      NOT_COPIED+=("${REPO}:${TAG}")
      continue
    fi
    for ALIAS in "$@"; do
      crane tag "${REPO}:${TAG}" "${ALIAS}" >/dev/null || NOT_COPIED+=("${REPO}:${ALIAS}")
    done
  done <<<"${TARGETS}"
  if [[ "${#NOT_COPIED[@]}" -gt 0 ]]; then
    echo "::error title=Registry copy::Not copied: ${NOT_COPIED[*]}" >&2
    return 1
  fi
}

# The destination a reading job uses: SELECT (a full ref, e.g. DEPLOY_IMAGE_REPOSITORY)
# when it is one of the destinations, else the primary. Sets SELECTED_HOST,
# SELECTED_STABLE and SELECTED_DEV.
registry_select() {
  local KIND="$1" SELECT="${2#oci://}" TARGETS HOST STABLE DEV VALID=()
  SELECTED_HOST=""
  TARGETS=$(registry_targets "${KIND}") || return 1
  while IFS=$'\t' read -r HOST STABLE DEV; do
    VALID+=("${HOST}/${STABLE}")
    if [[ -z "${SELECTED_HOST}" && ( -z "${SELECT}" || "${SELECT,,}" == "${HOST}/${STABLE,,}" ) ]]; then
      SELECTED_HOST="${HOST}"
      SELECTED_STABLE="${STABLE}"
      SELECTED_DEV="${DEV}"
    fi
  done <<<"${TARGETS}"
  if [[ -z "${SELECTED_HOST}" ]]; then
    echo "::error title=Registry configuration::'${SELECT}' is not one of the ${KIND} destinations: ${VALID[*]}" >&2
    return 1
  fi
}

# The selected repository for VERSION: stable for a release version, dev otherwise.
registry_version_repository() {
  if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s/%s\n' "${SELECTED_HOST}" "${SELECTED_STABLE}"
  else
    printf '%s/%s\n' "${SELECTED_HOST}" "${SELECTED_DEV}"
  fi
}
