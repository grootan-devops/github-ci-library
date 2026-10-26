#!/usr/bin/env bash
# Shared OCI validation and lookup. Source this file; it performs no network I/O on load.
#
# The chart registries are CHART_REGISTRY, or with PROJECT_REGISTRY_NAME the
# registries of the full repositories CHART_REPOSITORY lists
# (scripts/registry/lib.sh). The first is the primary, which these helpers
# default to.

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../registry/lib.sh"

# Resolve the chart registries, from CHART_REPOSITORY, into lib.sh's
# REGISTRY_* arrays.
chart_registry_validate() {
  chart_registry_targets "${CHART_REPOSITORY:-}" ""
}

# Resolve the chart registries, pairing them with REPOSITORIES and, when it is
# not empty, DEV_REPOSITORIES.
chart_registry_targets() {
  if ! registry_named && [[ -z "${CHART_REGISTRY:-}" ]]; then
    echo "::error title=Chart registry::Set vars.CHART_REGISTRY to an OCI registry hostname, or name a REGISTRY_CONFIG group in vars.PROJECT_REGISTRY_NAME and list full repositories in vars.CHART_REPOSITORY. GitHub has no package-registry fallback." >&2
    return 1
  fi
  registry_resolve chart "$1" "$2" || return 1
}

# Log Helm in to the registry of chart repository INDEX, the primary by default.
# Resolve the registries first.
chart_registry_login() {
  registry_login helm "${1:-0}" || return 1
}

# Return 0 for present, 1 for confirmed absence, 2 for operational errors.
# Successful metadata is returned on stdout for candidate-version resolution.
chart_oci_lookup() {
  local LOOKUP_REF="$1" LOOKUP_VERSION="$2" LOOKUP_OUTPUT
  if LOOKUP_OUTPUT=$(helm show chart "${LOOKUP_REF}" --version "${LOOKUP_VERSION}" 2>&1); then
    printf '%s\n' "${LOOKUP_OUTPUT}"
    return 0
  fi
  case "${LOOKUP_OUTPUT}" in
    *401*|*403*|*Unauthorized*|*unauthorized*|*denied*|*timeout*|*connection*|*"no such host"*|*x509*|*executable*|*"command not found"*) ;;
    *"not found"*|*"404 Not Found"*|*MANIFEST_UNKNOWN*|*NAME_UNKNOWN*|*"Unable to locate any tags in provided repository"*|*"Could not locate a version matching provided version string"*) return 1 ;;
  esac
  echo "::error title=Chart registry::OCI lookup failed; chart availability cannot be confirmed. Check connectivity and access." >&2
  return 2
}

# Dependencies come from vars.CHART_DEPENDENCY_REGISTRY, with its own secret
# pair, when it is set. Otherwise Helm logs in to the chart registries: with
# vars.PROJECT_REGISTRY_NAME to every registry CHART_REPOSITORY names, since a
# dependency may live on any of them, and to a single registry only when it
# has credentials, since public and file:// dependencies need none. Runs in a
# subshell, so the caller's resolved chart registries are left as they were.
chart_dependency_login() (
  if [[ -n "${CHART_DEPENDENCY_REGISTRY:-}" ]]; then
    registry_resolve dependency || exit 1
    registry_login helm 0 || exit 1
    exit 0
  fi
  if registry_named; then
    if [[ -z "${CHART_REPOSITORY:-}" ]]; then
      exit 0
    fi
    chart_registry_validate || exit 1
    for I in "${!REGISTRY_HOSTS[@]}"; do
      registry_login --optional helm "${I}" || exit 1
    done
    exit 0
  fi
  if [[ -z "${CHART_REGISTRY_USERNAME:-}${CHART_REGISTRY_PASSWORD:-}" ]]; then
    exit 0
  fi
  chart_registry_validate || exit 1
  chart_registry_login || exit 1
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  if [[ "${1:-}" == "dependencies" ]]; then
    chart_dependency_login
  else
    chart_registry_validate
    chart_registry_login
  fi
fi
