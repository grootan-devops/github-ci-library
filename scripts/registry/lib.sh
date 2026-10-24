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
#                 exactly as before 1.7.0.
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
  local value="${1-}"
  REGISTRY_LIST=()
  IFS=$' \t\n' read -r -d '' -a REGISTRY_LIST <<< "${value//,/ }" || true
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
  local host="${1-}"
  host="${host,,}"
  host="${host#*://}"
  host="${host%%/*}"
  case "${host}" in
    index.docker.io|registry-1.docker.io) host="docker.io" ;;
  esac
  printf '%s\n' "${host}"
}

registry_is_docker_hub() {
  [[ "$(registry_canonical_host "${1-}")" == "docker.io" ]]
}

# Expand a list to COUNT entries into REGISTRY_EXPANDED: one value is repeated,
# COUNT values are used as given, anything else is an error naming NAME.
registry_expand() {
  local name="$1" count="$2" i
  local REGISTRY_LIST=()
  registry_list "${3-}"
  REGISTRY_EXPANDED=()
  if [[ ${#REGISTRY_LIST[@]} -eq "${count}" ]]; then
    REGISTRY_EXPANDED=("${REGISTRY_LIST[@]}")
  elif [[ ${#REGISTRY_LIST[@]} -eq 1 ]]; then
    for ((i = 0; i < count; i++)); do
      REGISTRY_EXPANDED+=("${REGISTRY_LIST[0]}")
    done
  else
    echo "::error title=Registry::${name} has ${#REGISTRY_LIST[@]} value(s) for ${count} repositories. Give one value for all of them, or one per repository in the same order." >&2
    return 1
  fi
}

# Print a registry's development repository. Docker Hub has no nested image
# repositories, so `/dev` becomes `-dev`; its Helm charts live in the
# namespace root, so charts take no suffix there at all.
registry_dev_repository() {
  local kind="$1" host="$2" repo="$3" suffix="${4-}"
  if registry_is_docker_hub "${host}"; then
    if [[ "${kind}" == "chart" ]]; then
      suffix=""
    else
      suffix="${suffix//\//-}"
    fi
  fi
  printf '%s\n' "${repo}${suffix}"
}

# Print PROJECT_REGISTRY_NAME without surrounding whitespace.
registry_group_name() {
  local name="${PROJECT_REGISTRY_NAME-}"
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  printf '%s\n' "${name}"
}

# Succeed when PROJECT_REGISTRY_NAME names a group.
registry_named() {
  [[ -n "$(registry_group_name)" ]]
}

# Fail when PROJECT_REGISTRY_NAME is set together with a single-registry
# variable: nothing says which of them should win. init.yml runs this first,
# so a pipeline configured both ways stops before any job publishes anything.
registry_check_mode() {
  local variable value set=()
  if ! registry_named; then
    return 0
  fi
  for variable in IMAGE_REGISTRY CHART_REGISTRY; do
    value="${!variable-}"
    if [[ -n "${value//[[:space:],]/}" ]]; then
      set+=("vars.${variable}")
    fi
  done
  if [[ ${#set[@]} -eq 0 ]]; then
    return 0
  fi
  local joined="${set[0]}"
  if [[ ${#set[@]} -gt 1 ]]; then
    joined="${set[0]} and ${set[1]}"
  fi
  echo "::error title=Registry::vars.PROJECT_REGISTRY_NAME and ${joined} are both set, so it is unclear where to publish. Remove ${joined} to publish to the full repositories vars.IMAGE_REPOSITORY and vars.CHART_REPOSITORY list, or remove vars.PROJECT_REGISTRY_NAME to publish to a single registry." >&2
  return 2
}

# Split REF, a full repository <registry>/<path> (charts may add oci://), into
# REF_HOST and REF_PATH. Fails when the first part is not a registry host, or
# REF carries a scheme, a tag or a digest.
registry_split_ref() {
  local kind="$1" ref="$2" host path
  REF_HOST=""
  REF_PATH=""
  if [[ "${kind}" == "chart" ]]; then
    ref="${ref#oci://}"
  fi
  ref="${ref%/}"
  if [[ "${ref}" != */* || "${ref}" == *://* || "${ref}" == *@* ]]; then
    return 1
  fi
  host="${ref%%/*}"
  path="${ref#*/}"
  if [[ -z "${path}" || "${path}" == /* || "${path}" == *:* ]]; then
    return 1
  fi
  if [[ "${host}" != *.* && "${host}" != *:* && "${host}" != "localhost" ]]; then
    return 1
  fi
  REF_HOST="${host}"
  REF_PATH="${path}"
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
  local raw="${REGISTRY_CONFIG-}" json=""
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    echo "::error title=Registry config::vars.PROJECT_REGISTRY_NAME is set, but the REGISTRY_CONFIG secret is empty or was not passed to this workflow. Set it on the organisation or repository and call the workflow with secrets: inherit." >&2
    return 2
  fi
  if [[ "${raw}" != *$'\n'* && -f "${raw}" && -r "${raw}" ]]; then
    raw="$(cat -- "${raw}")"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "::error title=Registry config::jq is required to read REGISTRY_CONFIG." >&2
    return 2
  fi
  if [[ "${raw}" =~ ^[[:space:]]*\{ ]]; then
    json="$(printf '%s' "${raw}" | jq -c . 2>/dev/null)" || json=""
  elif command -v yq >/dev/null 2>&1; then
    json="$(printf '%s' "${raw}" | yq eval -o=json -I=0 'explode(.)' - 2>/dev/null)" || json=""
  else
    echo "::error title=Registry config::yq is required to read REGISTRY_CONFIG as YAML; store it as JSON on a runner without yq." >&2
    return 2
  fi
  if [[ -z "${json}" ]] || ! json="$(printf '%s' "${json}" | jq -c 'if type == "object" then . else error("not a map") end' 2>/dev/null)"; then
    echo "::error title=Registry config::REGISTRY_CONFIG is not valid YAML or JSON mapping group names to their registries." >&2
    return 2
  fi
  _REGISTRY_CONFIG_JSON="${json}"
  _REGISTRY_CONFIG_STATUS=0
}

# Load the registries of the group PROJECT_REGISTRY_NAME names into
# _REGISTRY_GROUP_HOSTS, once. Returns 0, or 2 when the group is missing or is
# not a map of registries.
registry_group_load() {
  local name line status hosts
  name="$(registry_group_name)"
  if [[ "${_REGISTRY_GROUP_LOADED-}" == "${name}" ]]; then
    return 0
  fi
  _REGISTRY_GROUP_HOSTS=()
  registry_config_load || return 2
  # shellcheck disable=SC2016 # $name is a jq variable, not a shell one
  if ! line="$(printf '%s' "${_REGISTRY_CONFIG_JSON}" | jq -r --arg name "${name}" '
      .[$name] as $g
      | if $g == null then "missing"
        elif ($g | type) != "object" or ($g | length) == 0
             or ($g | keys | map(test("^[^\\s,/]+$")) | all | not)
        then "invalid"
        else "ok\t" + ($g | keys_unsorted | join(" ")) end' 2>/dev/null)"; then
    line="invalid"
  fi
  IFS=$'\t' read -r status hosts <<< "${line}"
  case "${status}" in
    ok) ;;
    missing)
      echo "::error title=Registry config::vars.PROJECT_REGISTRY_NAME names group '${name}', which REGISTRY_CONFIG does not define." >&2
      return 2
      ;;
    *)
      echo "::error title=Registry config::REGISTRY_CONFIG group '${name}' must map registry hosts, such as docker.io or quay.io, to their credentials." >&2
      return 2
      ;;
  esac
  read -r -a _REGISTRY_GROUP_HOSTS <<< "${hosts}"
  _REGISTRY_GROUP_LOADED="${name}"
}

# Find the group's registry for HOST, ignoring case, scheme and Docker Hub's
# aliases, into REG_ENTRY_KEY. Returns 0 found, 1 none, 2 when two of the
# group's registries are the same host.
registry_group_entry() {
  local host="$1" canonical key found=()
  REG_ENTRY_KEY=""
  canonical="$(registry_canonical_host "${host}")"
  for key in "${_REGISTRY_GROUP_HOSTS[@]}"; do
    if [[ "$(registry_canonical_host "${key}")" == "${canonical}" ]]; then
      found+=("${key}")
    fi
  done
  if [[ ${#found[@]} -eq 0 ]]; then
    return 1
  fi
  if [[ ${#found[@]} -gt 1 ]]; then
    echo "::error title=Registry config::REGISTRY_CONFIG group '$(registry_group_name)' lists ${found[*]}, which are one registry; keep one of them." >&2
    return 2
  fi
  REG_ENTRY_KEY="${found[0]}"
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
  local kind="${1-}" repositories="${2-}" dev_repositories="${3-}"
  local label variable ref host group i key seen=" " status
  local REGISTRY_LIST=() REGISTRY_EXPANDED=()
  REGISTRY_KIND="${kind}"
  REGISTRY_HOSTS=()
  REGISTRY_REPOS=()
  REGISTRY_DEV_REPOS=()
  REGISTRY_PRIMARY=""
  case "${kind}" in
    image)      label="IMAGE";            variable="IMAGE_REGISTRY" ;;
    chart)      label="CHART";            variable="CHART_REGISTRY" ;;
    dependency) label="CHART_DEPENDENCY"; variable="CHART_DEPENDENCY_REGISTRY" ;;
    *)
      echo "::error title=Registry::Unknown registry kind '${kind}'." >&2
      return 2
      ;;
  esac
  if [[ "${kind}" != "dependency" ]] && registry_named; then
    group="$(registry_group_name)"
    registry_group_load || return 2
    registry_list "${repositories}"
    if [[ ${#REGISTRY_LIST[@]} -eq 0 ]]; then
      echo "::error title=Registry::With vars.PROJECT_REGISTRY_NAME, vars.${label}_REPOSITORY lists the full repositories to publish ${kind}s to, as <registry>/<path>." >&2
      return 1
    fi
    for ref in "${REGISTRY_LIST[@]}"; do
      if ! registry_split_ref "${kind}" "${ref}"; then
        echo "::error title=Registry::vars.${label}_REPOSITORY entry '${ref}' is not a full repository, <registry>/<path>, on a registry of REGISTRY_CONFIG group '${group}'." >&2
        return 2
      fi
      status=0
      registry_group_entry "${REF_HOST}" || status=$?
      if [[ ${status} -eq 1 ]]; then
        echo "::error title=Registry::Registry ${REF_HOST} of '${ref}' is not in REGISTRY_CONFIG group '${group}', which has: ${_REGISTRY_GROUP_HOSTS[*]}." >&2
        return 2
      elif [[ ${status} -ne 0 ]]; then
        return 2
      fi
      REGISTRY_HOSTS+=("${REF_HOST}")
      REGISTRY_REPOS+=("${REF_PATH}")
    done
  else
    registry_list "${!variable-}"
    if [[ ${#REGISTRY_LIST[@]} -eq 0 ]]; then
      echo "::error title=Registry::No ${kind} registry is set: set vars.${variable}, or name a REGISTRY_CONFIG group in vars.PROJECT_REGISTRY_NAME." >&2
      return 1
    fi
    if [[ ${#REGISTRY_LIST[@]} -gt 1 ]]; then
      echo "::error title=Registry::vars.${variable} holds ${#REGISTRY_LIST[@]} hosts, but takes one. To publish to several registries, name a REGISTRY_CONFIG group in vars.PROJECT_REGISTRY_NAME, list the full repositories in vars.${label}_REPOSITORY, and remove vars.${variable}." >&2
      return 2
    fi
    REGISTRY_HOSTS=("${REGISTRY_LIST[0]}")
    REGISTRY_REPOS=("")
    registry_list "${repositories}"
    if [[ ${#REGISTRY_LIST[@]} -gt 1 ]]; then
      echo "::error title=Registry::vars.${label}_REPOSITORY holds ${#REGISTRY_LIST[@]} repositories, but vars.${variable} publishes to one. To publish to several, name a REGISTRY_CONFIG group in vars.PROJECT_REGISTRY_NAME, list the full repositories in vars.${label}_REPOSITORY, and remove vars.${variable}." >&2
      return 1
    fi
    if [[ ${#REGISTRY_LIST[@]} -eq 1 ]]; then
      REGISTRY_REPOS=("${REGISTRY_LIST[0]}")
    fi
  fi
  REGISTRY_PRIMARY="${REGISTRY_HOSTS[0]}"
  if [[ "${kind}" != "image" ]]; then
    for host in "${REGISTRY_HOSTS[@]}"; do
      case "${host}" in
        *://*|*/*|*@*)
          echo "::error title=Chart registry::${host} is not an OCI hostname. Chart registries are hostnames, optionally with a port; put the namespace in CHART_REPOSITORY." >&2
          return 2
          ;;
      esac
    done
  fi
  if [[ -n "${dev_repositories//[[:space:],]/}" ]]; then
    registry_expand "${label}_DEV_REPOSITORY" "${#REGISTRY_HOSTS[@]}" "${dev_repositories}" || return 1
    for i in "${!REGISTRY_HOSTS[@]}"; do
      ref="${REGISTRY_EXPANDED[i]}"
      if [[ -n "${group-}" ]] && registry_split_ref "${kind}" "${ref}"; then
        if [[ "$(registry_canonical_host "${REF_HOST}")" != "$(registry_canonical_host "${REGISTRY_HOSTS[i]}")" ]]; then
          echo "::error title=Registry::Development repository '${ref}' is not on ${REGISTRY_HOSTS[i]}, the registry of ${REGISTRY_HOSTS[i]}/${REGISTRY_REPOS[i]}." >&2
          return 1
        fi
        ref="${REF_PATH}"
      fi
      REGISTRY_DEV_REPOS+=("${ref}")
    done
  fi
  for i in "${!REGISTRY_HOSTS[@]}"; do
    key="$(registry_canonical_host "${REGISTRY_HOSTS[i]}")/${REGISTRY_REPOS[i]}"
    if [[ "${seen}" == *" ${key} "* ]]; then
      echo "::error title=Registry::${REGISTRY_HOSTS[i]}/${REGISTRY_REPOS[i]} is listed twice." >&2
      return 1
    fi
    seen+="${key} "
  done
}

# Set REGISTRY_PRIMARY and REGISTRY_PRIMARY_REPO, the primary registry and the
# path in it, for a step that may not need them: a single registry and
# REPOSITORIES exactly as given, even empty, or else the first full repository
# of REPOSITORIES, empty when there is none. Reads no credentials. Returns 2,
# having said why, only when that repository is not <registry>/<path>.
registry_primary_target() {
  local kind="$1" repositories="${2-}" variable first
  REGISTRY_PRIMARY=""
  REGISTRY_PRIMARY_REPO=""
  case "${kind}" in
    image) variable="IMAGE_REGISTRY" ;;
    chart) variable="CHART_REGISTRY" ;;
    *)
      echo "::error title=Registry::Unknown registry kind '${kind}'." >&2
      return 2
      ;;
  esac
  if ! registry_named; then
    REGISTRY_PRIMARY="${!variable-}"
    REGISTRY_PRIMARY_REPO="${repositories}"
    return 0
  fi
  first="$(registry_primary "${repositories}")"
  if [[ -z "${first}" ]]; then
    return 0
  fi
  if ! registry_split_ref "${kind}" "${first}"; then
    echo "::error title=Registry::'${first}' is not a full repository, <registry>/<path>, as vars.PROJECT_REGISTRY_NAME requires." >&2
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
  local percent="%"
  local value="${1//"${percent}"/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '::add-mask::%s\n' "${value}"
}

# shellcheck disable=SC2016 # $group and $key are jq variables, not shell ones
_REGISTRY_CREDENTIALS='
  .[$group][$key]
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
  local index="${1-0}" host group prefix user pass line status user64 pass64
  REG_USER=""
  REG_PASS=""
  REG_SOURCE=""
  if [[ $- == *x* ]]; then
    echo "::error title=Registry::Shell tracing (set -x) is on; refusing to handle registry credentials." >&2
    return 2
  fi
  host="${REGISTRY_HOSTS[index]-}"
  if [[ -z "${host}" ]]; then
    echo "::error title=Registry::${REGISTRY_KIND-registry} target ${index} does not exist." >&2
    return 2
  fi
  if [[ "${REGISTRY_KIND-}" != "dependency" ]] && registry_named; then
    group="$(registry_group_name)"
    registry_group_load || return 2
    status=0
    registry_group_entry "${host}" || status=$?
    if [[ ${status} -ne 0 ]]; then
      return "${status}"
    fi
    if ! line="$(printf '%s' "${_REGISTRY_CONFIG_JSON}" | jq -r --arg group "${group}" --arg key "${REG_ENTRY_KEY}" "${_REGISTRY_CREDENTIALS}" 2>/dev/null)"; then
      line="invalid"
    fi
    IFS=$'\t' read -r status user64 pass64 <<< "${line}"
    case "${status}" in
      full) ;;
      none) return 1 ;;
      rolearn)
        echo "::error title=Registry config::REGISTRY_CONFIG group '${group}' uses rolearn (AWS ECR) for ${REG_ENTRY_KEY}, which this library does not support." >&2
        return 2
        ;;
      *)
        echo "::error title=Registry config::REGISTRY_CONFIG group '${group}' needs a username and a password, quoted, for ${REG_ENTRY_KEY}." >&2
        return 2
        ;;
    esac
    if [[ "$(registry_canonical_host "${host}")" == *.dkr.ecr.*.amazonaws.com* ]]; then
      echo "::error title=Registry config::${host} is AWS ECR, which needs a short-lived token this library does not mint." >&2
      return 2
    fi
    REG_USER="$(printf '%s' "${user64}" | base64 -d)"
    REG_PASS="$(printf '%s' "${pass64}" | base64 -d)"
    registry_mask "${REG_PASS}"
    REG_SOURCE="REGISTRY_CONFIG group '${group}'"
    return 0
  fi
  case "${REGISTRY_KIND-}" in
    image)      prefix="IMAGE_REGISTRY" ;;
    chart)      prefix="CHART_REGISTRY" ;;
    dependency) prefix="CHART_DEPENDENCY_REGISTRY" ;;
    *)
      echo "::error title=Registry::Unknown registry kind '${REGISTRY_KIND-}'." >&2
      return 2
      ;;
  esac
  user="${prefix}_USERNAME"
  pass="${prefix}_PASSWORD"
  if [[ -n "${!user-}" && -n "${!pass-}" ]]; then
    REG_USER="${!user}"
    REG_PASS="${!pass}"
    REG_SOURCE="secrets.${user}/${pass}"
    return 0
  fi
  if [[ -n "${!user-}" || -n "${!pass-}" ]]; then
    echo "::warning title=Registry::Only one of secrets.${user} and secrets.${pass} is set, so the pair is ignored for ${host}."
  fi
  return 1
}

# Check that each registry of the resolved targets has credentials, naming every
# one without, once however many repositories it holds. init.yml runs this for a
# group, so a missing account stops the run before anything is built. Returns 0,
# 1 when a registry has none, or 2 on a configuration error.
registry_require_credentials() {
  local i host checked=" " status rc=0
  for i in "${!REGISTRY_HOSTS[@]}"; do
    host="$(registry_canonical_host "${REGISTRY_HOSTS[i]}")"
    if [[ "${checked}" == *" ${host} "* ]]; then
      continue
    fi
    checked+="${host} "
    status=0
    registry_credentials "${i}" || status=$?
    if [[ ${status} -eq 1 ]]; then
      echo "::error title=Registry config::REGISTRY_CONFIG group '$(registry_group_name)' has no username and password for ${REGISTRY_HOSTS[i]}." >&2
    fi
    if [[ ${status} -gt ${rc} ]]; then
      rc=${status}
    fi
  done
  REG_USER=""
  REG_PASS=""
  return "${rc}"
}

# Log TOOL (docker | crane | helm) in to the registry of target INDEX, once per
# registry and tool. With --optional, a registry without credentials is used
# anonymously instead of failing. The password only ever travels on stdin.
registry_login() {
  local optional="false"
  if [[ "${1-}" == "--optional" ]]; then
    optional="true"
    shift
  fi
  local tool="${1-}" index="${2-0}"
  local host key server output status prefix
  case "${tool}" in
    docker|crane|helm) ;;
    *)
      echo "::error title=Registry::Unknown login tool '${tool}'." >&2
      return 2
      ;;
  esac
  host="${REGISTRY_HOSTS[index]-}"
  key="${tool}:$(registry_canonical_host "${host}")"
  if [[ "${_REGISTRY_LOGINS-}" == *" ${key} "* ]]; then
    return 0
  fi
  status=0
  registry_credentials "${index}" || status=$?
  if [[ ${status} -eq 1 ]]; then
    if [[ "${optional}" == "true" ]]; then
      echo "No credentials for ${host}; using it anonymously."
      return 0
    fi
    if [[ "${REGISTRY_KIND-}" != "dependency" ]] && registry_named; then
      echo "::error title=Registry config::REGISTRY_CONFIG group '$(registry_group_name)' has no username and password for ${host}." >&2
    else
      prefix="${REGISTRY_KIND^^}_REGISTRY"
      if [[ "${REGISTRY_KIND}" == "dependency" ]]; then
        prefix="CHART_DEPENDENCY_REGISTRY"
      fi
      echo "::error title=Registry::No credentials for ${host}. Set secrets.${prefix}_USERNAME and secrets.${prefix}_PASSWORD and pass secrets: inherit." >&2
    fi
    return 1
  elif [[ ${status} -ne 0 ]]; then
    return 2
  fi
  server="${host}"
  # BuildKit and the docker CLI look Docker Hub up under its default index key,
  # which `docker login` only writes when it is given no server.
  if [[ "${tool}" == "docker" ]] && registry_is_docker_hub "${host}"; then
    server=""
  fi
  if output="$(printf '%s' "${REG_PASS}" | _registry_cli "${tool}" "${server}" "${REG_USER}" 2>&1)"; then
    echo "Logged in to ${host} (${tool}) with ${REG_SOURCE}."
    _REGISTRY_LOGINS="${_REGISTRY_LOGINS:- }${key} "
    if [[ "${tool}" == "docker" ]]; then
      _registry_ledger_add "${server:-docker.io}"
    fi
    status=0
  else
    echo "::error title=Registry::${tool} login to ${host} with ${REG_SOURCE} was refused." >&2
    tail -n 5 <<< "${output}" >&2
    status=1
  fi
  REG_USER=""
  REG_PASS=""
  return "${status}"
}

_registry_cli() {
  local tool="$1" server="$2" user="$3"
  case "${tool}" in
    docker)
      if [[ -n "${server}" ]]; then
        docker login --username "${user}" --password-stdin "${server}"
      else
        docker login --username "${user}" --password-stdin
      fi
      ;;
    crane) crane auth login "${server}" --username "${user}" --password-stdin ;;
    helm)  helm registry login "${server}" --username "${user}" --password-stdin ;;
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
  local ledger="${RUNNER_TEMP-}/registry-logins.docker" server
  if [[ -z "${RUNNER_TEMP-}" || ! -f "${ledger}" ]]; then
    return 0
  fi
  while IFS= read -r server; do
    if [[ "${server}" == "docker.io" ]]; then
      docker logout >/dev/null 2>&1 || true
    elif [[ -n "${server}" ]]; then
      docker logout "${server}" >/dev/null 2>&1 || true
    fi
    echo "Logged out of ${server}."
  done < <(sort -u "${ledger}")
  rm -f "${ledger}"
}
