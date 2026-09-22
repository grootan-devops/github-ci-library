#!/usr/bin/env bash
# Verifies MIGRATION.md documents the upgrade path into the release version and
# extracts that section for the release notes.
# GitLab counterpart: `Migration:Check Existence`.
set -euo pipefail

: "${RELEASE_VERSION:?RELEASE_VERSION must be set}"
: "${MIGRATION_FILE_NAME:=./MIGRATION.md}"
: "${RELEASE_MIGRATION_FILE_NAME:=RELEASE_MIGRATION.md}"
: "${PREVIOUS_RELEASE_VERSION:=}"

echo "🔍 Verifying migration requirements for release version ${RELEASE_VERSION}..."

CURRENT_MAJOR=$(grep -Eo '^[0-9]+' <<<"${RELEASE_VERSION}" || true)
if [[ -z "${CURRENT_MAJOR}" ]]; then
  echo "::error title=Migration guide::Could not parse major version from RELEASE_VERSION='${RELEASE_VERSION}'."
  exit 1
fi

if [[ -z "${PREVIOUS_RELEASE_VERSION}" ]]; then
  API_TAGS=""
  if [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    # curl, not `gh`: the guard runs inside the toolkit container, which does
    # not ship the GitHub CLI, so a `gh` call here returned nothing and the
    # fallback below silently became the only source of tags.
    API_TAGS=$(curl -sSf \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/tags?per_page=100" \
      | jq -r '.[].name // empty') || API_TAGS=""
  fi

  GIT_TAGS=$(git tag -l 2>/dev/null || true)
  if [[ -z "${GIT_TAGS}" ]]; then
    git fetch --tags --depth=50 origin 2>/dev/null || true
    GIT_TAGS=$(git tag -l 2>/dev/null || true)
  fi

  ALL_TAGS=$(printf "%s\n%s\n" "${API_TAGS}" "${GIT_TAGS}" \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' \
    | sed 's/^v//' \
    | grep -v "^${RELEASE_VERSION}$" \
    | sort -uV || true)
  PREVIOUS_RELEASE_VERSION=$(tail -n 1 <<<"${ALL_TAGS}" || true)
fi

echo "ℹ️ Target Release Version: ${RELEASE_VERSION} (Major: ${CURRENT_MAJOR})"
echo "ℹ️ Previous Release Version: ${PREVIOUS_RELEASE_VERSION:-none}"

summarise() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "${1}" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

if [[ -z "${PREVIOUS_RELEASE_VERSION}" ]]; then
  echo "ℹ️ Notice: No previous release found in repository. Initial release detected."
  echo "Migration guide check is skipped for initial release."
  exit 0
fi

PREVIOUS_MAJOR=$(grep -Eo '^[0-9]+' <<<"${PREVIOUS_RELEASE_VERSION}" || true)

echo "🔍 Verifying migration documentation: ${PREVIOUS_RELEASE_VERSION} -> ${RELEASE_VERSION}"
echo "Every release (major, minor, or patch) requires documented migration/compatibility notes in ${MIGRATION_FILE_NAME}."

if [[ ! -f "${MIGRATION_FILE_NAME}" ]]; then
  echo "::error title=Migration guide::Migration file '${MIGRATION_FILE_NAME}' is missing. Release ${PREVIOUS_RELEASE_VERSION} -> ${RELEASE_VERSION} cannot proceed without it."
  summarise "### 🧭 Migration guide
❌ \`${MIGRATION_FILE_NAME}\` is missing. Document the ${PREVIOUS_RELEASE_VERSION} → ${RELEASE_VERSION} upgrade (or state 'No migration required')."
  exit 1
fi

AWK_EXIT=0
awk -v p_ver="${PREVIOUS_RELEASE_VERSION}" \
    -v p_maj="${PREVIOUS_MAJOR}" \
    -v c_ver="${RELEASE_VERSION}" \
    -v c_maj="${CURRENT_MAJOR}" '
  BEGIN {
    gsub(/\./, "\\.", p_ver);
    gsub(/\./, "\\.", c_ver);
    re_range = "^##[[:space:]]+(Release[[:space:]]+)?v?" p_ver "[[:space:]]*(\\.\\.\\.|\\.\\.|\\->|to)[[:space:]]*v?" c_ver "([[:space:]]|$)";
    re_single = "^##[[:space:]]+(Release[[:space:]]+)?v?" c_ver "([[:space:]]|$)";
    re_major = "^##[[:space:]]+(Release[[:space:]]+)?v?" p_maj "(\\.x|\\.[0-9]+)*[[:space:]]*(\\.\\.\\.|\\.\\.|\\->|to)[[:space:]]*v?" c_maj "(\\.x|\\.[0-9]+)*([[:space:]]|$)";
  }
  {
    clean_line = $0;
    gsub(/[`\[\]]/, "", clean_line);
  }
  clean_line ~ re_range || clean_line ~ re_single || (p_maj != c_maj && clean_line ~ re_major) {
    found = 1;
    p = 1;
    print;
    next;
  }
  p && /^##[[:space:]]+/ {
    exit;
  }
  p {
    print;
  }
  END {
    if (!found) exit 2;
  }
' "${MIGRATION_FILE_NAME}" > "${RELEASE_MIGRATION_FILE_NAME}" || AWK_EXIT=$?

if [[ "${AWK_EXIT}" -eq 2 || ! -s "${RELEASE_MIGRATION_FILE_NAME}" ]]; then
  echo "::error title=Migration guide::Missing migration entry in ${MIGRATION_FILE_NAME} for ${PREVIOUS_RELEASE_VERSION} -> ${RELEASE_VERSION}."
  echo "Required Action: Add a section to ${MIGRATION_FILE_NAME} with the following heading:"
  echo "## [${PREVIOUS_RELEASE_VERSION}...${RELEASE_VERSION}] - $(date +%Y-%m-%d)"
  summarise "### 🧭 Migration guide
❌ No section in \`${MIGRATION_FILE_NAME}\` covers ${PREVIOUS_RELEASE_VERSION} → ${RELEASE_VERSION}.

Add:
\`\`\`markdown
## [${PREVIOUS_RELEASE_VERSION}...${RELEASE_VERSION}] - $(date +%Y-%m-%d)
\`\`\`
covering upgrade instructions and breaking changes (or stating 'No migration required')."
  exit 1
fi

BODY_LINES=$(grep -v "^##" "${RELEASE_MIGRATION_FILE_NAME}" | grep -c '[^[:space:]]' || true)
if [[ "${BODY_LINES}" -lt 1 ]]; then
  echo "::error title=Migration guide::The section for ${PREVIOUS_RELEASE_VERSION}...${RELEASE_VERSION} lacks content. At minimum, state 'No migration required'."
  summarise "### 🧭 Migration guide
❌ The ${PREVIOUS_RELEASE_VERSION} → ${RELEASE_VERSION} section is empty. At minimum, state 'No migration required'."
  exit 1
fi

echo "✅ Successfully verified and extracted migration guide for ${PREVIOUS_RELEASE_VERSION}...${RELEASE_VERSION}:"
cat "${RELEASE_MIGRATION_FILE_NAME}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 🧭 Migration guide: ${PREVIOUS_RELEASE_VERSION} → ${RELEASE_VERSION}"
    echo ""
    cat "${RELEASE_MIGRATION_FILE_NAME}"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi
