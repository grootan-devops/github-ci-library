#!/usr/bin/env bash
# Self-test for scripts/registry: a single registry, a REGISTRY_CONFIG group
# with full repositories, credentials and masking, logins, the init guard, and
# the login, target, copy, chart and collision-check scripts.
#
# No network: docker, crane and helm are stubs on PATH that record their
# arguments and their stdin separately, so the test can prove that no password
# ever reaches a command line and that each registry is logged in to once.
#
# Run from the repository root: bash tests/registry/lib.test.sh
#
# Exit codes: 0 every assertion passed, 1 otherwise.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${ROOT}/scripts/registry"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
}
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $*" >&2
}
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    pass
  else
    fail "$3: expected [$1], got [$2]"
  fi
}
assert_contains() {
  if [[ "$2" == *"$1"* ]]; then
    pass
  else
    fail "$3: [$1] not found in [$2]"
  fi
}
assert_not_contains() {
  if [[ "$2" != *"$1"* ]]; then
    pass
  else
    fail "$3: [$1] unexpectedly found"
  fi
}
# Print how many lines of FILE start with PREFIX.
count() {
  awk -v prefix="$1" 'index($0, prefix) == 1 { n++ } END { print n + 0 }' "$2"
}

# --- stubs -----------------------------------------------------------------
# Each call is logged as "argv <tool> <args>", and a password read from stdin
# as "stdin <tool> <password>". STUB_ARGV keeps every argv line of the run.
STUBS="${WORK}/bin"
mkdir -p "${STUBS}"
cat > "${STUBS}/stub" <<'STUB'
#!/usr/bin/env bash
tool="$(basename "$0")"
echo "argv ${tool} $*" | tee -a "${STUB_ARGV}" >> "${STUB_LOG}"
for arg in "$@"; do
  if [[ "${arg}" == "--password-stdin" ]]; then
    printf 'stdin %s %s\n' "${tool}" "$(cat)" >> "${STUB_LOG}"
  fi
done
for host in ${STUB_FAIL_HOSTS:-}; do
  for arg in "$@"; do
    if [[ "${arg}" == "${host}" || "${arg}" == "${host}/"* ]]; then
      echo "denied: ${host}" >&2
      exit 1
    fi
  done
done
if [[ "${tool}" == "crane" && "${1:-}" == "manifest" ]]; then
  for ref in ${STUB_MISSING:-}; do
    if [[ "${2:-}" == "${ref}" ]]; then
      echo "MANIFEST_UNKNOWN: ${ref}" >&2
      exit 1
    fi
  done
fi
if [[ "${tool}" == "crane" && "${1:-}" == "digest" ]]; then
  if [[ -n "${STUB_OTHER_DIGEST_HOST:-}" && "${2:-}" == "${STUB_OTHER_DIGEST_HOST}/"* ]]; then
    echo "sha256:$(printf 'b%.0s' {1..64})"
  else
    echo "sha256:$(printf 'a%.0s' {1..64})"
  fi
fi
STUB
chmod +x "${STUBS}/stub"
for tool in docker crane helm; do
  ln -s stub "${STUBS}/${tool}"
done
export PATH="${STUBS}:${PATH}"
export STUB_LOG="${WORK}/stub.log" STUB_ARGV="${WORK}/argv.log"
: > "${STUB_ARGV}"
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"

# Credential groups, quoted as the documentation asks. Every password is
# distinct, so a leak names its registry.
CONFIG_FILE="${WORK}/registry-config.yaml"
cat > "${CONFIG_FILE}" <<'YAML'
oneuptime/dev:
  registry.example.com:
    username: 'robot$ci'
    password: 'harbor-secret'
  quay.io:
    username: "quay-user"
    password: "quay\tsecret\nsecond-line"
  docker.io:
    username: "hubuser"
    password: "hub%secret"
  charts.example.com: {username: "chart-user", password: "chart-secret"}
oneuptime/prod:
  REGISTRY.example.com:
    username: "robot$prod"
    password: "prod-secret"
broken/numbers:
  quay.io: {username: "quay-user", password: 0123}
broken/partial:
  quay.io: {username: "quay-user"}
broken/empty:
  quay.io: {}
broken/string:
  quay.io: "quay-user:secret"
broken/ecr:
  123456789012.dkr.ecr.eu-west-1.amazonaws.com:
    username: "aws-key"
    password: "aws-secret"
    rolearn: "arn:aws:iam::123456789012:role/ci"
broken/plain-ecr:
  210987654321.dkr.ecr.us-east-1.amazonaws.com: {username: "aws-key", password: "aws-secret"}
broken/aliases:
  docker.io: {username: "a", password: "alias-a"}
  registry-1.docker.io: {username: "c", password: "alias-c"}
broken/path-key:
  quay.io/oneuptime: {username: "a", password: "b"}
broken/not-map: "registry.example.com"
broken/empty-group: {}
YAML
CONFIG="$(cat "${CONFIG_FILE}")"
SECRETS=(harbor-secret $'quay\tsecret' hub%secret chart-secret prod-secret pair-secret json-secret dep-secret shared-secret)

reset() {
  unset REGISTRY_CONFIG PROJECT_REGISTRY_NAME IMAGE_REGISTRY CHART_REGISTRY CHART_DEPENDENCY_REGISTRY CHART_REPOSITORY
  unset IMAGE_REGISTRY_USERNAME IMAGE_REGISTRY_PASSWORD CHART_REGISTRY_USERNAME CHART_REGISTRY_PASSWORD
  unset CHART_DEPENDENCY_REGISTRY_USERNAME CHART_DEPENDENCY_REGISTRY_PASSWORD
  unset _REGISTRY_CONFIG_LOADED _REGISTRY_CONFIG_STATUS _REGISTRY_CONFIG_JSON
  unset _REGISTRY_GROUP_LOADED _REGISTRY_LOGINS
  _REGISTRY_GROUP_HOSTS=()
  unset STUB_FAIL_HOSTS STUB_MISSING STUB_OTHER_DIGEST_HOST
  export GITHUB_ACTIONS=true
  export RUNNER_TEMP="${WORK}/runner"
  rm -rf "${RUNNER_TEMP}"
  mkdir -p "${RUNNER_TEMP}"
  : > "${STUB_LOG}"
}
# Start over with group NAME of the test configuration.
group() {
  reset
  export REGISTRY_CONFIG="${CONFIG}" PROJECT_REGISTRY_NAME="$1"
}
OUT="${WORK}/out"
export GITHUB_STEP_SUMMARY="${WORK}/summary.md" GITHUB_OUTPUT="${WORK}/github-output"

# shellcheck source=scripts/registry/lib.sh
source "${SCRIPTS}/lib.sh"

# --- lists and hosts --------------------------------------------------------
reset
registry_list " docker.io/oneuptime/api, quay.io/oneuptime/api
registry.example.com/core/api  "
assert_eq "3|docker.io/oneuptime/api|registry.example.com/core/api" "${#REGISTRY_LIST[@]}|${REGISTRY_LIST[0]}|${REGISTRY_LIST[2]}" "lists split on spaces, commas and newlines"
registry_list ""
assert_eq "0" "${#REGISTRY_LIST[@]}" "an empty list"
assert_eq "quay.io/a" "$(registry_primary "quay.io/a,docker.io/b")" "the primary is the first"
assert_eq "" "$(registry_primary " ")" "a blank list has no primary"
assert_eq "docker.io" "$(registry_canonical_host "HTTPS://Registry-1.Docker.IO/v2/")" "Docker Hub's push host is Docker Hub"
assert_eq "docker.io" "$(registry_canonical_host index.docker.io)" "so is its index"
assert_eq "registry.example.com:5000" "$(registry_canonical_host "Registry.Example.com:5000")" "a port is kept"
if registry_is_docker_hub registry-1.docker.io && ! registry_is_docker_hub quay.io; then
  pass
else
  fail "registry_is_docker_hub"
fi
registry_expand IMAGE_DEV_REPOSITORY 3 "core/api/dev"
assert_eq "core/api/dev core/api/dev core/api/dev" "${REGISTRY_EXPANDED[*]}" "one value is repeated"
registry_expand IMAGE_DEV_REPOSITORY 3 "a b" > "${OUT}" 2>&1
assert_eq "1" "$?" "a short list is refused"
assert_contains "IMAGE_DEV_REPOSITORY has 2 value(s) for 3 repositories" "$(cat "${OUT}")" "and the counts are named"
assert_eq "core/api/dev" "$(registry_dev_repository image registry.example.com core/api /dev)" "a nested dev repository"
assert_eq "oneuptime/api-dev" "$(registry_dev_repository image docker.io oneuptime/api /dev)" "Docker Hub images take -dev"
assert_eq "oneuptime" "$(registry_dev_repository chart registry-1.docker.io oneuptime /dev)" "Docker Hub charts take no suffix"

# --- mode ---------------------------------------------------------------------
reset
if registry_named; then fail "no group by default"; else pass; fi
export PROJECT_REGISTRY_NAME="   "
if registry_named; then fail "a blank group is no group"; else pass; fi
export PROJECT_REGISTRY_NAME="  oneuptime/dev "
assert_eq "oneuptime/dev" "$(registry_group_name)" "the group name is trimmed"
registry_check_mode > "${OUT}" 2>&1
assert_eq "0" "$?" "a group alone is clear"
export IMAGE_REGISTRY="registry.example.com"
registry_check_mode > "${OUT}" 2>&1
assert_eq "2" "$?" "a group and IMAGE_REGISTRY are ambiguous"
assert_contains "vars.PROJECT_REGISTRY_NAME and vars.IMAGE_REGISTRY are both set" "$(cat "${OUT}")" "both are named"
export CHART_REGISTRY="registry.example.com"
registry_check_mode > "${OUT}" 2>&1
assert_contains "vars.PROJECT_REGISTRY_NAME and vars.IMAGE_REGISTRY and vars.CHART_REGISTRY are both set" "$(cat "${OUT}")" "all three are named"
export IMAGE_REGISTRY=" , " CHART_REGISTRY=""
registry_check_mode > "${OUT}" 2>&1
assert_eq "0" "$?" "blank registry variables count as unset"
reset
export IMAGE_REGISTRY="registry.example.com"
registry_check_mode > "${OUT}" 2>&1
assert_eq "0" "$?" "a single registry alone is clear"

# --- full repositories ----------------------------------------------------------
split() {
  if registry_split_ref "$1" "$2"; then
    echo "${REF_HOST}|${REF_PATH}"
  else
    echo "invalid|${REF_HOST}${REF_PATH}"
  fi
}
assert_eq "quay.io|oneuptime/api" "$(split image quay.io/oneuptime/api)" "a full repository"
assert_eq "registry.example.com:5000|core/api" "$(split image registry.example.com:5000/core/api/)" "a port and a trailing slash"
assert_eq "localhost|api" "$(split image localhost/api)" "localhost"
assert_eq "registry-1.docker.io|oneuptime" "$(split chart oci://registry-1.docker.io/oneuptime)" "charts may carry oci://"
assert_eq "invalid|" "$(split image core/api)" "a path is not a full repository"
assert_eq "invalid|" "$(split image quay.io)" "nor is a host"
assert_eq "invalid|" "$(split image oci://quay.io/oneuptime/api)" "images carry no scheme"
assert_eq "invalid|" "$(split chart https://charts.example.com/helm)" "charts carry no other scheme"
assert_eq "invalid|" "$(split image quay.io/oneuptime/api:1.0)" "a repository has no tag"
assert_eq "invalid|" "$(split image quay.io/oneuptime/api@sha256:abc)" "nor a digest"
assert_eq "invalid|" "$(split image quay.io//api)" "nor an empty segment"

# --- REGISTRY_CONFIG --------------------------------------------------------------
group "oneuptime/dev"
registry_config_load > "${OUT}" 2>&1
assert_eq "0|" "$?|$(cat "${OUT}")" "the YAML configuration loads silently"
assert_eq "oneuptime/dev,oneuptime/prod" "$(printf '%s' "${_REGISTRY_CONFIG_JSON}" | jq -r 'keys_unsorted[:2] | join(",")')" "into JSON, keeping its groups"
group "oneuptime/dev"
export REGISTRY_CONFIG="${CONFIG_FILE}"
registry_group_load > "${OUT}" 2>&1
assert_eq "0|registry.example.com quay.io docker.io charts.example.com" "$?|${_REGISTRY_GROUP_HOSTS[*]}" "a file path is read, and the group's registries keep their order"
group "oneuptime/dev"
export REGISTRY_CONFIG='{"oneuptime/dev": {"quay.io": {"username": "json-user", "password": "json-secret"}}}'
registry_group_load > "${OUT}" 2>&1
assert_eq "0|quay.io" "$?|${_REGISTRY_GROUP_HOSTS[*]}" "JSON is read too"
group "oneuptime/prod"
export REGISTRY_CONFIG=$'shared-quay: &quay\n  username: "shared-user"\n  password: "shared-secret"\noneuptime/prod:\n  quay.io: *quay\n'
registry_resolve image "quay.io/oneuptime/api" > /dev/null 2>&1
registry_credentials 0 > "${OUT}" 2>&1
assert_eq "0|shared-user|shared-secret" "$?|${REG_USER}|${REG_PASS}" "YAML anchors share an account between groups"
group "oneuptime/dev"
export REGISTRY_CONFIG=$'oneuptime/dev:\n  quay.io: {username: "u", password: "leaked-secret"\n'
registry_group_load > "${OUT}" 2>&1
assert_eq "2" "$?" "malformed YAML is refused"
assert_contains "REGISTRY_CONFIG is not valid YAML or JSON" "$(cat "${OUT}")" "and says so"
assert_not_contains "leaked-secret" "$(cat "${OUT}")" "without quoting the input"
group "oneuptime/dev"
export REGISTRY_CONFIG='{"oneuptime/dev": {"quay.io": {"password": "leaked-secret"}'
registry_group_load > "${OUT}" 2>&1
assert_eq "2" "$?" "malformed JSON is refused"
assert_not_contains "leaked-secret" "$(cat "${OUT}")" "without quoting the input"
group "oneuptime/dev"
export REGISTRY_CONFIG="- registry.example.com"
registry_group_load > "${OUT}" 2>&1
assert_eq "2" "$?" "a list is not a configuration"
group "oneuptime/dev"
export REGISTRY_CONFIG=" "
registry_group_load > "${OUT}" 2>&1
assert_eq "2" "$?" "an empty secret is refused"
assert_contains "the REGISTRY_CONFIG secret is empty or was not passed to this workflow" "$(cat "${OUT}")" "and secrets: inherit is suggested"
mkdir -p "${WORK}/only-jq"
ln -s "$(command -v jq)" "${WORK}/only-jq/jq"
group "oneuptime/dev"
PATH="${WORK}/only-jq" registry_config_load > "${OUT}" 2>&1
assert_eq "2" "$?" "YAML needs yq"
assert_contains "yq is required to read REGISTRY_CONFIG as YAML" "$(cat "${OUT}")" "and says so"
group "oneuptime/dev"
export REGISTRY_CONFIG='{"oneuptime/dev": {}}'
PATH="${WORK}/only-jq" registry_config_load > "${OUT}" 2>&1
assert_eq "0" "$?" "JSON needs no yq"
for name in oneuptime/staging broken/not-map broken/empty-group broken/path-key; do
  group "${name}"
  registry_group_load > "${OUT}" 2>&1
  assert_eq "2" "$?" "group ${name} is refused"
done
assert_contains "must map registry hosts" "$(cat "${OUT}")" "a group that is not a map of registries says so"
group "oneuptime/staging"
registry_group_load > "${OUT}" 2>&1
assert_contains "names group 'oneuptime/staging', which REGISTRY_CONFIG does not define" "$(cat "${OUT}")" "a missing group is named"

# --- a group's full repositories ------------------------------------------------------
group "oneuptime/dev"
registry_resolve image "registry.example.com/core/api quay.io/oneuptime/api,registry-1.docker.io/oneuptime/api docker.io/oneuptime/api-mirror" > "${OUT}" 2>&1
assert_eq "0|registry.example.com quay.io registry-1.docker.io docker.io|core/api oneuptime/api oneuptime/api oneuptime/api-mirror|registry.example.com" \
  "$?|${REGISTRY_HOSTS[*]}|${REGISTRY_REPOS[*]}|${REGISTRY_PRIMARY}" "the repositories, hosts as written, the first being the primary"
group "oneuptime/prod"
registry_resolve image "registry.example.com/core/api" > "${OUT}" 2>&1
assert_eq "0|registry.example.com" "$?|${REGISTRY_HOSTS[*]}" "a group's registry matches ignoring case"
group "oneuptime/dev"
registry_resolve chart "oci://charts.example.com/helm quay.io/oneuptime/charts" > "${OUT}" 2>&1
assert_eq "0|charts.example.com quay.io|helm oneuptime/charts" "$?|${REGISTRY_HOSTS[*]}|${REGISTRY_REPOS[*]}" "chart repositories"
registry_resolve image "registry.example.com/core/api docker.io/oneuptime/api" "registry.example.com/core/api/dev docker.io/oneuptime/api-dev" > "${OUT}" 2>&1
assert_eq "0|core/api/dev oneuptime/api-dev" "$?|${REGISTRY_DEV_REPOS[*]}" "full development repositories become paths"
registry_resolve image "registry.example.com/core/api docker.io/oneuptime/api" "quay.io/core/api/dev docker.io/oneuptime/api-dev" > "${OUT}" 2>&1
assert_eq "1" "$?" "a development repository on another registry is refused"
assert_contains "Development repository 'quay.io/core/api/dev' is not on registry.example.com" "$(cat "${OUT}")" "and named"
registry_resolve image "ghcr.io/oneuptime/api" > "${OUT}" 2>&1
assert_eq "2" "$?" "a registry outside the group is refused"
assert_contains "Registry ghcr.io of 'ghcr.io/oneuptime/api' is not in REGISTRY_CONFIG group 'oneuptime/dev', which has: registry.example.com quay.io docker.io charts.example.com." "$(cat "${OUT}")" "and the group's registries are listed"
registry_resolve image "quay.io/oneuptime/api core/api" > "${OUT}" 2>&1
assert_eq "2" "$?" "a path is refused"
assert_contains "vars.IMAGE_REPOSITORY entry 'core/api' is not a full repository, <registry>/<path>" "$(cat "${OUT}")" "and named"
registry_resolve chart " " > "${OUT}" 2>&1
assert_eq "1" "$?" "a group needs repositories"
assert_contains "With vars.PROJECT_REGISTRY_NAME, vars.CHART_REPOSITORY lists the full repositories to publish charts to" "$(cat "${OUT}")" "and says where they go"
registry_resolve image "quay.io/oneuptime/api QUAY.IO/oneuptime/api" > "${OUT}" 2>&1
assert_eq "1" "$?" "a repository listed twice is refused"
assert_contains "QUAY.IO/oneuptime/api is listed twice" "$(cat "${OUT}")" "and named"
group "broken/aliases"
registry_resolve image "docker.io/oneuptime/api" > "${OUT}" 2>&1
assert_eq "2" "$?" "two keys for one registry are refused"
assert_contains "lists docker.io registry-1.docker.io, which are one registry" "$(cat "${OUT}")" "and both are named"
group "oneuptime/dev"
export CHART_DEPENDENCY_REGISTRY="deps.example.com"
registry_resolve dependency > "${OUT}" 2>&1
assert_eq "0|deps.example.com" "$?|${REGISTRY_HOSTS[*]}" "dependencies always come from CHART_DEPENDENCY_REGISTRY"

# --- a single registry --------------------------------------------------------------
reset
export IMAGE_REGISTRY="registry.example.com"
registry_resolve image "core/api" "core/api/dev" > "${OUT}" 2>&1
assert_eq "0|registry.example.com|core/api|core/api/dev|registry.example.com" "$?|${REGISTRY_HOSTS[*]}|${REGISTRY_REPOS[*]}|${REGISTRY_DEV_REPOS[*]}|${REGISTRY_PRIMARY}" "one registry and its paths"
registry_resolve image "" > "${OUT}" 2>&1
assert_eq "0|1|" "$?|${#REGISTRY_REPOS[@]}|${REGISTRY_REPOS[0]}" "a registry without a repository"
registry_resolve image "core/api other/api" > "${OUT}" 2>&1
assert_eq "1" "$?" "a single registry takes one repository"
assert_contains "vars.IMAGE_REPOSITORY holds 2 repositories, but vars.IMAGE_REGISTRY publishes to one" "$(cat "${OUT}")" "and points at a group"
export IMAGE_REGISTRY="registry.example.com/library"
registry_resolve image "core/api" > "${OUT}" 2>&1
assert_eq "0" "$?" "an image registry may still carry a path"
export IMAGE_REGISTRY="registry.example.com quay.io"
registry_resolve image "core/api" > "${OUT}" 2>&1
assert_eq "2" "$?" "a host list is refused"
assert_contains "vars.IMAGE_REGISTRY holds 2 hosts, but takes one" "$(cat "${OUT}")" "and points at a group"
unset IMAGE_REGISTRY
registry_resolve image "core/api" > "${OUT}" 2>&1
assert_eq "1" "$?" "no registry"
assert_contains "No image registry is set" "$(cat "${OUT}")" "says what to set"
export CHART_REGISTRY="oci://charts.example.com"
registry_resolve chart "helm" > "${OUT}" 2>&1
assert_eq "2" "$?" "a chart registry is a hostname"
assert_contains "is not an OCI hostname" "$(cat "${OUT}")" "and says so"

# --- the primary, for readers that may not need one -------------------------------------
reset
export IMAGE_REGISTRY="registry.example.com"
registry_primary_target image "core/api"
assert_eq "0|registry.example.com|core/api" "$?|${REGISTRY_PRIMARY}|${REGISTRY_PRIMARY_REPO}" "a single registry, as given"
reset
registry_primary_target image ""
assert_eq "0||" "$?|${REGISTRY_PRIMARY}|${REGISTRY_PRIMARY_REPO}" "nothing set stays empty"
reset
export PROJECT_REGISTRY_NAME="oneuptime/dev"
registry_primary_target image "quay.io/oneuptime/api docker.io/oneuptime/api"
assert_eq "0|quay.io|oneuptime/api" "$?|${REGISTRY_PRIMARY}|${REGISTRY_PRIMARY_REPO}" "a group's first repository, without reading REGISTRY_CONFIG"
registry_primary_target chart "oci://charts.example.com/helm"
assert_eq "charts.example.com|helm" "${REGISTRY_PRIMARY}|${REGISTRY_PRIMARY_REPO}" "a chart's"
registry_primary_target image "" > "${OUT}" 2>&1
assert_eq "0|" "$?|${REGISTRY_PRIMARY}" "no repositories, no primary"
registry_primary_target image "core/api" > "${OUT}" 2>&1
assert_eq "2" "$?" "a path is refused"
assert_contains "'core/api' is not a full repository" "$(cat "${OUT}")" "and named"

# --- credentials --------------------------------------------------------------------
group "oneuptime/dev"
export IMAGE_REGISTRY_USERNAME="pair-user" IMAGE_REGISTRY_PASSWORD="pair-secret"
registry_resolve image "registry.example.com/core/api quay.io/oneuptime/api docker.io/oneuptime/api" > /dev/null 2>&1
registry_credentials 0 > "${OUT}" 2>&1
# shellcheck disable=SC2016 # the $ in robot$ci is a literal fixture value
assert_eq '0|robot$ci|harbor-secret' "$?|${REG_USER}|${REG_PASS}" "a group's credentials, never the pair"
assert_eq "REGISTRY_CONFIG group 'oneuptime/dev'" "${REG_SOURCE}" "named by their group"
assert_contains "::add-mask::harbor-secret" "$(cat "${OUT}")" "the password is masked"
registry_credentials 1 > "${OUT}" 2>&1
assert_eq $'quay\tsecret\nsecond-line' "${REG_PASS}" "control characters survive"
assert_contains $'::add-mask::quay\tsecret%0Asecond-line' "$(cat "${OUT}")" "a newline is escaped in the mask"
registry_credentials 2 > "${OUT}" 2>&1
assert_contains "::add-mask::hub%25secret" "$(cat "${OUT}")" "so is a percent sign"
GITHUB_ACTIONS=false registry_credentials 2 > "${OUT}" 2>&1
assert_eq "0|" "$?|$(cat "${OUT}")" "no mask outside GitHub Actions"
registry_credentials 7 > "${OUT}" 2>&1
assert_eq "2" "$?" "an unknown target"
for name in broken/numbers broken/partial broken/string; do
  group "${name}"
  registry_resolve image "quay.io/oneuptime/api" > /dev/null 2>&1
  registry_credentials 0 > "${OUT}" 2>&1
  assert_eq "2|" "$?|${REG_PASS}" "${name} is refused"
  assert_contains "REGISTRY_CONFIG group '${name}' needs a username and a password, quoted, for quay.io" "$(cat "${OUT}")" "${name} says why"
done
group "broken/empty"
registry_resolve image "quay.io/oneuptime/api" > /dev/null 2>&1
registry_credentials 0 > "${OUT}" 2>&1
assert_eq "1|" "$?|$(cat "${OUT}")" "an entry without credentials has none"
group "broken/ecr"
registry_resolve image "123456789012.dkr.ecr.eu-west-1.amazonaws.com/api" > /dev/null 2>&1
registry_credentials 0 > "${OUT}" 2>&1
assert_eq "2" "$?" "rolearn is refused"
assert_contains "uses rolearn (AWS ECR)" "$(cat "${OUT}")" "and named"
group "broken/plain-ecr"
registry_resolve image "210987654321.dkr.ecr.us-east-1.amazonaws.com/api" > /dev/null 2>&1
registry_credentials 0 > "${OUT}" 2>&1
assert_eq "2" "$?" "ECR is refused"
assert_contains "is AWS ECR" "$(cat "${OUT}")" "and named"
group "oneuptime/dev"
registry_resolve image "quay.io/oneuptime/api" > /dev/null 2>&1
(set -x; registry_credentials 0) > "${OUT}" 2>&1
assert_eq "2" "$?" "credentials are refused under xtrace"
assert_not_contains $'quay\tsecret' "$(cat "${OUT}")" "and nothing secret is traced"
reset
export IMAGE_REGISTRY="registry.example.com" IMAGE_REGISTRY_USERNAME="pair-user" IMAGE_REGISTRY_PASSWORD="pair-secret"
registry_resolve image "core/api" > /dev/null 2>&1
registry_credentials 0 > "${OUT}" 2>&1
assert_eq "0|pair-user|pair-secret|secrets.IMAGE_REGISTRY_USERNAME/IMAGE_REGISTRY_PASSWORD" "$?|${REG_USER}|${REG_PASS}|${REG_SOURCE}" "a single registry's pair"
assert_not_contains "add-mask" "$(cat "${OUT}")" "GitHub masks the pair itself"
unset IMAGE_REGISTRY_PASSWORD
registry_credentials 0 > "${OUT}" 2>&1
assert_eq "1" "$?" "half a pair is no pair"
assert_contains "Only one of secrets.IMAGE_REGISTRY_USERNAME and secrets.IMAGE_REGISTRY_PASSWORD is set" "$(cat "${OUT}")" "and warns"
group "oneuptime/dev"
registry_resolve image "quay.io/oneuptime/api QUAY.io/oneuptime/api-mirror docker.io/oneuptime/api" > /dev/null 2>&1
registry_require_credentials > "${OUT}" 2>&1
assert_eq "0|1|" "$?|$(grep -c '^::add-mask::quay' "${OUT}")|${REG_PASS}" "every registry has credentials, each checked once"
group "broken/empty"
registry_resolve image "quay.io/oneuptime/api quay.io/oneuptime/api-mirror" > /dev/null 2>&1
registry_require_credentials > "${OUT}" 2>&1
assert_eq "1|1" "$?|$(grep -c 'has no username and password for quay.io' "${OUT}")" "a registry without credentials is named once"

# --- logins -----------------------------------------------------------------------------
group "oneuptime/dev"
registry_resolve image "registry.example.com/core/api registry-1.docker.io/oneuptime/api docker.io/oneuptime/api-mirror quay.io/oneuptime/api" > /dev/null 2>&1
registry_login docker 0 > "${OUT}" 2>&1
assert_eq "0" "$?" "docker logs in"
assert_contains "argv docker login --username robot\$ci --password-stdin registry.example.com" "$(cat "${STUB_LOG}")" "to the host as written"
assert_contains "stdin docker harbor-secret" "$(cat "${STUB_LOG}")" "with the password on stdin"
assert_contains "Logged in to registry.example.com (docker) with REGISTRY_CONFIG group 'oneuptime/dev'." "$(cat "${OUT}")" "and says with what"
assert_eq "|" "${REG_USER}|${REG_PASS}" "the credentials are cleared"
registry_login docker 1 > "${OUT}" 2>&1
assert_eq "argv docker login --username hubuser --password-stdin" "$(grep 'hubuser' "${STUB_LOG}" | grep '^argv')" "docker logs in to Docker Hub without a server"
registry_login docker 2 > "${OUT}" 2>&1
assert_eq "2" "$(count "argv docker login" "${STUB_LOG}")" "a registry is logged in to once, whatever its alias"
registry_login crane 2 > "${OUT}" 2>&1
assert_contains "argv crane auth login docker.io --username hubuser --password-stdin" "$(cat "${STUB_LOG}")" "each tool logs in once"
registry_login helm 3 > "${OUT}" 2>&1
assert_contains "argv helm registry login quay.io --username quay-user --password-stdin" "$(cat "${STUB_LOG}")" "helm logs in"
assert_eq "docker.io
registry.example.com" "$(sort "${RUNNER_TEMP}/registry-logins.docker")" "docker logins are recorded"
registry_logout > "${OUT}" 2>&1
assert_contains "argv docker logout registry.example.com" "$(cat "${STUB_LOG}")" "and logged out"
assert_eq "1" "$(grep -cx 'argv docker logout' "${STUB_LOG}")" "Docker Hub's logout has no server"
if [[ -e "${RUNNER_TEMP}/registry-logins.docker" ]]; then fail "the ledger is removed"; else pass; fi
group "oneuptime/dev"
export STUB_FAIL_HOSTS="quay.io"
registry_resolve image "quay.io/oneuptime/api" > /dev/null 2>&1
registry_login crane 0 > "${OUT}" 2>&1
assert_eq "1" "$?" "a refused login fails"
assert_contains "crane login to quay.io with REGISTRY_CONFIG group 'oneuptime/dev' was refused." "$(cat "${OUT}")" "and says so"
assert_not_contains $'quay\tsecret' "$(grep -v '^::add-mask::' "${OUT}")" "without the password"
group "broken/empty"
registry_resolve image "quay.io/oneuptime/api" > /dev/null 2>&1
registry_login --optional crane 0 > "${OUT}" 2>&1
assert_eq "0|" "$?|$(cat "${STUB_LOG}")" "an optional login without credentials is anonymous"
assert_contains "No credentials for quay.io; using it anonymously." "$(cat "${OUT}")" "and says so"
registry_login crane 0 > "${OUT}" 2>&1
assert_eq "1" "$?" "a required login without credentials fails"
assert_contains "REGISTRY_CONFIG group 'broken/empty' has no username and password for quay.io." "$(cat "${OUT}")" "naming the group"
reset
export IMAGE_REGISTRY="registry.example.com"
registry_resolve image "core/api" > /dev/null 2>&1
registry_login crane 0 > "${OUT}" 2>&1
assert_contains "No credentials for registry.example.com. Set secrets.IMAGE_REGISTRY_USERNAME and secrets.IMAGE_REGISTRY_PASSWORD" "$(cat "${OUT}")" "or the pair"
registry_login podman 0 > "${OUT}" 2>&1
assert_eq "2" "$?" "an unknown tool"
reset
export CHART_DEPENDENCY_REGISTRY="deps.example.com" CHART_DEPENDENCY_REGISTRY_USERNAME="dep-user" CHART_DEPENDENCY_REGISTRY_PASSWORD="dep-secret"
registry_resolve dependency > /dev/null 2>&1
registry_login helm 0 > "${OUT}" 2>&1
assert_contains "argv helm registry login deps.example.com --username dep-user --password-stdin" "$(cat "${STUB_LOG}")" "dependencies log in with their own pair"

# --- login.sh -------------------------------------------------------------------
group "oneuptime/dev"
TOOL=helm KIND=chart REPOSITORIES="charts.example.com/helm quay.io/oneuptime/charts" bash "${SCRIPTS}/login.sh" > "${OUT}" 2>&1
assert_eq "0|1" "$?|$(count "argv helm registry login" "${STUB_LOG}")" "login.sh logs in to the primary only"
assert_contains "argv helm registry login charts.example.com --username chart-user --password-stdin" "$(cat "${STUB_LOG}")" "the chart primary"
assert_contains "::add-mask::chart-secret" "$(cat "${OUT}")" "an executed login still masks"
group "oneuptime/dev"
TOOL=docker KIND=image REPOSITORIES="" bash "${SCRIPTS}/login.sh" > "${OUT}" 2>&1
assert_eq "1" "$?" "login.sh needs the repositories with a group"
reset
export IMAGE_REGISTRY="registry.example.com" IMAGE_REGISTRY_USERNAME="pair-user" IMAGE_REGISTRY_PASSWORD="pair-secret"
TOOL=docker KIND=image bash "${SCRIPTS}/login.sh" > "${OUT}" 2>&1
assert_contains "argv docker login --username pair-user --password-stdin registry.example.com" "$(cat "${STUB_LOG}")" "login.sh with a single registry"
reset
export IMAGE_REGISTRY="registry.example.com"
TOOL=crane KIND=image OPTIONAL=true bash "${SCRIPTS}/login.sh" > "${OUT}" 2>&1
assert_eq "0|" "$?|$(cat "${STUB_LOG}")" "login.sh OPTIONAL without credentials"

# --- targets.sh -----------------------------------------------------------------
reset
: > "${GITHUB_OUTPUT}"
IMAGE_REGISTRY="registry.example.com" KIND=image REPOSITORIES="core/api/dev" TAG="1.4.0-7.1" \
  bash "${SCRIPTS}/targets.sh" > "${OUT}" 2>&1
assert_eq "0" "$?" "targets.sh"
assert_eq "primary=registry.example.com
repository=core/api/dev
ref=registry.example.com/core/api/dev:1.4.0-7.1
others=false" "$(cat "${GITHUB_OUTPUT}")" "one registry keeps its one reference"
group "oneuptime/dev"
: > "${GITHUB_OUTPUT}"
KIND=image REPOSITORIES="docker.io/oneuptime/api-dev quay.io/oneuptime/api/dev" TAG="1.4.0-7.1" bash "${SCRIPTS}/targets.sh" > "${OUT}" 2>&1
assert_eq "primary=docker.io
repository=oneuptime/api-dev
ref=docker.io/oneuptime/api-dev:1.4.0-7.1
others=true" "$(cat "${GITHUB_OUTPUT}")" "a group publishes its primary"
assert_contains "Target: quay.io/oneuptime/api/dev:1.4.0-7.1" "$(cat "${OUT}")" "targets.sh lists every repository"
assert_not_contains "secret" "$(cat "${OUT}" "${GITHUB_OUTPUT}")" "and no credentials"

# --- mirror-image.sh ----------------------------------------------------------------
cd "${WORK}" || exit 1
reset
: > "${GITHUB_STEP_SUMMARY}"
IMAGE_REGISTRY="registry.example.com" REPOSITORY="core/api" TAG="1.4.0" \
  bash "${SCRIPTS}/mirror-image.sh" > "${OUT}" 2>&1
assert_eq "0|" "$?|$(cat "${STUB_LOG}")" "mirror-image.sh does nothing for one repository"

group "oneuptime/dev"
rm -f IMAGE_INFO.md
REPOSITORY="registry.example.com/core/api docker.io/oneuptime/api docker.io/oneuptime/api-mirror quay.io/oneuptime/api" TAG="1.4.0" ALIASES=true \
  bash "${SCRIPTS}/mirror-image.sh" > "${OUT}" 2>&1
assert_eq "0" "$?" "mirror-image.sh copies a release"
LOG="$(cat "${STUB_LOG}")"
assert_eq "3" "$(count "argv crane auth login" "${STUB_LOG}")" "each registry is logged in to once"
assert_contains "argv crane digest registry.example.com/core/api:1.4.0" "${LOG}" "the primary's digest is read"
assert_contains "argv crane copy registry.example.com/core/api@${DIGEST_A} docker.io/oneuptime/api:1.4.0" "${LOG}" "copied by digest"
assert_contains "argv crane copy registry.example.com/core/api@${DIGEST_A} docker.io/oneuptime/api-mirror:1.4.0" "${LOG}" "to a second repository on one registry"
assert_contains "argv crane copy registry.example.com/core/api@${DIGEST_A} quay.io/oneuptime/api:1.4.0" "${LOG}" "and to another registry"
assert_contains "argv crane tag quay.io/oneuptime/api:1.4.0 1.4" "${LOG}" "release aliases are tagged in each copy"
assert_contains "| \`docker.io/oneuptime/api-mirror:1.4.0\` | \`${DIGEST_A}\` |" "$(cat IMAGE_INFO.md)" "IMAGE_INFO lists the copies"

group "oneuptime/dev"
export STUB_FAIL_HOSTS="quay.io"
REPOSITORY="registry.example.com/core/api quay.io/oneuptime/api docker.io/oneuptime/api" TAG="1.4.0-7.1" \
  bash "${SCRIPTS}/mirror-image.sh" > "${OUT}" 2>&1
assert_eq "1" "$?" "mirror-image.sh fails when a registry fails"
assert_contains "was not copied to: quay.io/oneuptime/api." "$(cat "${OUT}")" "the failed repository is named"
assert_contains "argv crane copy registry.example.com/core/api@${DIGEST_A} docker.io/oneuptime/api:1.4.0-7.1" "$(cat "${STUB_LOG}")" "the repository after a failed one is still tried"
assert_not_contains "argv crane tag" "$(cat "${STUB_LOG}")" "candidates get no aliases"
group "oneuptime/dev"
export STUB_OTHER_DIGEST_HOST="docker.io"
REPOSITORY="registry.example.com/core/api docker.io/oneuptime/api" TAG="1.4.0-7.1" \
  bash "${SCRIPTS}/mirror-image.sh" > "${OUT}" 2>&1
assert_eq "1" "$?" "a copy under another digest fails"
assert_contains "docker.io/oneuptime/api:1.4.0-7.1 resolves to" "$(cat "${OUT}")" "and says so"

# --- chart push and dependencies ----------------------------------------------------
mkdir -p "${WORK}/push"
cd "${WORK}/push" || exit 1
touch api-1.4.0-7.1.tgz
group "oneuptime/dev"
CHART_NAME=api CHART_VERSION=1.4.0-7.1 CHART_REPOSITORY="charts.example.com/helm/dev quay.io/oneuptime/charts/dev" \
  bash "${ROOT}/scripts/chart/push.sh" > "${OUT}" 2>&1
assert_eq "0" "$?" "push.sh publishes to every repository"
assert_contains "argv helm push api-1.4.0-7.1.tgz oci://charts.example.com/helm/dev" "$(cat "${STUB_LOG}")" "the primary"
assert_contains "argv helm push api-1.4.0-7.1.tgz oci://quay.io/oneuptime/charts/dev" "$(cat "${STUB_LOG}")" "and the other"
assert_eq "1" "$(count "argv helm registry login quay.io" "${STUB_LOG}")" "only the other registry logs in here"
assert_contains "oci://quay.io/oneuptime/charts/dev" "$(cat CHART_INFO.md)" "CHART_INFO lists both"
group "oneuptime/dev"
export STUB_FAIL_HOSTS="oci://quay.io"
CHART_NAME=api CHART_VERSION=1.4.0-7.1 CHART_REPOSITORY="charts.example.com/helm/dev quay.io/oneuptime/charts/dev" \
  bash "${ROOT}/scripts/chart/push.sh" > "${OUT}" 2>&1
assert_eq "1" "$?" "a refused repository fails the push"
assert_contains "was not published to: quay.io/oneuptime/charts/dev." "$(cat "${OUT}")" "and is named"
group "oneuptime/dev"
CHART_REPOSITORY="charts.example.com/helm quay.io/oneuptime/charts" bash "${ROOT}/scripts/chart/registry.sh" dependencies > "${OUT}" 2>&1
assert_eq "0|2" "$?|$(count "argv helm registry login" "${STUB_LOG}")" "dependencies log in to every chart registry of a group"
group "oneuptime/dev"
CHART_REPOSITORY="" bash "${ROOT}/scripts/chart/registry.sh" dependencies > "${OUT}" 2>&1
assert_eq "0|" "$?|$(cat "${STUB_LOG}")" "and to none without chart repositories"
cd "${ROOT}" || exit 1

# --- image-tag-check.sh ----------------------------------------------------------------
group "oneuptime/dev"
: > "${GITHUB_STEP_SUMMARY}"
STUB_MISSING="quay.io/oneuptime/api:1.4.0" IMAGE_REPOSITORY="docker.io/oneuptime/api quay.io/oneuptime/api" IMAGE_TAG="1.4.0" \
  bash "${ROOT}/scripts/checks/image-tag-check.sh" > "${OUT}" 2>&1
assert_eq "1" "$?" "a tag taken in any repository fails"
assert_contains "\`docker.io/oneuptime/api:1.4.0\` is already taken" "$(cat "${GITHUB_STEP_SUMMARY}")" "and is named"
assert_contains "Nothing is published at \`quay.io/oneuptime/api:1.4.0\`" "$(cat "${GITHUB_STEP_SUMMARY}")" "while the free one is reported free"
group "oneuptime/dev"
STUB_MISSING="docker.io/oneuptime/api:1.4.0 quay.io/oneuptime/api:1.4.0" IMAGE_REPOSITORY="docker.io/oneuptime/api quay.io/oneuptime/api" IMAGE_TAG="1.4.0" \
  bash "${ROOT}/scripts/checks/image-tag-check.sh" > "${OUT}" 2>&1
assert_eq "0" "$?" "a tag free everywhere passes"

# --- logout.sh never fails ---------------------------------------------------------
reset
bash "${SCRIPTS}/logout.sh" > "${OUT}" 2>&1
assert_eq "0" "$?" "logout.sh without a ledger"

# --- init: validate-config.sh -------------------------------------------------------
VALIDATE="${ROOT}/scripts/init/validate-config.sh"
PROJECT="${WORK}/project"
mkdir -p "${PROJECT}/chart"
touch "${PROJECT}/Dockerfile"
printf 'name: api\nversion: 1.0.0\n' > "${PROJECT}/chart/Chart.yaml"
validate() {
  : > "${GITHUB_STEP_SUMMARY}"
  (cd "${PROJECT}" && env "$@" bash "${VALIDATE}") > "${OUT}" 2>&1
}

reset
validate PROJECT_REGISTRY_NAME="oneuptime/dev" REGISTRY_CONFIG="${CONFIG}" IMAGE_REGISTRY_INPUT="registry.example.com" \
  IGNORE_DOCKER_INPUT=true IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "init stops on a group and a registry variable, even with nothing to publish"
assert_contains "vars.PROJECT_REGISTRY_NAME and vars.IMAGE_REGISTRY are both set" "$(cat "${OUT}")" "init names both variables"
assert_contains "is set together with" "$(cat "${GITHUB_STEP_SUMMARY}")" "init's summary says why"
validate PROJECT_REGISTRY_NAME="oneuptime/dev" REGISTRY_CONFIG="${CONFIG}" CHART_REGISTRY_INPUT="registry.example.com" \
  IGNORE_DOCKER_INPUT=true IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "init stops on a group and CHART_REGISTRY"

validate PROJECT_REGISTRY_NAME="oneuptime/dev" REGISTRY_CONFIG="${CONFIG}" \
  IMAGE_REPOSITORY_INPUT="registry.example.com/core/api docker.io/oneuptime/api docker.io/oneuptime/api-mirror" \
  CHART_REPOSITORY_INPUT="oci://charts.example.com/helm"
assert_eq "0" "$?" "init accepts a group's full repositories"
assert_eq "1" "$(count "::add-mask::hub%25secret" "${OUT}")" "each registry's password is masked once"
validate PROJECT_REGISTRY_NAME="oneuptime/dev" REGISTRY_CONFIG="${CONFIG_FILE}" \
  IMAGE_REPOSITORY_INPUT="quay.io/oneuptime/api" IGNORE_CHART_INPUT=true
assert_eq "0" "$?" "init reads REGISTRY_CONFIG from a file"
validate PROJECT_REGISTRY_NAME="oneuptime/dev" REGISTRY_CONFIG="${CONFIG}" \
  IMAGE_REPOSITORY_INPUT="ghcr.io/oneuptime/api" IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "init refuses a registry outside the group"
assert_contains "is not in REGISTRY_CONFIG group 'oneuptime/dev'" "$(cat "${OUT}")" "init names it"
assert_contains "The registry configuration is inconsistent" "$(cat "${GITHUB_STEP_SUMMARY}")" "init's summary points at the annotations"
validate PROJECT_REGISTRY_NAME="broken/empty" REGISTRY_CONFIG="${CONFIG}" \
  IMAGE_REPOSITORY_INPUT="quay.io/oneuptime/api" IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "init refuses a registry without credentials"
assert_contains "REGISTRY_CONFIG group 'broken/empty' has no username and password for quay.io." "$(cat "${OUT}")" "init names it"
validate PROJECT_REGISTRY_NAME="oneuptime/dev" REGISTRY_CONFIG="${CONFIG}" IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "init needs the repositories of a published artifact"
assert_contains "Set these organisation or repository variables: vars.IMAGE_REPOSITORY" "$(cat "${OUT}")" "init lists them"
validate PROJECT_REGISTRY_NAME="oneuptime/staging" REGISTRY_CONFIG="${CONFIG}" IGNORE_CHART_INPUT=true
assert_contains "names group 'oneuptime/staging', which REGISTRY_CONFIG does not define" "$(cat "${OUT}")" "a missing group is reported with them"
validate PROJECT_REGISTRY_NAME="oneuptime/dev" REGISTRY_CONFIG=$'oneuptime/dev:\n  quay.io: [\n' \
  IMAGE_REPOSITORY_INPUT="quay.io/oneuptime/api" IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "init refuses malformed YAML"

validate IMAGE_REGISTRY_INPUT="registry.example.com quay.io" IMAGE_REPOSITORY_INPUT="core/api" \
  IMAGE_REGISTRY_USERNAME=u IMAGE_REGISTRY_PASSWORD=p IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "init refuses a host list"
assert_contains "takes one" "$(cat "${OUT}")" "init points at PROJECT_REGISTRY_NAME"
validate IGNORE_CHART_INPUT=true
assert_eq "1" "$?" "a single registry still reports what is missing"
assert_contains "Set these organisation or repository variables: vars.IMAGE_REGISTRY vars.IMAGE_REPOSITORY secrets.IMAGE_REGISTRY_USERNAME secrets.IMAGE_REGISTRY_PASSWORD" "$(cat "${OUT}")" "word for word as before"

# --- no password ever reached a command line ---------------------------------------------
for SECRET in "${SECRETS[@]}"; do
  assert_not_contains "${SECRET}" "$(cat "${STUB_ARGV}")" "no command line carries ${SECRET%%$'\t'*}"
done

echo "${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
