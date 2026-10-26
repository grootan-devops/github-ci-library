#!/usr/bin/env bash
# Shared OCI validation and lookup. Source this file; it performs no network I/O on load.

chart_registry_validate() {
  if [[ -z "${CHART_REGISTRY:-}" ]]; then
    echo "::error title=Chart registry::Set vars.CHART_REGISTRY to an OCI registry hostname. GitHub has no package-registry fallback." >&2
    return 1
  fi
  case "${CHART_REGISTRY}" in
    *://*|*/*|*@*|*[[:space:]]*)
      echo "::error title=Chart registry::CHART_REGISTRY must be an OCI hostname, optionally with a port; put the namespace in CHART_REPOSITORY." >&2
      return 1
      ;;
  esac
}

chart_registry_login() {
  chart_registry_validate || return 1
  if [[ -z "${CHART_REGISTRY_USERNAME:-}" || -z "${CHART_REGISTRY_PASSWORD:-}" ]]; then
    echo "::error title=Chart registry::Set secrets.CHART_REGISTRY_USERNAME and secrets.CHART_REGISTRY_PASSWORD; pass secrets: inherit." >&2
    return 1
  fi
  if ! printf '%s' "${CHART_REGISTRY_PASSWORD}" | helm registry login "${CHART_REGISTRY}" \
    --username "${CHART_REGISTRY_USERNAME}" --password-stdin >/dev/null 2>&1; then
    echo "::error title=Chart registry::OCI authentication failed. Check chart credentials and registry access." >&2
    return 1
  fi
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

chart_dependency_login() {
  local CHART_REGISTRY="${CHART_REGISTRY:-}"
  local CHART_REGISTRY_USERNAME="${CHART_REGISTRY_USERNAME:-}"
  local CHART_REGISTRY_PASSWORD="${CHART_REGISTRY_PASSWORD:-}"
  if [[ -n "${CHART_DEPENDENCY_REGISTRY:-}" ]]; then
    CHART_REGISTRY="${CHART_DEPENDENCY_REGISTRY}"
    CHART_REGISTRY_USERNAME="${CHART_DEPENDENCY_REGISTRY_USERNAME:-}"
    CHART_REGISTRY_PASSWORD="${CHART_DEPENDENCY_REGISTRY_PASSWORD:-}"
  elif [[ -z "${CHART_REGISTRY_USERNAME:-}${CHART_REGISTRY_PASSWORD:-}" ]]; then
    # Public and file:// dependencies require no registry credentials.
    return 0
  fi
  chart_registry_login
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  if [[ "${1:-}" == "dependencies" ]]; then
    chart_dependency_login
  else
    chart_registry_login
  fi
fi
