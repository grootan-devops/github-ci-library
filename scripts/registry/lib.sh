#!/usr/bin/env bash
# shellcheck disable=SC2034 # REGISTRY_* and REG_* globals are this library's outputs.
# Registry targets: where images and charts are published, and the credentials
# each registry is logged in to with.
#
# Source this file; it sets no shell options and performs no I/O on load.
#
# A project publishes to one registry, or to several through a credential group:
#
#   One registry  vars.IMAGE_REGISTRY / vars.CHART_REGISTRY hold its host,
#                 vars.IMAGE_REPOSITORY / vars.CHART_REPOSITORY the path in it,
#                 and secrets.<KIND>_REGISTRY_USERNAME / _PASSWORD log in to it,
#                 exactly as before 1.10.0.
#   A group       vars.PROJECT_REGISTRY_NAME names one group of the
#                 REGISTRY_CONFIG secret, YAML (or JSON) that maps each group's
#                 registries to their credentials:
#                   client-name/org:
#                     docker.io:
#                       username: "..."
#                       password: "..."
#                     quay.io:
#                       username: "..."
#                       password: "..."
#                 vars.IMAGE_REPOSITORY and vars.CHART_REPOSITORY then list the
#                 full repositories to publish to, <registry>/<path>, separated
#                 by spaces or commas. Every registry they name must be in the
#                 group, and repositories on one registry share its account.
#
# Setting PROJECT_REGISTRY_NAME together with IMAGE_REGISTRY or CHART_REGISTRY
# is ambiguous, and init.yml stops before anything else runs
# (registry_check_mode).
#
# The first repository of each kind is the primary: base images are pulled from
# its registry, scans, smoke tests and deployments read from it, and releases
# are promoted in it before being copied to the others. Hosts are used exactly
# as written; credentials match them ignoring case, scheme and path, with Docker
# Hub's aliases as one registry.
#
# Passwords read from REGISTRY_CONFIG are registered with `::add-mask::` before
# use, because GitHub does not reliably redact parts of a structured secret.
# That command must reach the runner, so call registry_credentials and
# registry_login directly: never inside $(...), a pipe, or a block whose output
# is tee'd to a log file, where the mask line would be captured in plain text.
#
# Return codes: 0 ok; 1 a registry, a repository or credentials are missing, or
# a registry refused the login; 2 configuration error. Errors are reported with
# ::error annotations.
#
# Env:
#   PROJECT_REGISTRY_NAME                the REGISTRY_CONFIG group to publish with (default: empty)
#   REGISTRY_CONFIG                      the groups, as YAML or JSON, or the path of a file holding them
#   IMAGE_REGISTRY / CHART_REGISTRY      the single registry's host, without a group
#   CHART_DEPENDENCY_REGISTRY            the host chart dependencies are pulled from
#   <KIND>_REGISTRY_USERNAME / _PASSWORD the single registry's secret pair, KIND being
#                                        IMAGE, CHART or CHART_DEPENDENCY
#   GITHUB_ACTIONS                       "true" enables ::add-mask::
#   RUNNER_TEMP                          holds the ledger registry_logout reads

# Split a list on spaces, commas and newlines, keeping order, into REGISTRY_LIST.
registry_list() {
  local LIST_TEXT="${1-}"
  REGISTRY_LIST=()
  IFS=$' \t\n' read -r -d '' -a REGISTRY_LIST <<< "${LIST_TEXT//,/ }" || true
}

# Print the first item of a list.
registry_primary() {
  local REGISTRY_LIST=()
  registry_list "${1-}"
  printf '%s\n' "${REGISTRY_LIST[0]-}"
}

# Print a host in the form used for matching only: lower case, no scheme, no
# path, Docker Hub's aliases folded to docker.io. Logins and pushes keep the
# host exactly as it was written.
registry_canonical_host() {
  local CANONICAL_HOST="${1-}"
  CANONICAL_HOST="${CANONICAL_HOST,,}"
  CANONICAL_HOST="${CANONICAL_HOST#*://}"
  CANONICAL_HOST="${CANONICAL_HOST%%/*}"
  case "${CANONICAL_HOST}" in
    index.docker.io|registry-1.docker.io) CANONICAL_HOST="docker.io" ;;
  esac
  printf '%s\n' "${CANONICAL_HOST}"
}

registry_is_docker_hub() {
  [[ "$(registry_canonical_host "${1-}")" == "docker.io" ]]
}

# Expand a list to COUNT entries into REGISTRY_EXPANDED: one value is repeated,
# COUNT values are used as given, anything else is an error naming NAME.
registry_expand() {
  local EXPAND_NAME="$1" EXPAND_COUNT="$2" I
  local REGISTRY_LIST=()
  registry_list "${3-}"
  REGISTRY_EXPANDED=()
  if [[ ${#REGISTRY_LIST[@]} -eq "${EXPAND_COUNT}" ]]; then
    REGISTRY_EXPANDED=("${REGISTRY_LIST[@]}")
  elif [[ ${#REGISTRY_LIST[@]} -eq 1 ]]; then
    for ((I = 0; I < EXPAND_COUNT; I++)); do
      REGISTRY_EXPANDED+=("${REGISTRY_LIST[0]}")
    done
  else
    echo "::error title=Registry::${EXPAND_NAME} has ${#REGISTRY_LIST[@]} value(s) for ${EXPAND_COUNT} repositories. Give one value for all of them, or one per repository in the same order." >&2
    return 1
  fi
}

# Print a registry's development repository. Docker Hub has no nested image
# repositories, so `/dev` becomes `-dev`; its Helm charts live in the
# namespace root, so charts take no suffix there at all.
registry_dev_repository() {
  local ARTIFACT_KIND="$1" REPO_HOST="$2" REPO_PATH="$3" REPO_SUFFIX="${4-}"
  if registry_is_docker_hub "${REPO_HOST}"; then
    if [[ "${ARTIFACT_KIND}" == "chart" ]]; then
      REPO_SUFFIX=""
    else
      REPO_SUFFIX="${REPO_SUFFIX//\//-}"
    fi
  fi
  printf '%s\n' "${REPO_PATH}${REPO_SUFFIX}"
}

# Print PROJECT_REGISTRY_NAME without surrounding whitespace.
registry_group_name() {
  local GROUP_NAME="${PROJECT_REGISTRY_NAME-}"
  GROUP_NAME="${GROUP_NAME#"${GROUP_NAME%%[![:space:]]*}"}"
  GROUP_NAME="${GROUP_NAME%"${GROUP_NAME##*[![:space:]]}"}"
  printf '%s\n' "${GROUP_NAME}"
}

# Succeed when PROJECT_REGISTRY_NAME names a group.
registry_named() {
  [[ -n "$(registry_group_name)" ]]
}

# Fail when PROJECT_REGISTRY_NAME is set together with a single-registry
# variable: nothing says which of them should win. init.yml runs this first,
# so a pipeline configured both ways stops before any job publishes anything.
registry_check_mode() {
  local KIND_VARIABLE VARIABLE_VALUE BOTH_SET=()
  if ! registry_named; then
    return 0
  fi
  for KIND_VARIABLE in IMAGE_REGISTRY CHART_REGISTRY; do
    VARIABLE_VALUE="${!KIND_VARIABLE-}"
    if [[ -n "${VARIABLE_VALUE//[[:space:],]/}" ]]; then
      BOTH_SET+=("vars.${KIND_VARIABLE}")
    fi
  done
  if [[ ${#BOTH_SET[@]} -eq 0 ]]; then
    return 0
  fi
  local JOINED_NAMES="${BOTH_SET[0]}"
  if [[ ${#BOTH_SET[@]} -gt 1 ]]; then
    JOINED_NAMES="${BOTH_SET[0]} and ${BOTH_SET[1]}"
  fi
  echo "::error title=Registry::vars.PROJECT_REGISTRY_NAME and ${JOINED_NAMES} are both set, so it is unclear where to publish. Remove ${JOINED_NAMES} to publish to the full repositories vars.IMAGE_REPOSITORY and vars.CHART_REPOSITORY list, or remove vars.PROJECT_REGISTRY_NAME to publish to a single registry." >&2
  return 2
}

# Split REF, a full repository <registry>/<path> (charts may add oci://), into
# REF_HOST and REF_PATH. Fails when the first part is not a registry host, or
# REF carries a scheme, a tag or a digest.
registry_split_ref() {
  local ARTIFACT_KIND="$1" REPO_REF="$2" SPLIT_HOST SPLIT_PATH
  REF_HOST=""
  REF_PATH=""
  if [[ "${ARTIFACT_KIND}" == "chart" ]]; then
    REPO_REF="${REPO_REF#oci://}"
  fi
  REPO_REF="${REPO_REF%/}"
  if [[ "${REPO_REF}" != */* || "${REPO_REF}" == *://* || "${REPO_REF}" == *@* ]]; then
    return 1
  fi
  SPLIT_HOST="${REPO_REF%%/*}"
  SPLIT_PATH="${REPO_REF#*/}"
  if [[ -z "${SPLIT_PATH}" || "${SPLIT_PATH}" == /* || "${SPLIT_PATH}" == *:* ]]; then
    return 1
  fi
  if [[ "${SPLIT_HOST}" != *.* && "${SPLIT_HOST}" != *:* && "${SPLIT_HOST}" != "localhost" ]]; then
    return 1
  fi
  REF_HOST="${SPLIT_HOST}"
  REF_PATH="${SPLIT_PATH}"
}

# Load REGISTRY_CONFIG once into _REGISTRY_CONFIG_JSON. YAML is converted with
# yq; JSON, which is YAML too, is read with jq alone. Neither the value nor a
# parser's diagnostics are ever printed: a parse error message can quote the
# input.
registry_config_load() {
  if [[ -n "${_REGISTRY_CONFIG_LOADED-}" ]]; then
    return "${_REGISTRY_CONFIG_STATUS}"
  fi
  _REGISTRY_CONFIG_LOADED=1
  _REGISTRY_CONFIG_STATUS=2
  _REGISTRY_CONFIG_JSON=""
  local RAW="${REGISTRY_CONFIG-}" JSON=""
  if [[ -z "${RAW//[[:space:]]/}" ]]; then
    echo "::error title=Registry config::vars.PROJECT_REGISTRY_NAME is set, but the REGISTRY_CONFIG secret is empty or was not passed to this workflow. Set it on the organisation or repository and call the workflow with secrets: inherit." >&2
    return 2
  fi
  if [[ "${RAW}" != *$'\n'* && -f "${RAW}" && -r "${RAW}" ]]; then
    RAW="$(cat -- "${RAW}")"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "::error title=Registry config::jq is required to read REGISTRY_CONFIG." >&2
    return 2
  fi
  if [[ "${RAW}" =~ ^[[:space:]]*\{ ]]; then
    JSON="$(printf '%s' "${RAW}" | jq -c . 2>/dev/null)" || JSON=""
  elif command -v yq >/dev/null 2>&1; then
    JSON="$(printf '%s' "${RAW}" | yq eval -o=json -I=0 'explode(.)' - 2>/dev/null)" || JSON=""
  else
    echo "::error title=Registry config::yq is required to read REGISTRY_CONFIG as YAML; store it as JSON on a runner without yq." >&2
    return 2
  fi
  if [[ -z "${JSON}" ]] || ! JSON="$(printf '%s' "${JSON}" | jq -c 'if type == "object" then . else error("not a map") end' 2>/dev/null)"; then
    echo "::error title=Registry config::REGISTRY_CONFIG is not valid YAML or JSON mapping group names to their registries." >&2
    return 2
  fi
  _REGISTRY_CONFIG_JSON="${JSON}"
  _REGISTRY_CONFIG_STATUS=0
}

# Load the registries of the group PROJECT_REGISTRY_NAME names into
# _REGISTRY_GROUP_HOSTS, once. Returns 0, or 2 when the group is missing or is
# not a map of registries.
registry_group_load() {
  local GROUP_NAME JQ_LINE GROUP_STATE HOST_KEYS
  GROUP_NAME="$(registry_group_name)"
  if [[ "${_REGISTRY_GROUP_LOADED-}" == "${GROUP_NAME}" ]]; then
    return 0
  fi
  _REGISTRY_GROUP_HOSTS=()
  registry_config_load || return 2
  # shellcheck disable=SC2016 # $GROUP_NAME and $GROUP are jq variables, not shell ones
  if ! JQ_LINE="$(printf '%s' "${_REGISTRY_CONFIG_JSON}" | jq -r --arg GROUP_NAME "${GROUP_NAME}" '
      .[$GROUP_NAME] as $GROUP
      | if $GROUP == null then "missing"
        elif ($GROUP | type) != "object" or ($GROUP | length) == 0
             or ($GROUP | keys | map(test("^[^\\s,/]+$")) | all | not)
        then "invalid"
        else "ok\t" + ($GROUP | keys_unsorted | join(" ")) end' 2>/dev/null)"; then
    JQ_LINE="invalid"
  fi
  IFS=$'\t' read -r GROUP_STATE HOST_KEYS <<< "${JQ_LINE}"
  case "${GROUP_STATE}" in
    ok) ;;
    missing)
      echo "::error title=Registry config::vars.PROJECT_REGISTRY_NAME names group '${GROUP_NAME}', which REGISTRY_CONFIG does not define." >&2
      return 2
      ;;
    *)
      echo "::error title=Registry config::REGISTRY_CONFIG group '${GROUP_NAME}' must map registry hosts, such as docker.io or quay.io, to their credentials." >&2
      return 2
      ;;
  esac
  read -r -a _REGISTRY_GROUP_HOSTS <<< "${HOST_KEYS}"
  _REGISTRY_GROUP_LOADED="${GROUP_NAME}"
}

# Find the group's registry for HOST, ignoring case, scheme and Docker Hub's
# aliases, into REG_ENTRY_KEY. Returns 0 found, 1 none, 2 when two of the
# group's registries are the same host.
registry_group_entry() {
  local HOST_NAME="$1" CANONICAL GROUP_KEY MATCHED_KEYS=()
  REG_ENTRY_KEY=""
  CANONICAL="$(registry_canonical_host "${HOST_NAME}")"
  for GROUP_KEY in "${_REGISTRY_GROUP_HOSTS[@]}"; do
    if [[ "$(registry_canonical_host "${GROUP_KEY}")" == "${CANONICAL}" ]]; then
      MATCHED_KEYS+=("${GROUP_KEY}")
    fi
  done
  if [[ ${#MATCHED_KEYS[@]} -eq 0 ]]; then
    return 1
  fi
  if [[ ${#MATCHED_KEYS[@]} -gt 1 ]]; then
    echo "::error title=Registry config::REGISTRY_CONFIG group '$(registry_group_name)' lists ${MATCHED_KEYS[*]}, which are one registry; keep one of them." >&2
    return 2
  fi
  REG_ENTRY_KEY="${MATCHED_KEYS[0]}"
}

# Resolve where artifacts of KIND (image | chart | dependency) go, pairing each
# target with its repository and, when given, its development repository.
# Sets REGISTRY_KIND, REGISTRY_HOSTS, REGISTRY_REPOS, REGISTRY_DEV_REPOS (empty
# when no development list is given) and REGISTRY_PRIMARY.
#
# A single registry takes its host from the KIND's registry variable and
# REPOSITORIES as the path in it; without REPOSITORIES the path is left empty.
# With a group, REPOSITORIES lists full repositories, and DEV_REPOSITORIES may
# be full repositories on the same registries or plain paths. Chart
# dependencies always come from the single vars.CHART_DEPENDENCY_REGISTRY host.
registry_resolve() {
  local ARTIFACT_KIND="${1-}" REPO_LIST="${2-}" DEV_REPO_LIST="${3-}"
  local KIND_LABEL KIND_VARIABLE REPO_REF HOST_NAME GROUP_NAME I HOST_REPO_KEY SEEN=" " RC
  local REGISTRY_LIST=() REGISTRY_EXPANDED=()
  REGISTRY_KIND="${ARTIFACT_KIND}"
  REGISTRY_HOSTS=()
  REGISTRY_REPOS=()
  REGISTRY_DEV_REPOS=()
  REGISTRY_PRIMARY=""
  case "${ARTIFACT_KIND}" in
    image)      KIND_LABEL="IMAGE";            KIND_VARIABLE="IMAGE_REGISTRY" ;;
    chart)      KIND_LABEL="CHART";            KIND_VARIABLE="CHART_REGISTRY" ;;
    dependency) KIND_LABEL="CHART_DEPENDENCY"; KIND_VARIABLE="CHART_DEPENDENCY_REGISTRY" ;;
    *)
      echo "::error title=Registry::Unknown registry kind '${ARTIFACT_KIND}'." >&2
      return 2
      ;;
  esac
  if [[ "${ARTIFACT_KIND}" != "dependency" ]] && registry_named; then
    GROUP_NAME="$(registry_group_name)"
    registry_group_load || return 2
    registry_list "${REPO_LIST}"
    if [[ ${#REGISTRY_LIST[@]} -eq 0 ]]; then
      echo "::error title=Registry::With vars.PROJECT_REGISTRY_NAME, vars.${KIND_LABEL}_REPOSITORY lists the full repositories to publish ${ARTIFACT_KIND}s to, as <registry>/<path>." >&2
      return 1
    fi
    for REPO_REF in "${REGISTRY_LIST[@]}"; do
      if ! registry_split_ref "${ARTIFACT_KIND}" "${REPO_REF}"; then
        echo "::error title=Registry::vars.${KIND_LABEL}_REPOSITORY entry '${REPO_REF}' is not a full repository, <registry>/<path>, on a registry of REGISTRY_CONFIG group '${GROUP_NAME}'." >&2
        return 2
      fi
      RC=0
      registry_group_entry "${REF_HOST}" || RC=$?
      if [[ ${RC} -eq 1 ]]; then
        echo "::error title=Registry::Registry ${REF_HOST} of '${REPO_REF}' is not in REGISTRY_CONFIG group '${GROUP_NAME}', which has: ${_REGISTRY_GROUP_HOSTS[*]}." >&2
        return 2
      elif [[ ${RC} -ne 0 ]]; then
        return 2
      fi
      REGISTRY_HOSTS+=("${REF_HOST}")
      REGISTRY_REPOS+=("${REF_PATH}")
    done
  else
    registry_list "${!KIND_VARIABLE-}"
    if [[ ${#REGISTRY_LIST[@]} -eq 0 ]]; then
      echo "::error title=Registry::No ${ARTIFACT_KIND} registry is set: set vars.${KIND_VARIABLE}, or name a REGISTRY_CONFIG group in vars.PROJECT_REGISTRY_NAME." >&2
      return 1
    fi
    if [[ ${#REGISTRY_LIST[@]} -gt 1 ]]; then
      echo "::error title=Registry::vars.${KIND_VARIABLE} holds ${#REGISTRY_LIST[@]} hosts, but takes one. To publish to several registries, name a REGISTRY_CONFIG group in vars.PROJECT_REGISTRY_NAME, list the full repositories in vars.${KIND_LABEL}_REPOSITORY, and remove vars.${KIND_VARIABLE}." >&2
      return 2
    fi
    REGISTRY_HOSTS=("${REGISTRY_LIST[0]}")
    REGISTRY_REPOS=("")
    registry_list "${REPO_LIST}"
    if [[ ${#REGISTRY_LIST[@]} -gt 1 ]]; then
      echo "::error title=Registry::vars.${KIND_LABEL}_REPOSITORY holds ${#REGISTRY_LIST[@]} repositories, but vars.${KIND_VARIABLE} publishes to one. To publish to several, name a REGISTRY_CONFIG group in vars.PROJECT_REGISTRY_NAME, list the full repositories in vars.${KIND_LABEL}_REPOSITORY, and remove vars.${KIND_VARIABLE}." >&2
      return 1
    fi
    if [[ ${#REGISTRY_LIST[@]} -eq 1 ]]; then
      REGISTRY_REPOS=("${REGISTRY_LIST[0]}")
    fi
  fi
  REGISTRY_PRIMARY="${REGISTRY_HOSTS[0]}"
  if [[ "${ARTIFACT_KIND}" != "image" ]]; then
    for HOST_NAME in "${REGISTRY_HOSTS[@]}"; do
      case "${HOST_NAME}" in
        *://*|*/*|*@*)
          echo "::error title=Chart registry::${HOST_NAME} is not an OCI hostname. Chart registries are hostnames, optionally with a port; put the namespace in CHART_REPOSITORY." >&2
          return 2
          ;;
      esac
    done
  fi
  if [[ -n "${DEV_REPO_LIST//[[:space:],]/}" ]]; then
    registry_expand "${KIND_LABEL}_DEV_REPOSITORY" "${#REGISTRY_HOSTS[@]}" "${DEV_REPO_LIST}" || return 1
    for I in "${!REGISTRY_HOSTS[@]}"; do
      REPO_REF="${REGISTRY_EXPANDED[${I}]}"
      if [[ -n "${GROUP_NAME-}" ]] && registry_split_ref "${ARTIFACT_KIND}" "${REPO_REF}"; then
        if [[ "$(registry_canonical_host "${REF_HOST}")" != "$(registry_canonical_host "${REGISTRY_HOSTS[${I}]}")" ]]; then
          echo "::error title=Registry::Development repository '${REPO_REF}' is not on ${REGISTRY_HOSTS[${I}]}, the registry of ${REGISTRY_HOSTS[${I}]}/${REGISTRY_REPOS[${I}]}." >&2
          return 1
        fi
        REPO_REF="${REF_PATH}"
      fi
      REGISTRY_DEV_REPOS+=("${REPO_REF}")
    done
  fi
  for I in "${!REGISTRY_HOSTS[@]}"; do
    HOST_REPO_KEY="$(registry_canonical_host "${REGISTRY_HOSTS[${I}]}")/${REGISTRY_REPOS[${I}]}"
    if [[ "${SEEN}" == *" ${HOST_REPO_KEY} "* ]]; then
      echo "::error title=Registry::${REGISTRY_HOSTS[${I}]}/${REGISTRY_REPOS[${I}]} is listed twice." >&2
      return 1
    fi
    SEEN+="${HOST_REPO_KEY} "
  done
}

# Set REGISTRY_PRIMARY and REGISTRY_PRIMARY_REPO, the primary registry and the
# path in it, for a step that may not need them: a single registry and
# REPOSITORIES exactly as given, even empty, or else the first full repository
# of REPOSITORIES, empty when there is none. Reads no credentials. Returns 2,
# having said why, only when that repository is not <registry>/<path>.
registry_primary_target() {
  local ARTIFACT_KIND="$1" REPO_LIST="${2-}" KIND_VARIABLE FIRST_REF
  REGISTRY_PRIMARY=""
  REGISTRY_PRIMARY_REPO=""
  case "${ARTIFACT_KIND}" in
    image) KIND_VARIABLE="IMAGE_REGISTRY" ;;
    chart) KIND_VARIABLE="CHART_REGISTRY" ;;
    *)
      echo "::error title=Registry::Unknown registry kind '${ARTIFACT_KIND}'." >&2
      return 2
      ;;
  esac
  if ! registry_named; then
    REGISTRY_PRIMARY="${!KIND_VARIABLE-}"
    REGISTRY_PRIMARY_REPO="${REPO_LIST}"
    return 0
  fi
  FIRST_REF="$(registry_primary "${REPO_LIST}")"
  if [[ -z "${FIRST_REF}" ]]; then
    return 0
  fi
  if ! registry_split_ref "${ARTIFACT_KIND}" "${FIRST_REF}"; then
    echo "::error title=Registry::'${FIRST_REF}' is not a full repository, <registry>/<path>, as vars.PROJECT_REGISTRY_NAME requires." >&2
    return 2
  fi
  REGISTRY_PRIMARY="${REF_HOST}"
  REGISTRY_PRIMARY_REPO="${REF_PATH}"
}

# Register VALUE with the runner's log masking. Prints the workflow command,
# so it must not be called inside $(...) or a pipe.
registry_mask() {
  if [[ "${GITHUB_ACTIONS-}" != "true" || -z "${1-}" ]]; then
    return 0
  fi
  local PERCENT="%"
  local MASK_VALUE="${1//"${PERCENT}"/%25}"
  MASK_VALUE="${MASK_VALUE//$'\r'/%0D}"
  MASK_VALUE="${MASK_VALUE//$'\n'/%0A}"
  printf '::add-mask::%s\n' "${MASK_VALUE}"
}

# shellcheck disable=SC2016 # $GROUP_NAME and $GROUP_KEY are jq variables, not shell ones
_REGISTRY_CREDENTIALS='
  .[$GROUP_NAME][$GROUP_KEY]
  | if type != "object" then "invalid"
    elif has("rolearn") then "rolearn"
    elif ([.username, .password] | map(type == "string" and length > 0) | all)
    then "full\t" + (.username | @base64) + "\t" + (.password | @base64)
    elif .username == null and .password == null then "none"
    else "partial" end'

# Resolve the credentials of target INDEX into REG_USER, REG_PASS and
# REG_SOURCE: its registry's entry in the group, or the single registry's
# secret pair. Returns 0 found, 1 none, 2 configuration error.
registry_credentials() {
  local INDEX="${1-0}" HOST_NAME GROUP_NAME SECRET_PREFIX USER_VAR PASS_VAR JQ_LINE CRED_STATE USER64 PASS64
  REG_USER=""
  REG_PASS=""
  REG_SOURCE=""
  if [[ $- == *x* ]]; then
    echo "::error title=Registry::Shell tracing (set -x) is on; refusing to handle registry credentials." >&2
    return 2
  fi
  HOST_NAME="${REGISTRY_HOSTS[${INDEX}]-}"
  if [[ -z "${HOST_NAME}" ]]; then
    echo "::error title=Registry::${REGISTRY_KIND-registry} target ${INDEX} does not exist." >&2
    return 2
  fi
  if [[ "${REGISTRY_KIND-}" != "dependency" ]] && registry_named; then
    GROUP_NAME="$(registry_group_name)"
    registry_group_load || return 2
    CRED_STATE=0
    registry_group_entry "${HOST_NAME}" || CRED_STATE=$?
    if [[ ${CRED_STATE} -ne 0 ]]; then
      return "${CRED_STATE}"
    fi
    if ! JQ_LINE="$(printf '%s' "${_REGISTRY_CONFIG_JSON}" | jq -r --arg GROUP_NAME "${GROUP_NAME}" --arg GROUP_KEY "${REG_ENTRY_KEY}" "${_REGISTRY_CREDENTIALS}" 2>/dev/null)"; then
      JQ_LINE="invalid"
    fi
    IFS=$'\t' read -r CRED_STATE USER64 PASS64 <<< "${JQ_LINE}"
    case "${CRED_STATE}" in
      full) ;;
      none) return 1 ;;
      rolearn)
        echo "::error title=Registry config::REGISTRY_CONFIG group '${GROUP_NAME}' uses rolearn (AWS ECR) for ${REG_ENTRY_KEY}, which this library does not support." >&2
        return 2
        ;;
      *)
        echo "::error title=Registry config::REGISTRY_CONFIG group '${GROUP_NAME}' needs a username and a password, quoted, for ${REG_ENTRY_KEY}." >&2
        return 2
        ;;
    esac
    if [[ "$(registry_canonical_host "${HOST_NAME}")" == *.dkr.ecr.*.amazonaws.com* ]]; then
      echo "::error title=Registry config::${HOST_NAME} is AWS ECR, which needs a short-lived token this library does not mint." >&2
      return 2
    fi
    REG_USER="$(printf '%s' "${USER64}" | base64 -d)"
    REG_PASS="$(printf '%s' "${PASS64}" | base64 -d)"
    registry_mask "${REG_PASS}"
    REG_SOURCE="REGISTRY_CONFIG group '${GROUP_NAME}'"
    return 0
  fi
  case "${REGISTRY_KIND-}" in
    image)      SECRET_PREFIX="IMAGE_REGISTRY" ;;
    chart)      SECRET_PREFIX="CHART_REGISTRY" ;;
    dependency) SECRET_PREFIX="CHART_DEPENDENCY_REGISTRY" ;;
    *)
      echo "::error title=Registry::Unknown registry kind '${REGISTRY_KIND-}'." >&2
      return 2
      ;;
  esac
  USER_VAR="${SECRET_PREFIX}_USERNAME"
  PASS_VAR="${SECRET_PREFIX}_PASSWORD"
  if [[ -n "${!USER_VAR-}" && -n "${!PASS_VAR-}" ]]; then
    REG_USER="${!USER_VAR}"
    REG_PASS="${!PASS_VAR}"
    REG_SOURCE="secrets.${USER_VAR}/${PASS_VAR}"
    return 0
  fi
  if [[ -n "${!USER_VAR-}" || -n "${!PASS_VAR-}" ]]; then
    echo "::warning title=Registry::Only one of secrets.${USER_VAR} and secrets.${PASS_VAR} is set, so the pair is ignored for ${HOST_NAME}."
  fi
  return 1
}

# Check that each registry of the resolved targets has credentials, naming every
# one without, once however many repositories it holds. init.yml runs this for a
# group, so a missing account stops the run before anything is built. Returns 0,
# 1 when a registry has none, or 2 on a configuration error.
registry_require_credentials() {
  local I HOST_NAME CHECKED_HOSTS=" " CRED_RC WORST_RC=0
  for I in "${!REGISTRY_HOSTS[@]}"; do
    HOST_NAME="$(registry_canonical_host "${REGISTRY_HOSTS[${I}]}")"
    if [[ "${CHECKED_HOSTS}" == *" ${HOST_NAME} "* ]]; then
      continue
    fi
    CHECKED_HOSTS+="${HOST_NAME} "
    CRED_RC=0
    registry_credentials "${I}" || CRED_RC=$?
    if [[ ${CRED_RC} -eq 1 ]]; then
      echo "::error title=Registry config::REGISTRY_CONFIG group '$(registry_group_name)' has no username and password for ${REGISTRY_HOSTS[${I}]}." >&2
    fi
    if [[ ${CRED_RC} -gt ${WORST_RC} ]]; then
      WORST_RC=${CRED_RC}
    fi
  done
  REG_USER=""
  REG_PASS=""
  return "${WORST_RC}"
}

# Log TOOL (docker | crane | helm) in to the registry of target INDEX, once per
# registry and tool. With --optional, a registry without credentials is used
# anonymously instead of failing. The password only ever travels on stdin.
registry_login() {
  local LOGIN_OPTIONAL="false"
  if [[ "${1-}" == "--optional" ]]; then
    LOGIN_OPTIONAL="true"
    shift
  fi
  local LOGIN_TOOL="${1-}" INDEX="${2-0}"
  local HOST_NAME LOGIN_KEY SERVER CLI_OUTPUT RC SECRET_PREFIX
  case "${LOGIN_TOOL}" in
    docker|crane|helm) ;;
    *)
      echo "::error title=Registry::Unknown login tool '${LOGIN_TOOL}'." >&2
      return 2
      ;;
  esac
  HOST_NAME="${REGISTRY_HOSTS[${INDEX}]-}"
  LOGIN_KEY="${LOGIN_TOOL}:$(registry_canonical_host "${HOST_NAME}")"
  if [[ "${_REGISTRY_LOGINS-}" == *" ${LOGIN_KEY} "* ]]; then
    return 0
  fi
  RC=0
  registry_credentials "${INDEX}" || RC=$?
  if [[ ${RC} -eq 1 ]]; then
    if [[ "${LOGIN_OPTIONAL}" == "true" ]]; then
      echo "No credentials for ${HOST_NAME}; using it anonymously."
      return 0
    fi
    if [[ "${REGISTRY_KIND-}" != "dependency" ]] && registry_named; then
      echo "::error title=Registry config::REGISTRY_CONFIG group '$(registry_group_name)' has no username and password for ${HOST_NAME}." >&2
    else
      SECRET_PREFIX="${REGISTRY_KIND^^}_REGISTRY"
      if [[ "${REGISTRY_KIND}" == "dependency" ]]; then
        SECRET_PREFIX="CHART_DEPENDENCY_REGISTRY"
      fi
      echo "::error title=Registry::No credentials for ${HOST_NAME}. Set secrets.${SECRET_PREFIX}_USERNAME and secrets.${SECRET_PREFIX}_PASSWORD and pass secrets: inherit." >&2
    fi
    return 1
  elif [[ ${RC} -ne 0 ]]; then
    return 2
  fi
  SERVER="${HOST_NAME}"
  # BuildKit and the docker CLI look Docker Hub up under its default index key,
  # which `docker login` only writes when it is given no server.
  if [[ "${LOGIN_TOOL}" == "docker" ]] && registry_is_docker_hub "${HOST_NAME}"; then
    SERVER=""
  fi
  if CLI_OUTPUT="$(printf '%s' "${REG_PASS}" | _registry_cli "${LOGIN_TOOL}" "${SERVER}" "${REG_USER}" 2>&1)"; then
    echo "Logged in to ${HOST_NAME} (${LOGIN_TOOL}) with ${REG_SOURCE}."
    _REGISTRY_LOGINS="${_REGISTRY_LOGINS:- }${LOGIN_KEY} "
    if [[ "${LOGIN_TOOL}" == "docker" ]]; then
      _registry_ledger_add "${SERVER:-docker.io}"
    fi
    RC=0
  else
    echo "::error title=Registry::${LOGIN_TOOL} login to ${HOST_NAME} with ${REG_SOURCE} was refused." >&2
    tail -n 5 <<< "${CLI_OUTPUT}" >&2
    RC=1
  fi
  REG_USER=""
  REG_PASS=""
  return "${RC}"
}

_registry_cli() {
  local CLI_TOOL="$1" CLI_SERVER="$2" CLI_USER="$3"
  case "${CLI_TOOL}" in
    docker)
      if [[ -n "${CLI_SERVER}" ]]; then
        docker login --username "${CLI_USER}" --password-stdin "${CLI_SERVER}"
      else
        docker login --username "${CLI_USER}" --password-stdin
      fi
      ;;
    crane) crane auth login "${CLI_SERVER}" --username "${CLI_USER}" --password-stdin ;;
    helm)  helm registry login "${CLI_SERVER}" --username "${CLI_USER}" --password-stdin ;;
  esac
}

# Docker logins on the runner host outlive the job on a self-hosted runner, so
# every server one wrote is recorded for registry_logout.
_registry_ledger_add() {
  if [[ -z "${RUNNER_TEMP-}" ]]; then
    return 0
  fi
  printf '%s\n' "$1" >> "${RUNNER_TEMP}/registry-logins.docker"
}

# Log docker out of every server this job logged in to. Never fails.
registry_logout() {
  local LEDGER="${RUNNER_TEMP-}/registry-logins.docker" SERVER
  if [[ -z "${RUNNER_TEMP-}" || ! -f "${LEDGER}" ]]; then
    return 0
  fi
  while IFS= read -r SERVER; do
    if [[ "${SERVER}" == "docker.io" ]]; then
      docker logout >/dev/null 2>&1 || true
    elif [[ -n "${SERVER}" ]]; then
      docker logout "${SERVER}" >/dev/null 2>&1 || true
    fi
    echo "Logged out of ${SERVER}."
  done < <(sort -u "${LEDGER}")
  rm -f "${LEDGER}"
}
