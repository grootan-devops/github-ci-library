#!/usr/bin/env bash
# Shared OCI validation and lookup. Source this file; it performs no network I/O on load.

# The chart host comes from scripts/registry/auth.sh (its chart-registry output), which
# also wrote the credentials every helm call reads through HELM_REGISTRY_CONFIG.
chart_registry_validate() {
  if [[ -z "${CHART_REGISTRY:-}" ]]; then
    echo "::error title=Chart registry::No chart registry: run scripts/registry/auth.sh and pass its chart-registry output as CHART_REGISTRY." >&2
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
