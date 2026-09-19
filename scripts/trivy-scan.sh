#!/usr/bin/env bash
# Unified Trivy security, misconfiguration, SBOM and license scanner.
# Port of the GitLab `.scan-script` job template; same exit codes and contract.
# Exit codes: 0 clean, 1 errors (fixable findings, stale or unjustified
# suppressions), 2 warnings only (unfixable findings, justified suppressions).
# Nameref indirection and jq-driven word splitting are deliberate throughout.
# shellcheck disable=SC2034,SC2178,SC2207
set -uo pipefail

: "${SCAN_TYPE:?SCAN_TYPE must be set}"
: "${TRIVY_SCAN_REPORT_NAME:?TRIVY_SCAN_REPORT_NAME must be set}"

: "${SKIP_CVE_SCAN:=false}"
: "${TRIVY_IGNORE_CONFIG_FILE:=ignored-cves.yml}"
: "${TRIVY_TIMEOUT:=60m}"
: "${TRIVY_IGNORE_CVES:=}"
: "${TRIVY_IGNORED_LICENSE_CLASSIFICATIONS:=notice,permissive,unencumbered}"
: "${SBOM_FILE:=sbom.cdx.json}"
: "${IAC_SCAN_PATH:=.}"
: "${IMAGE_CVE_INFO_FILE_NAME:=IMAGE_CVE.md}"
: "${CHART_CVE_INFO_FILE_NAME:=CHART_CVE.md}"
: "${TF_CVE_INFO_FILE_NAME:=TF_CVE.md}"
: "${LICENSE_INFO_FILE_NAME:=LICENSE_CVE.md}"
: "${SBOM_CVE_INFO_FILE_NAME:=SBOM_CVE.md}"
: "${IMAGE_DEV_REPOSITORY_SUFFIX:=}"

if [[ -z "${IMAGE_DEV_REPOSITORY_SUFFIX}" ]]; then
  case "${IMAGE_REGISTRY:-}" in
    docker.io|index.docker.io|registry-1.docker.io) IMAGE_DEV_REPOSITORY_SUFFIX="-dev" ;;
    *) IMAGE_DEV_REPOSITORY_SUFFIX="/dev" ;;
  esac
fi
: "${TARGET_VERSION:=}"
: "${RELEASE_VERSION:=}"
: "${IMAGE_REGISTRY:=}"
: "${IMAGE_REPOSITORY:=}"
: "${IMAGE_REF:=}"
: "${CONFIG_TYPE:=}"

declare -A IGNORED_ITEM_REASONS
EXIT_CODE=0
REASONS=()
MISSING_REASONS=()
INVALID_REASONS=()
FINAL_FIXABLE=()
FINAL_FIXABLE_IGNORED=()
FINAL_UNFIXABLE=()
FINAL_FIXED_IGNORED=()
FINAL_NOTICE=()
FINAL_NOTICE_IGNORED=()
FINAL_PERMISSIVE=()
FINAL_PERMISSIVE_IGNORED=()
FINAL_RECIPROCAL=()
FINAL_RECIPROCAL_IGNORED=()
FINAL_RESTRICTED=()
FINAL_RESTRICTED_IGNORED=()
FINAL_UNRECOGNIZED=()
FINAL_UNRECOGNIZED_IGNORED=()
cleanup() {
  local FILES=("${IGNORED_ITEMS_FILE}" "${JUNIT_TPL_FILE}" "${ALL_FIXABLE_FILE}" "${ALL_UNFIXABLE_FILE}" "${ALL_FOUND_FILE}" "${ALL_NOTICE_FILE}" "${ALL_PERMISSIVE_FILE}" "${ALL_RECIPROCAL_FILE}" "${ALL_RESTRICTED_FILE}" "${ALL_UNRECOGNIZED_FILE}")
  rm -f "${FILES[@]}"
}

log() {
  echo "[${1}] ${2}"
}

log_info() {
  log "INFO" "${*}"
}

log_warn() {
  log "WARN" "${*}" >&2
}

log_error() {
  log "ERROR" "${*}" >&2
}

print_separator() {
  echo "========================================"
}

# Early failures never reach publish_step_summary, so they write their own section.
summarise_abort() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### 🛡️ Trivy ${SCAN_TYPE:-security} scan"
      echo ""
      echo "❌ ${1}"
      echo ""
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
}
get_ignore_config_path() {
  case "${SCAN_TYPE}" in
    image) echo "image" ;;
    config) echo "iac.${CONFIG_TYPE}" ;;
    license) echo "license" ;;
    sbom) echo "sbom" ;;
  esac
}

get_summary_file_name() {
  case "${SCAN_TYPE}" in
    image)
      echo "${IMAGE_CVE_INFO_FILE_NAME}"
      ;;
    config)
      if [[ "${CONFIG_TYPE}" == "chart" ]]; then
        echo "${CHART_CVE_INFO_FILE_NAME}"
      else
        echo "${TF_CVE_INFO_FILE_NAME}"
      fi
      ;;
    license)
      echo "${LICENSE_INFO_FILE_NAME}"
      ;;
    sbom)
      echo "${SBOM_CVE_INFO_FILE_NAME}"
      ;;
  esac
}
is_valid_reason() {
  local REASON="${1}"
  local TRIMMED="${REASON#"${REASON%%[![:space:]]*}"}"
  TRIMMED="${TRIMMED%"${TRIMMED##*[![:space:]]}"}"
  if [[ ${#TRIMMED} -lt 10 ]]; then
    return 1
  fi
  local PLACEHOLDERS=("todo" "tbd" "n/a" "na" "fix" "fixme" "later" "wip" "placeholder" "none" "unknown" "ignore" "skip" "test" "temp")
  local LOWER
  LOWER=$(echo "${TRIMMED}" | tr '[:upper:]' '[:lower:]')
  for PLACEHOLDER in "${PLACEHOLDERS[@]}"; do
    if [[ "${LOWER}" == "${PLACEHOLDER}" ]]; then
      return 1
    fi
  done
  return 0
}

validate_scan_type() {
  local VALID_TYPES=("image" "config" "license" "sbom")
  if [[ -z "${SCAN_TYPE}" ]]; then
    log_error "SCAN_TYPE is not set. Valid values: ${VALID_TYPES[*]}"
    log_error "Example: export SCAN_TYPE=image"
    summarise_abort "\`SCAN_TYPE\` is not set. Pass \`scan-type\` as one of: ${VALID_TYPES[*]}."
    exit 1
  fi
  if [[ ! " ${VALID_TYPES[*]} " == *" ${SCAN_TYPE} "* ]]; then
    log_error "Invalid SCAN_TYPE '${SCAN_TYPE}'. Valid values: ${VALID_TYPES[*]}"
    summarise_abort "\`${SCAN_TYPE}\` is not a scan type. Pass \`scan-type\` as one of: ${VALID_TYPES[*]}."
    exit 1
  fi
  log_info "Scan type: ${SCAN_TYPE}"
  if [[ "${SCAN_TYPE}" == "config" ]]; then
    validate_config_type
  fi
}

validate_config_type() {
  local VALID_CONFIG_TYPES=("chart" "terraform")
  if [[ -z "${CONFIG_TYPE}" ]]; then
    log_error "CONFIG_TYPE is not set for config scan. Valid values: ${VALID_CONFIG_TYPES[*]}"
    summarise_abort "\`config-type\` is required when \`scan-type\` is \`config\`. Pass one of: ${VALID_CONFIG_TYPES[*]}."
    exit 1
  fi
  if [[ ! " ${VALID_CONFIG_TYPES[*]} " == *" ${CONFIG_TYPE} "* ]]; then
    log_error "Invalid CONFIG_TYPE '${CONFIG_TYPE}'. Valid values: ${VALID_CONFIG_TYPES[*]}"
    summarise_abort "\`${CONFIG_TYPE}\` is not a config type. Pass \`config-type\` as one of: ${VALID_CONFIG_TYPES[*]}."
    exit 1
  fi
  log_info "Config type: ${CONFIG_TYPE}"
}
# Trivy treats --skip-java-db-update on a cold cache as fatal, so skip only what is cached.
TRIVY_ARGS=""
if [[ -n "${TRIVY_CACHE_DIR:-}" ]] && compgen -G "${TRIVY_CACHE_DIR}/java-db/*" > /dev/null 2>&1; then
  TRIVY_ARGS="--skip-java-db-update"
fi
build_trivy_command() {
  local BASE_CMD=""
  case "${SCAN_TYPE}" in
    image)
      if [[ -n "${IMAGE_REF}" ]]; then
        log_info "Scanning pinned image reference: ${IMAGE_REF}" >&2
        BASE_CMD="trivy image --scanners vuln ${TRIVY_ARGS} ${IMAGE_REF}"
      else
        TARGET_TAG="${TARGET_VERSION:-${RELEASE_VERSION}}"
        if [[ "${TARGET_TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          SCAN_IMAGE_REPO="${IMAGE_REPOSITORY}"
          log_info "Stable release version '${TARGET_TAG}' detected — pulling from non-dev production registry: ${IMAGE_REGISTRY}/${SCAN_IMAGE_REPO}:${TARGET_TAG}" >&2
        else
          SCAN_IMAGE_REPO="${IMAGE_REPOSITORY}${IMAGE_DEV_REPOSITORY_SUFFIX}"
          log_info "Candidate/dev version '${TARGET_TAG}' detected — pulling from dev registry: ${IMAGE_REGISTRY}/${SCAN_IMAGE_REPO}:${TARGET_TAG}" >&2
        fi
        FULL_IMAGE="${IMAGE_REGISTRY}/${SCAN_IMAGE_REPO}:${TARGET_TAG}"
        BASE_CMD="trivy image --scanners vuln ${TRIVY_ARGS} ${FULL_IMAGE}"
      fi
      ;;
    config)
      BASE_CMD="trivy config ${IAC_SCAN_PATH}"
      if [[ -n "${TRIVY_HELM_VALUES_FILE:-}" && -f "${TRIVY_HELM_VALUES_FILE}" ]]; then
        BASE_CMD+=" --helm-values ${TRIVY_HELM_VALUES_FILE}"
      fi
      ;;
    license) BASE_CMD="trivy fs --scanners license --license-full --skip-db-update ${TRIVY_ARGS} ." ;;
    sbom) BASE_CMD="trivy sbom --scanners vuln ${SBOM_FILE}" ;;
  esac
  echo "${BASE_CMD}"
}

execute_trivy_scan() {
  log_info "Executing Trivy scan..."
  if [[ -n "${TRIVY_IGNORE_CVES}" ]]; then
    log_info "Adding ignored CVEs to .trivyignore..."
    # shellcheck disable=SC2086 # deliberate split: a space-separated CVE list, one per line
    printf "%s\n" ${TRIVY_IGNORE_CVES} >> .trivyignore
  fi
  local TRIVY_CMD
  TRIVY_CMD=$(build_trivy_command)

  if [[ "${SCAN_TYPE}" == "image" || "${SCAN_TYPE}" == "sbom" ]]; then
    if [[ -n "${TRIVY_HOST:-}" ]]; then
      TRIVY_CMD+=" --server ${TRIVY_HOST}"
      log_info "Using Trivy server mode (${TRIVY_HOST})."
      if [[ -n "${TRIVY_TOKEN:-}" ]]; then
        TRIVY_CMD+=" --token ${TRIVY_TOKEN}"
      fi
    else
      log_warn "TRIVY_HOST is not set: this scan will download the full vulnerability database (~1.2GB) into the job. Point TRIVY_HOST at the shared Trivy server to avoid it."
    fi
  fi

  local TRIVY_LOG="trivy-scan.log"
  if ! ${TRIVY_CMD} --format json --ignorefile .trivyignore --skip-version-check --timeout "${TRIVY_TIMEOUT}" --output "${TRIVY_SCAN_REPORT_NAME}.json" 2>&1 | tee "${TRIVY_LOG}"; then
    local REASON
    REASON="$(grep -E "\bFATAL\b|\bERROR\b" "${TRIVY_LOG}" | tail -n 5 || true)"
    log_error "Trivy scan failed"
    if [[ -n "${REASON}" ]]; then
      echo "${REASON}" >&2
    fi
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "### 🛡️ Trivy ${SCAN_TYPE} scan"
        echo ""
        echo "❌ The scan did not complete."
        if [[ -n "${REASON}" ]]; then
          echo ""
          echo '```'
          echo "${REASON}"
          echo '```'
        fi
        echo ""
      } >> "${GITHUB_STEP_SUMMARY}"
    fi
    exit 1
  fi

  log_info "Generating JUnit XML test report..."
  trivy convert --format template --template "@${JUNIT_TPL_FILE}" --output "${TRIVY_SCAN_REPORT_NAME}.junit" "${TRIVY_SCAN_REPORT_NAME}.json" 2>/dev/null || true

  if [[ ! -f "${TRIVY_SCAN_REPORT_NAME}.json" ]]; then
    log_error "Trivy did not generate output file"
    summarise_abort "Trivy exited cleanly but wrote no \`${TRIVY_SCAN_REPORT_NAME}.json\`, so there is nothing to evaluate. The scan cannot be treated as passing. Re-run, and if it persists check the Trivy server at \`${TRIVY_HOST:-<unset>}\`."
    exit 1
  fi
  log_info "Trivy scan completed successfully"
}
load_ignored_items() {
  local CONFIG_PATH
  CONFIG_PATH=$(get_ignore_config_path)

  if [[ ! -f "${TRIVY_IGNORE_CONFIG_FILE}" ]]; then
    log_warn "Ignore file not found: ${TRIVY_IGNORE_CONFIG_FILE}"
    touch "${IGNORED_ITEMS_FILE}"
    return
  fi
  log_info "Loading ignored items from: ${CONFIG_PATH}"
  while IFS= read -r LINE; do
    local ITEM_NAME ITEM_PKG ITEM_REASON KEY
    ITEM_NAME=$(jq -r 'fromjson | .id' <<< "${LINE}")
    ITEM_PKG=$(jq -r 'fromjson | .package // "*"' <<< "${LINE}")
    ITEM_REASON=$(jq -r 'fromjson | .reason' <<< "${LINE}")
    if [[ -n "${ITEM_NAME}" && "${ITEM_NAME}" != "null" ]]; then
      if [[ "${SCAN_TYPE}" == "license" && -n "${ITEM_PKG}" && "${ITEM_PKG}" != "*" && "${ITEM_PKG}" != "null" ]]; then
        KEY="${ITEM_PKG}:::${ITEM_NAME}"
      else
        KEY="${ITEM_NAME}"
      fi
      echo "${KEY}" >> "${IGNORED_ITEMS_FILE}"
      if [[ -z "${ITEM_REASON}" || "${ITEM_REASON}" == "null" ]]; then
        MISSING_REASONS+=("${KEY}")
      else
        IGNORED_ITEM_REASONS["${KEY}"]="${ITEM_REASON}"
        if ! is_valid_reason "${ITEM_REASON}"; then
          INVALID_REASONS+=("${KEY}:::${ITEM_REASON}")
        fi
      fi
    fi
  done < <(yq -o=json ".${CONFIG_PATH}[] | @json" "${TRIVY_IGNORE_CONFIG_FILE}")
  sort -u "${IGNORED_ITEMS_FILE}" -o "${IGNORED_ITEMS_FILE}"
  log_info "Loaded $(wc -l < "${IGNORED_ITEMS_FILE}") ignored items"
}

extract_cve_items() {
  local INPUT_JSON="${TRIVY_SCAN_REPORT_NAME}.json"
  log_info "Extracting CVE items..."
  jq -r '[.Results[]?.Vulnerabilities[]? | select(.FixedVersion != null and .FixedVersion != "" and .VulnerabilityID != null and .VulnerabilityID != "") | .VulnerabilityID] | unique | .[]' "${INPUT_JSON}" 2>/dev/null > "${ALL_FIXABLE_FILE}"
  jq -r '[.Results[]?.Vulnerabilities[]? | select((.FixedVersion == null or .FixedVersion == "") and .VulnerabilityID != null and .VulnerabilityID != "") | .VulnerabilityID] | unique | .[]' "${INPUT_JSON}" 2>/dev/null > "${ALL_UNFIXABLE_FILE}"
  cat "${ALL_FIXABLE_FILE}" "${ALL_UNFIXABLE_FILE}" | sort -u > "${ALL_FOUND_FILE}"
  log_info "Found $(wc -l < "${ALL_FIXABLE_FILE}") fixable and $(wc -l < "${ALL_UNFIXABLE_FILE}") unfixable CVEs"
}

extract_misconfig_items() {
  local INPUT_JSON="${TRIVY_SCAN_REPORT_NAME}.json"
  log_info "Extracting misconfiguration items..."
  jq -r '[.Results[]?.Misconfigurations[]? | select(.ID != null and .ID != "") | .ID] | unique | .[]' "${INPUT_JSON}" 2>/dev/null > "${ALL_FIXABLE_FILE}"
  touch "${ALL_UNFIXABLE_FILE}"
  cp "${ALL_FIXABLE_FILE}" "${ALL_FOUND_FILE}"
  log_info "Found $(wc -l < "${ALL_FIXABLE_FILE}") misconfigurations"
}

extract_license_items() {
  local INPUT_JSON="${TRIVY_SCAN_REPORT_NAME}.json"
  log_info "Extracting license items..."
  local CATEGORIES=("notice" "permissive" "reciprocal" "restricted" "unrecognized")
  local FILES=("${ALL_NOTICE_FILE}" "${ALL_PERMISSIVE_FILE}" "${ALL_RECIPROCAL_FILE}" "${ALL_RESTRICTED_FILE}" "${ALL_UNRECOGNIZED_FILE}")
  for I in "${!CATEGORIES[@]}"; do
    jq -r "[.Results[]?.Licenses[]? | select(.Category == \"${CATEGORIES[${I}]}\" and .Name != null and .Name != \"\") | \"\(.PkgName // \"unknown\"):::\(.Name)\"] | unique | .[]" "${INPUT_JSON}" 2>/dev/null > "${FILES[${I}]}"
    log_info "Found $(wc -l < "${FILES[${I}]}") ${CATEGORIES[${I}]} licenses"
  done
  cat "${FILES[@]}" | sort -u > "${ALL_FOUND_FILE}"
}
categorize_items() {
  local SOURCE_FILE="${1}"
  local -n _RESULT_REF="${2}"
  local -n _IGNORED_REF="${3}"
  _RESULT_REF=()
  while IFS= read -r ITEM; do
    if [[ -n "${ITEM}" ]]; then
      _RESULT_REF+=("${ITEM}")
    fi
  done < <(comm -23 "${SOURCE_FILE}" "${IGNORED_ITEMS_FILE}")
  _IGNORED_REF=()
  while IFS= read -r ITEM; do
    if [[ -n "${ITEM}" ]]; then
      _IGNORED_REF+=("${ITEM}")
    fi
  done < <(comm -12 "${SOURCE_FILE}" "${IGNORED_ITEMS_FILE}")
}

categorize_cve_items() {
  log_info "Categorizing CVE items..."
  categorize_items "${ALL_FIXABLE_FILE}" "FINAL_FIXABLE" "FINAL_FIXABLE_IGNORED"
  categorize_items "${ALL_UNFIXABLE_FILE}" "FINAL_UNFIXABLE" "FINAL_UNFIXABLE_IGNORED"
  FINAL_FIXED_IGNORED=()
  while IFS= read -r ITEM; do
    if [[ -n "${ITEM}" ]]; then
      FINAL_FIXED_IGNORED+=("${ITEM}")
    fi
  done < <(comm -23 "${IGNORED_ITEMS_FILE}" "${ALL_FOUND_FILE}")
  log_info "Categorized: ${#FINAL_FIXABLE[@]} fixable, ${#FINAL_FIXABLE_IGNORED[@]} ignored, ${#FINAL_UNFIXABLE[@]} unfixable, ${#FINAL_FIXED_IGNORED[@]} stale"
}

categorize_license_items() {
  log_info "Categorizing license items..."
  local CATEGORIES=("notice" "permissive" "reciprocal" "restricted" "unrecognized")
  local TEMP_FILES=("${ALL_NOTICE_FILE}" "${ALL_PERMISSIVE_FILE}" "${ALL_RECIPROCAL_FILE}" "${ALL_RESTRICTED_FILE}" "${ALL_UNRECOGNIZED_FILE}")
  local RESULT_ARRAYS=("FINAL_NOTICE" "FINAL_PERMISSIVE" "FINAL_RECIPROCAL" "FINAL_RESTRICTED" "FINAL_UNRECOGNIZED")
  local IGNORED_ARRAYS=("FINAL_NOTICE_IGNORED" "FINAL_PERMISSIVE_IGNORED" "FINAL_RECIPROCAL_IGNORED" "FINAL_RESTRICTED_IGNORED" "FINAL_UNRECOGNIZED_IGNORED")
  for I in "${!CATEGORIES[@]}"; do
    local -n _RESULT_REF="${RESULT_ARRAYS[${I}]}"
    local -n _IGNORED_REF="${IGNORED_ARRAYS[${I}]}"
    _RESULT_REF=()
    _IGNORED_REF=()
    while IFS= read -r ITEM; do
      if [[ -z "${ITEM}" ]]; then continue; fi
      local PKG="${ITEM%%:::*}"
      local LIC="${ITEM#*:::}"
      if grep -Fxq "${ITEM}" "${IGNORED_ITEMS_FILE}" || grep -Fxq "${LIC}" "${IGNORED_ITEMS_FILE}"; then
        _IGNORED_REF+=("${ITEM}")
      else
        _RESULT_REF+=("${ITEM}")
      fi
    done < "${TEMP_FILES[${I}]}"
  done
  FINAL_FIXED_IGNORED=()
  while IFS= read -r ITEM; do
    if [[ -z "${ITEM}" ]]; then continue; fi
    if [[ "${ITEM}" == *":::"* ]]; then
      if ! grep -Fxq "${ITEM}" "${ALL_FOUND_FILE}"; then
        FINAL_FIXED_IGNORED+=("${ITEM}")
      fi
    else
      if ! awk -F':::' '{print $2}' "${ALL_FOUND_FILE}" | grep -Fxq "${ITEM}"; then
        FINAL_FIXED_IGNORED+=("${ITEM}")
      fi
    fi
  done < "${IGNORED_ITEMS_FILE}"
  log_info "Categorized licenses across all categories"
}
generate_report_header() {
  local TITLE="${1}"
  local OUTPUT_FILE="${2}"
  local CONFIG_INFO=""
  if [[ "${SCAN_TYPE}" == "config" ]]; then
    CONFIG_INFO="**Config Type:** ${CONFIG_TYPE}"
  fi
  cat > "${OUTPUT_FILE}" << EOF
# ${TITLE}

**Scan Type:** ${SCAN_TYPE}
${CONFIG_INFO}
**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")

EOF
}

generate_table() {
  local HEADERS=("${@}")
  local HEADER_ROW="|"
  local SEPARATOR_ROW="|"
  for HEADER in "${HEADERS[@]}"; do
    HEADER_ROW+=" ${HEADER} |"
    SEPARATOR_ROW+=" --- |"
  done
  echo "${HEADER_ROW}"
  echo "${SEPARATOR_ROW}"
}
generate_vulnerability_section() {
  local INPUT_JSON="${1}"
  echo "## Container Image Vulnerability Scan"
  echo ""
  echo "### Summary"
  generate_table "Category" "Severity" "Count"
  local TOTAL_FIXABLE=0
  local TOTAL_UNFIXABLE=0
  local SEVERITIES=("CRITICAL" "HIGH" "MEDIUM" "LOW" "UNKNOWN")
  for SEV in "${SEVERITIES[@]}"; do
    local FIXABLE_COUNT UNFIXABLE_COUNT
    FIXABLE_COUNT=$(jq "[.Results[]?.Vulnerabilities[]? | select(.Severity == \"${SEV}\" and .FixedVersion != null and .FixedVersion != \"\")] | length" "${INPUT_JSON}")
    UNFIXABLE_COUNT=$(jq "[.Results[]?.Vulnerabilities[]? | select(.Severity == \"${SEV}\" and (.FixedVersion == null or .FixedVersion == \"\"))] | length" "${INPUT_JSON}")
    echo "| Fixable | ${SEV} | ${FIXABLE_COUNT} |"
    echo "| Unfixable | ${SEV} | ${UNFIXABLE_COUNT} |"
    TOTAL_FIXABLE=$((TOTAL_FIXABLE + FIXABLE_COUNT))
    TOTAL_UNFIXABLE=$((TOTAL_UNFIXABLE + UNFIXABLE_COUNT))
  done
  echo "| **Fixable Total** | — | ${TOTAL_FIXABLE} |"
  echo "| **Unfixable Total** | — | ${TOTAL_UNFIXABLE} |"
  echo "| **Grand Total** | — | $((TOTAL_FIXABLE + TOTAL_UNFIXABLE)) |"
  echo ""
  if [[ ${TOTAL_FIXABLE} -gt 0 ]]; then
    echo "### Fixable Vulnerabilities"
    generate_table "Package" "Vulnerability ID" "Installed Version" "Fixed Version" "Title" "Severity" "Ignored Reason"
    jq -r '.Results[]?.Vulnerabilities[]? | select(.FixedVersion != null and .FixedVersion != "") | [.PkgName, .VulnerabilityID, .InstalledVersion, .FixedVersion, (.Title // "N/A"), .Severity] | @tsv' "${INPUT_JSON}" 2>/dev/null | while IFS=$'\t' read -r PKG VID INST_VER FIX_VER TITLE SEV; do
      local REASON="${IGNORED_ITEM_REASONS[${VID}]:--}"
      echo "| ${PKG} | ${VID} | ${INST_VER} | ${FIX_VER} | ${TITLE} | ${SEV} | ${REASON} |"
    done
    echo ""
  fi
  if [[ ${TOTAL_UNFIXABLE} -gt 0 ]]; then
    echo "### Unfixable Vulnerabilities"
    generate_table "Package" "Vulnerability ID" "Installed Version" "Title" "Severity"
    jq -r '.Results[]?.Vulnerabilities[]? | select(.FixedVersion == null or .FixedVersion == "") | [.PkgName, .VulnerabilityID, .InstalledVersion, (.Title // "N/A"), .Severity] | @tsv' "${INPUT_JSON}" 2>/dev/null | while IFS=$'\t' read -r PKG VID INST_VER TITLE SEV; do
      echo "| ${PKG} | ${VID} | ${INST_VER} | ${TITLE} | ${SEV} |"
    done
    echo ""
  fi
}

generate_misconfig_section() {
  local INPUT_JSON="${1}"
  echo "## Configuration Scan (${CONFIG_TYPE})"
  echo ""
  echo "### Summary"
  generate_table "Severity" "Count"
  local TOTAL=0
  local SEVERITIES=("CRITICAL" "HIGH" "MEDIUM" "LOW" "UNKNOWN")
  for SEV in "${SEVERITIES[@]}"; do
    local COUNT
    COUNT=$(jq "[.Results[]?.Misconfigurations[]? | select(.Severity == \"${SEV}\")] | length" "${INPUT_JSON}")
    echo "| ${SEV} | ${COUNT} |"
    TOTAL=$((TOTAL + COUNT))
  done
  echo "| **Total** | **${TOTAL}** |"
  echo ""
  if [[ ${TOTAL} -gt 0 ]]; then
    echo "### Misconfigurations"
    generate_table "ID" "Title" "Severity" "Message" "Ignored Reason"
    jq -r '.Results[]?.Misconfigurations[]? | [.ID, .Title, .Severity, (.Message // "N/A" | gsub("\n"; " "))] | @tsv' "${INPUT_JSON}" 2>/dev/null | while IFS=$'\t' read -r ID TITLE SEVERITY MSG; do
      local REASON="${IGNORED_ITEM_REASONS[${ID}]:--}"
      echo "| ${ID} | ${TITLE} | ${SEVERITY} | ${MSG} | ${REASON} |"
    done
    echo ""
  fi
}

generate_cve_report() {
  local INPUT_JSON="${TRIVY_SCAN_REPORT_NAME}.json"
  local OUTPUT_MD="${TRIVY_SCAN_REPORT_NAME}.md"
  log_info "Generating CVE/misconfiguration report: ${OUTPUT_MD}"
  generate_report_header "Security Scan Report" "${OUTPUT_MD}"
  if [[ "${SCAN_TYPE}" == "config" ]]; then
    generate_misconfig_section "${INPUT_JSON}" >> "${OUTPUT_MD}"
  else
    generate_vulnerability_section "${INPUT_JSON}" >> "${OUTPUT_MD}"
  fi
  log_info "Report generated successfully"
}
generate_license_report() {
  local INPUT_JSON="${TRIVY_SCAN_REPORT_NAME}.json"
  local OUTPUT_MD="${TRIVY_SCAN_REPORT_NAME}.md"
  log_info "Generating license report: ${OUTPUT_MD}"
  generate_report_header "License Scan Report" "${OUTPUT_MD}"
  {
    generate_license_summary "${INPUT_JSON}"
    generate_license_details "${INPUT_JSON}"
    generate_license_ignored_section
  } >> "${OUTPUT_MD}"
  log_info "License report generated successfully"
}

generate_license_summary() {
  local INPUT_JSON="${1}"
  local COUNTS=()
  local CATEGORIES=("notice" "permissive" "reciprocal" "restricted" "unrecognized")
  local RISK_LEVELS=("Low" "Low" "Medium" "High" "Medium")
  for CATEGORY in "${CATEGORIES[@]}"; do
    COUNTS+=($(jq "[.Results[]?.Licenses[]? | select(.Category == \"${CATEGORY}\")] | length" "${INPUT_JSON}"))
  done
  local TOTAL=$(( COUNTS[0] + COUNTS[1] + COUNTS[2] + COUNTS[3] + COUNTS[4] ))
  echo "## Summary"
  generate_table "Category" "Count" "Risk Level"
  for I in "${!CATEGORIES[@]}"; do
    echo "| ${CATEGORIES[${I}]^} | ${COUNTS[${I}]} | ${RISK_LEVELS[${I}]} |"
  done
  echo "| **Total** | **${TOTAL}** | — |"
  echo ""
}

generate_license_details() {
  local INPUT_JSON="${1}"
  local CATEGORIES=("notice" "permissive" "reciprocal" "restricted" "unrecognized")
  local TITLES=("Notice Licenses" "Permissive Licenses" "Reciprocal Licenses" "Restricted Licenses" "Unrecognized Licenses")
  local DESCRIPTIONS=("These licenses require attribution but allow free use." "These licenses allow free use with minimal restrictions." "These licenses require derived works to be licensed under the same terms (copyleft)." "These licenses have significant restrictions on use and distribution." "These licenses could not be categorized. Manual review recommended.")
  for I in "${!CATEGORIES[@]}"; do
    local COUNT
    COUNT=$(jq "[.Results[]?.Licenses[]? | select(.Category == \"${CATEGORIES[${I}]}\")] | length" "${INPUT_JSON}")
    if [[ ${COUNT} -gt 0 ]]; then
      echo "## ${TITLES[${I}]}"
      echo "${DESCRIPTIONS[${I}]}"
      echo ""
      generate_table "Package Name" "License" "Severity" "File Path"
      jq -r ".Results[]?.Licenses[]? | select(.Category == \"${CATEGORIES[${I}]}\") | [.PkgName, .Name, (.Severity // \"UNKNOWN\"), (.FilePath // \"N/A\")] | @tsv" "${INPUT_JSON}" 2>/dev/null | while IFS=$'\t' read -r PKG LICENSE SEVERITY FILEPATH; do
        echo "| ${PKG} | ${LICENSE} | ${SEVERITY} | ${FILEPATH} |"
      done
      echo ""
    fi
  done
}

generate_license_ignored_section() {
  local TOTAL_IGNORED=$((${#FINAL_NOTICE_IGNORED[@]} + ${#FINAL_PERMISSIVE_IGNORED[@]} + ${#FINAL_RECIPROCAL_IGNORED[@]} + ${#FINAL_RESTRICTED_IGNORED[@]} + ${#FINAL_UNRECOGNIZED_IGNORED[@]}))
  if [[ ${TOTAL_IGNORED} -eq 0 ]]; then
    return
  fi
  echo "## Ignored Licenses"
  echo "The following licenses are currently ignored based on configuration:"
  echo ""
  generate_table "Package" "License" "Category" "Ignored Reason"
  local CATEGORIES=("FINAL_NOTICE_IGNORED" "FINAL_PERMISSIVE_IGNORED" "FINAL_RECIPROCAL_IGNORED" "FINAL_RESTRICTED_IGNORED" "FINAL_UNRECOGNIZED_IGNORED")
  local CATEGORY_NAMES=("Notice" "Permissive" "Reciprocal" "Restricted" "Unrecognized")
  for I in "${!CATEGORIES[@]}"; do
    local -n _LIC_REF="${CATEGORIES[${I}]}"
    for ITEM in "${_LIC_REF[@]}"; do
      local PKG LIC REASON
      if [[ "${ITEM}" == *":::"* ]]; then
        PKG="${ITEM%%:::*}"
        LIC="${ITEM#*:::}"
      else
        PKG="*"
        LIC="${ITEM}"
      fi
      REASON="${IGNORED_ITEM_REASONS[${ITEM}]:-${IGNORED_ITEM_REASONS[${LIC}]:-N/A}}"
      echo "| ${PKG} | ${LIC} | ${CATEGORY_NAMES[${I}]} | ${REASON} |"
    done
  done
  echo ""
}
generate_cve_summary_file() {
  local SUMMARY_FILE
  SUMMARY_FILE=$(get_summary_file_name)
  local INPUT_JSON="${TRIVY_SCAN_REPORT_NAME}.json"
  local REPORT_LABEL
  case "${SCAN_TYPE}" in
    image) REPORT_LABEL="Image CVE" ;;
    config) REPORT_LABEL="${CONFIG_TYPE^} configuration" ;;
    sbom) REPORT_LABEL="SBOM CVE" ;;
    *) REPORT_LABEL="CVE" ;;
  esac
  log_info "Generating summary file: ${SUMMARY_FILE}"
  {
    echo "### 🛡️ ${REPORT_LABEL} Security Scan Report"
    echo ""
    if [[ "${SCAN_TYPE}" == "image" ]]; then
      local FIXABLE_TOTAL UNFIXABLE_TOTAL
      FIXABLE_TOTAL=$(jq '[.Results[]?.Vulnerabilities[]? | select(.FixedVersion != null and .FixedVersion != "")] | length' "${INPUT_JSON}")
      UNFIXABLE_TOTAL=$(jq '[.Results[]?.Vulnerabilities[]? | select(.FixedVersion == null or .FixedVersion == "")] | length' "${INPUT_JSON}")
      echo "| Category | Count |"
      echo "|----------|-------|"
      echo "| Fixable | ${FIXABLE_TOTAL} |"
      echo "| Unfixable | ${UNFIXABLE_TOTAL} |"
      echo "| **Total** | **$((FIXABLE_TOTAL + UNFIXABLE_TOTAL))** |"
      echo ""
    fi
    echo "### 📊 ${REPORT_LABEL} Severity Breakdown"
    echo ""
    local SEVERITIES=("CRITICAL" "HIGH" "MEDIUM" "LOW" "UNKNOWN")
    if [[ "${SCAN_TYPE}" == "config" ]]; then
      # Misconfigurations carry no fixed version, so the fixable split does not apply.
      generate_table "Severity" "Count"
      for SEV in "${SEVERITIES[@]}"; do
        echo "| ${SEV} | $(jq "[.Results[]?.Misconfigurations[]? | select(.Severity == \"${SEV}\")] | length" "${INPUT_JSON}") |"
      done
    else
      generate_table "Severity" "Fixable" "Unfixable" "Total"
      for SEV in "${SEVERITIES[@]}"; do
        local FIXABLE UNFIXABLE
        FIXABLE=$(jq "[.Results[]?.Vulnerabilities[]? | select(.Severity == \"${SEV}\" and .FixedVersion != null and .FixedVersion != \"\")] | length" "${INPUT_JSON}")
        UNFIXABLE=$(jq "[.Results[]?.Vulnerabilities[]? | select(.Severity == \"${SEV}\" and (.FixedVersion == null or .FixedVersion == \"\"))] | length" "${INPUT_JSON}")
        echo "| ${SEV} | ${FIXABLE} | ${UNFIXABLE} | $((FIXABLE + UNFIXABLE)) |"
      done
    fi
    echo ""
  } > "${SUMMARY_FILE}"
  log_info "Summary file generated: ${SUMMARY_FILE}"
}

generate_license_summary_file() {
  local INPUT_JSON="${TRIVY_SCAN_REPORT_NAME}.json"
  local SUMMARY_FILE="${LICENSE_INFO_FILE_NAME}"
  log_info "Generating license summary file: ${SUMMARY_FILE}"
  local COUNTS=()
  local CATEGORIES=("notice" "permissive" "reciprocal" "restricted" "unrecognized")
  local RISK_LEVELS=("Low" "Low" "Medium" "High" "Medium")
  for CATEGORY in "${CATEGORIES[@]}"; do
    COUNTS+=($(jq "[.Results[]?.Licenses[]? | select(.Category == \"${CATEGORY}\")] | length" "${INPUT_JSON}"))
  done
  local TOTAL=$(( COUNTS[0] + COUNTS[1] + COUNTS[2] + COUNTS[3] + COUNTS[4] ))
  {
    echo "### 📜 License Compliance Summary"
    echo ""
    generate_table "Category" "Count" "Risk Level"
    for I in "${!CATEGORIES[@]}"; do
      echo "| ${CATEGORIES[${I}]^} | ${COUNTS[${I}]} | ${RISK_LEVELS[${I}]} |"
    done
    echo "| **Total** | **${TOTAL}** | — |"
    echo ""
    # Same condition the exit code uses: ignored classifications require no action.
    if [[ ${#FINAL_RESTRICTED[@]} -gt 0 ]] && ! is_classification_ignored "restricted"; then
      echo "### ⚠️ Action Required: Restricted Licenses"
      echo "The following restricted licenses require immediate attention:"
      echo ""
      for ITEM in "${FINAL_RESTRICTED[@]}"; do
        if [[ "${ITEM}" == *":::"* ]]; then
          echo "- Package: **${ITEM%%:::*}** — License: \`${ITEM#*:::}\`"
        else
          echo "- ${ITEM}"
        fi
      done
      echo ""
    fi
  } > "${SUMMARY_FILE}"
  log_info "License summary file generated: ${SUMMARY_FILE}"
}

print_cve_summary() {
  print_separator
  echo "CVE/Misconfiguration Scan Summary"
  print_separator
  print_array_summary "Fixable Items" "FINAL_FIXABLE"
  print_array_summary "Ignored Fixable Items" "FINAL_FIXABLE_IGNORED" "IGNORED_ITEM_REASONS"
  print_array_summary "Unfixable Items" "FINAL_UNFIXABLE"
  print_array_summary "Fixed Items Still in Ignore List" "FINAL_FIXED_IGNORED" "IGNORED_ITEM_REASONS"
  print_separator
}

print_license_summary() {
  print_separator
  echo "License Scan Summary"
  print_separator
  local CATEGORIES=("Notice" "Permissive" "Reciprocal" "Restricted" "Unrecognized")
  local ARRAYS=("FINAL_NOTICE" "FINAL_PERMISSIVE" "FINAL_RECIPROCAL" "FINAL_RESTRICTED" "FINAL_UNRECOGNIZED")
  for I in "${!CATEGORIES[@]}"; do
    print_array_summary "${CATEGORIES[${I}]} Licenses" "${ARRAYS[${I}]}"
  done
  local TOTAL_IGNORED=$((${#FINAL_NOTICE_IGNORED[@]} + ${#FINAL_PERMISSIVE_IGNORED[@]} + ${#FINAL_RECIPROCAL_IGNORED[@]} + ${#FINAL_RESTRICTED_IGNORED[@]} + ${#FINAL_UNRECOGNIZED_IGNORED[@]}))
  echo "Total Ignored Licenses: ${TOTAL_IGNORED}"
  echo ""
  print_array_summary "Fixed Licenses Still in Ignore List" "FINAL_FIXED_IGNORED" "IGNORED_ITEM_REASONS"
  print_separator
}

print_array_summary() {
  local TITLE="${1}"
  local ARRAY_NAME="${2}"
  # ${3:-}, not ${3}: set -u makes a bare third arg fatal at call sites that omit it.
  local REASON_ARRAY="${3:-}"
  local -n _PRINT_REF="${ARRAY_NAME}"
  local COUNT=${#_PRINT_REF[@]}
  echo "${TITLE}: ${COUNT}"
  if [[ ${COUNT} -gt 0 ]]; then
    for ITEM in "${_PRINT_REF[@]}"; do
      local REASON=""
      if [[ -n "${REASON_ARRAY}" ]]; then
        local -n _PRINT_REASON_REF="${REASON_ARRAY}"
        REASON="${_PRINT_REASON_REF[${ITEM}]:-}"
        if [[ -z "${REASON}" && "${ITEM}" == *":::"* ]]; then
          REASON="${_PRINT_REASON_REF[${ITEM#*:::}]:-}"
        fi
      fi
      if [[ -n "${REASON}" ]]; then
        echo "  - ${ITEM} (Reason: ${REASON})"
      else
        echo "  - ${ITEM}"
      fi
    done
  fi
  echo ""
}
check_missing_reasons() {
  if [[ ${#MISSING_REASONS[@]} -eq 0 ]]; then
    return
  fi
  EXIT_CODE=1
  print_separator
  echo "MISSING REASONS ERROR"
  print_separator
  echo "The following ignored items are missing a 'reason' field in ${TRIVY_IGNORE_CONFIG_FILE}:"
  echo ""
  for ITEM in "${MISSING_REASONS[@]}"; do
    echo "  - ${ITEM}"
  done
  echo ""
  echo "Please add a 'reason' field for each ignored item."
  echo "Example:"
  echo "  - name: ${MISSING_REASONS[0]}"
  echo "    reason: 'Explanation for why this is ignored'"
  print_separator
  echo ""
  REASONS+=("Error: Found ${#MISSING_REASONS[@]} ignored item(s) without a reason field.")
}

check_invalid_reasons() {
  if [[ ${#INVALID_REASONS[@]} -eq 0 ]]; then
    return
  fi
  EXIT_CODE=1
  print_separator
  echo "INVALID REASONS ERROR"
  print_separator
  echo "The following ignored items have invalid/placeholder 'reason' fields in ${TRIVY_IGNORE_CONFIG_FILE}:"
  echo ""
  for ENTRY in "${INVALID_REASONS[@]}"; do
    local ITEM="${ENTRY%%:::*}"
    local REASON="${ENTRY#*:::}"
    echo "  - ${ITEM} (reason: '${REASON}')"
  done
  echo ""
  echo "Reasons must be descriptive (at least 10 characters) and not a placeholder (e.g. TODO, TBD, N/A, fix, wip)."
  echo "Example:"
  echo "  - name: ${INVALID_REASONS[0]%%:::*}"
  echo "    reason: 'Accepted risk: this vulnerability does not affect our usage pattern'"
  print_separator
  echo ""
  REASONS+=("Error: Found ${#INVALID_REASONS[@]} ignored item(s) with invalid/placeholder reason fields.")
}

determine_cve_exit_code() {
  local HAS_ERRORS=0
  local HAS_WARNINGS=0
  check_missing_reasons
  check_invalid_reasons
  if [[ ${EXIT_CODE} -eq 1 ]]; then
    HAS_ERRORS=1
  fi
  if [[ ${#FINAL_FIXABLE[@]} -gt 0 ]]; then
    HAS_ERRORS=1
    REASONS+=("Error: Found ${#FINAL_FIXABLE[@]} active fixable vulnerabilities/misconfigurations that must be addressed.")
  fi
  if [[ ${#FINAL_FIXED_IGNORED[@]} -gt 0 ]]; then
    HAS_ERRORS=1
    REASONS+=("Error: Found ${#FINAL_FIXED_IGNORED[@]} fixed items still in ignore list. Remove them from ${TRIVY_IGNORE_CONFIG_FILE}.")
  fi
  if [[ ${#FINAL_UNFIXABLE[@]} -gt 0 ]]; then
    HAS_WARNINGS=1
    REASONS+=("Warning: Found ${#FINAL_UNFIXABLE[@]} unfixable vulnerabilities. Review and consider mitigation strategies.")
  fi
  if [[ ${#FINAL_FIXABLE_IGNORED[@]} -gt 0 ]]; then
    HAS_WARNINGS=1
    REASONS+=("Warning: Found ${#FINAL_FIXABLE_IGNORED[@]} ignored fixable vulnerabilities. Review if these can be addressed.")
  fi
  if [[ ${HAS_ERRORS} -eq 1 ]]; then
    EXIT_CODE=1
  elif [[ ${HAS_WARNINGS} -eq 1 ]]; then
    EXIT_CODE=2
  else
    EXIT_CODE=0
  fi
}

is_classification_ignored() {
  local CAT="${1,,}"
  local IGNORED_CONFIG="${TRIVY_IGNORED_LICENSE_CLASSIFICATIONS,,}"
  IFS=',' read -r -a CONFIG_ITEMS <<< "${IGNORED_CONFIG}"
  for ITEM in "${CONFIG_ITEMS[@]}"; do
    ITEM="$(echo "${ITEM}" | xargs)"
    case "${ITEM}" in
      "${CAT}") return 0 ;;
      "low")
        if [[ "${CAT}" == "notice" || "${CAT}" == "permissive" || "${CAT}" == "unencumbered" ]]; then
          return 0
        fi
        ;;
      "medium")
        if [[ "${CAT}" == "reciprocal" || "${CAT}" == "unrecognized" ]]; then
          return 0
        fi
        ;;
      "high")
        if [[ "${CAT}" == "restricted" ]]; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

determine_license_exit_code() {
  local HAS_ERRORS=0
  local HAS_WARNINGS=0
  check_missing_reasons
  check_invalid_reasons
  if [[ ${EXIT_CODE} -eq 1 ]]; then
    HAS_ERRORS=1
  fi
  if [[ ${#FINAL_RESTRICTED[@]} -gt 0 ]] && ! is_classification_ignored "restricted"; then
    HAS_ERRORS=1
    REASONS+=("Error: Found ${#FINAL_RESTRICTED[@]} restricted licenses requiring immediate attention.")
  fi
  if [[ ${#FINAL_FIXED_IGNORED[@]} -gt 0 ]]; then
    HAS_ERRORS=1
    REASONS+=("Error: Found ${#FINAL_FIXED_IGNORED[@]} licenses in ignore file that are no longer present. Remove them from ${TRIVY_IGNORE_CONFIG_FILE}.")
  fi
  if [[ ${#FINAL_RECIPROCAL[@]} -gt 0 ]] && ! is_classification_ignored "reciprocal"; then
    HAS_WARNINGS=1
    REASONS+=("Warning: Found ${#FINAL_RECIPROCAL[@]} reciprocal (copyleft) licenses. Review compliance implications.")
  fi
  if [[ ${#FINAL_UNRECOGNIZED[@]} -gt 0 ]] && ! is_classification_ignored "unrecognized"; then
    HAS_WARNINGS=1
    REASONS+=("Warning: Found ${#FINAL_UNRECOGNIZED[@]} unrecognized licenses. Manual review required.")
  fi
  if [[ ${#FINAL_RESTRICTED_IGNORED[@]} -gt 0 ]] && ! is_classification_ignored "restricted"; then
    HAS_WARNINGS=1
    REASONS+=("Warning: Found ${#FINAL_RESTRICTED_IGNORED[@]} ignored restricted licenses. Review if acceptable.")
  fi
  if [[ ${HAS_ERRORS} -eq 1 ]]; then
    EXIT_CODE=1
  elif [[ ${HAS_WARNINGS} -eq 1 ]]; then
    EXIT_CODE=2
  else
    EXIT_CODE=0
  fi
}

process_cve_scan() {
  if [[ "${SCAN_TYPE}" == "config" ]]; then
    extract_misconfig_items
  else
    extract_cve_items
  fi
  categorize_cve_items
  generate_cve_report
  print_cve_summary
  determine_cve_exit_code
  generate_cve_summary_file
}

process_license_scan() {
  extract_license_items
  categorize_license_items
  generate_license_report
  print_license_summary
  determine_license_exit_code
  generate_license_summary_file
}

print_final_summary() {
  echo ""
  print_separator
  case ${EXIT_CODE} in
    0) echo "All checks passed" ;;
    1) echo "Scan failed with errors" ;;
    2) echo "Scan completed with warnings" ;;
  esac
  print_separator
  if [[ ${#REASONS[@]} -gt 0 ]]; then
    echo ""
    echo "Details:"
    printf '  %s\n' "${REASONS[@]}"
  fi
  echo ""
  log_info "Generated reports:"
  echo "  - ${TRIVY_SCAN_REPORT_NAME}.json (raw JSON)"
  echo "  - ${TRIVY_SCAN_REPORT_NAME}.md (markdown report)"
  echo "  - $(get_summary_file_name) (summary)"
  echo ""
  log_info "Scan completed"
}

auto_generate_detected_findings() {
  local SCAN_JSON="./${TRIVY_SCAN_REPORT_NAME}.json"
  local IGNORE_FILE="./${TRIVY_IGNORE_CONFIG_FILE}"
  local OUTPUT="/tmp/generated-${TRIVY_IGNORE_CONFIG_FILE}"
  local EXISTING_IGNORED=""
  local NEW_FIXABLE=""
  local NEW_MISCONFIGS=""
  local NEW_ITEMS=""
  local INDENT=""
  if [[ ! -f "${IGNORE_FILE}" ]]; then
    echo "${TRIVY_IGNORE_CONFIG_FILE} not found — initializing new baseline..." >&2
  else
    EXISTING_IGNORED=$(yq -r '.. | .id? | select(. != null)' "${IGNORE_FILE}" 2>/dev/null | sort -u)
  fi
  {
    if [[ "${SCAN_TYPE}" == "image" ]]; then
      NEW_FIXABLE=$(jq -r '.Results[]?.Vulnerabilities[]? | select(.FixedVersion != null and .FixedVersion != "") | .VulnerabilityID' "${SCAN_JSON}" 2>/dev/null | sort -u)
      NEW_ITEMS=$(comm -23 <(echo "${NEW_FIXABLE}") <(echo "${EXISTING_IGNORED}"))
      if [[ -n "${NEW_ITEMS}" ]]; then
        echo "image:"
        while read -r VID; do
          if [[ -z "${VID}" ]]; then
            continue
          fi
          cat <<EOF
  - id: "${VID}"
    reason: "Explanation for why this is ignored"
EOF
        done <<< "${NEW_ITEMS}"
      fi
    fi
    if [[ "${SCAN_TYPE}" == "config" ]]; then
      NEW_MISCONFIGS=$(jq -r '.Results[]?.Misconfigurations[]?.ID' "${SCAN_JSON}" 2>/dev/null | sort -u)
      NEW_ITEMS=$(comm -23 <(echo "${NEW_MISCONFIGS}") <(echo "${EXISTING_IGNORED}"))
      if [[ -n "${NEW_ITEMS}" ]]; then
        echo "iac:"
        if [[ "${CONFIG_TYPE}" == "chart" ]]; then
          echo "  chart:"
          INDENT="    "
        else
          echo "  terraform:"
          INDENT="    "
        fi
        while read -r MID; do
          if [[ -z "${MID}" ]]; then
            continue
          fi
          cat <<EOF
${INDENT}- id: "${MID}"
${INDENT}  reason: "Explanation for why this is ignored"
EOF
        done <<< "${NEW_ITEMS}"
      fi
    fi
    if [[ "${SCAN_TYPE}" == "license" ]]; then
      local NON_PERMISSIVE_LICENSES
      NON_PERMISSIVE_LICENSES=$(jq -r '[.Results[]?.Licenses[]? | select((.Category == "restricted" or .Category == "reciprocal" or .Category == "unrecognized") and .Name != null and .Name != "") | "\(.PkgName // "unknown"):::\(.Name)"] | unique | .[]' "${SCAN_JSON}" 2>/dev/null | sort -u)
      local NEW_LIC_ITEMS=()
      while IFS= read -r LIC_ITEM; do
        if [[ -z "${LIC_ITEM}" ]]; then continue; fi
        local PKG="${LIC_ITEM%%:::*}"
        local LIC="${LIC_ITEM#*:::}"
        if ! grep -Fxq "${LIC_ITEM}" "${IGNORED_ITEMS_FILE}" && ! grep -Fxq "${LIC}" "${IGNORED_ITEMS_FILE}"; then
          NEW_LIC_ITEMS+=("${LIC_ITEM}")
        fi
      done <<< "${NON_PERMISSIVE_LICENSES}"
      if [[ ${#NEW_LIC_ITEMS[@]} -gt 0 ]]; then
        echo "license:"
        for ITEM in "${NEW_LIC_ITEMS[@]}"; do
          local PKG="${ITEM%%:::*}"
          local LIC="${ITEM#*:::}"
          echo "  - id: \"${LIC}\""
          echo "    package: \"${PKG}\""
          echo "    reason: \"Explanation for why this is ignored\""
        done
      fi
    fi
  } > "${OUTPUT}"
  cat "${OUTPUT}"
}
setup_temp_files() {
  IGNORED_ITEMS_FILE=$(mktemp)
  ALL_FIXABLE_FILE=$(mktemp)
  ALL_UNFIXABLE_FILE=$(mktemp)
  ALL_FOUND_FILE=$(mktemp)
  ALL_NOTICE_FILE=$(mktemp)
  ALL_PERMISSIVE_FILE=$(mktemp)
  ALL_RECIPROCAL_FILE=$(mktemp)
  ALL_RESTRICTED_FILE=$(mktemp)
  ALL_UNRECOGNIZED_FILE=$(mktemp)
  JUNIT_TPL_FILE=$(mktemp)
  if [[ -n "${TRIVY_JUNIT_TEMPLATE_FILE:-}" && -f "${TRIVY_JUNIT_TEMPLATE_FILE}" ]]; then
    cp "${TRIVY_JUNIT_TEMPLATE_FILE}" "${JUNIT_TPL_FILE}"
  else
    printf '%s' "${TRIVY_JUNIT_TEMPLATE:-}" > "${JUNIT_TPL_FILE}"
  fi
  trap cleanup EXIT
}

generate_action_table() {
  case "${SCAN_TYPE}" in
    license)
      generate_table "License category" "Needs review" "Ignored"
      # A classification the exit code never acts on is not left to act on.
      is_classification_ignored "restricted" || echo "| Restricted | ${#FINAL_RESTRICTED[@]} | ${#FINAL_RESTRICTED_IGNORED[@]} |"
      is_classification_ignored "reciprocal" || echo "| Reciprocal | ${#FINAL_RECIPROCAL[@]} | ${#FINAL_RECIPROCAL_IGNORED[@]} |"
      is_classification_ignored "unrecognized" || echo "| Unrecognized | ${#FINAL_UNRECOGNIZED[@]} | ${#FINAL_UNRECOGNIZED_IGNORED[@]} |"
      is_classification_ignored "notice" || echo "| Notice | ${#FINAL_NOTICE[@]} | ${#FINAL_NOTICE_IGNORED[@]} |"
      is_classification_ignored "permissive" || echo "| Permissive | ${#FINAL_PERMISSIVE[@]} | ${#FINAL_PERMISSIVE_IGNORED[@]} |"
      echo "| **Ignored but no longer present** | ${#FINAL_FIXED_IGNORED[@]} | — |"
      ;;
    *)
      generate_table "Category" "Count"
      echo "| Active, fixable | ${#FINAL_FIXABLE[@]} |"
      echo "| Ignored (justified) | ${#FINAL_FIXABLE_IGNORED[@]} |"
      # Misconfigurations carry no fixed version, so nothing is ever unfixable.
      [[ "${SCAN_TYPE}" == "config" ]] || echo "| Unfixable | ${#FINAL_UNFIXABLE[@]} |"
      echo "| **Ignored but no longer present** | ${#FINAL_FIXED_IGNORED[@]} |"
      ;;
  esac
}

publish_step_summary() {
  if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
    return
  fi
  local SUMMARY_FILE VERDICT
  SUMMARY_FILE=$(get_summary_file_name)
  case ${EXIT_CODE} in
    0) VERDICT="✅ Passed — no action required" ;;
    1) VERDICT="❌ Failed — findings must be fixed or justified" ;;
    2) VERDICT="⚠️ Passed with warnings" ;;
    *) VERDICT="Exit code ${EXIT_CODE}" ;;
  esac
  {
    if [[ -f "${SUMMARY_FILE}" ]]; then
      cat "${SUMMARY_FILE}"
    else
      echo "### 🛡️ ${SCAN_TYPE} scan"
    fi
    echo ""
    echo "**Verdict:** ${VERDICT}"
    echo ""
    echo "#### What is left to act on"
    echo ""
    generate_action_table
    if [[ ${#REASONS[@]} -gt 0 ]]; then
      echo ""
      if [[ ${EXIT_CODE} -eq 1 ]]; then
        printf -- '- %s\n' "${REASONS[@]}"
      else
        echo "<details><summary>Details (${#REASONS[@]})</summary>"
        echo ""
        printf -- '- %s\n' "${REASONS[@]}"
        echo ""
        echo "</details>"
      fi
    fi
    # A scan that found nothing has no full report worth opening.
    if [[ -s "${ALL_FOUND_FILE}" ]]; then
      echo ""
      echo "Full findings: \`${TRIVY_SCAN_REPORT_NAME}.md\` in this run's artifacts."
    fi
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"

  # Surface errors on the run page itself, not only inside the summary tab.
  if [[ ${EXIT_CODE} -eq 1 ]]; then
    for REASON in "${REASONS[@]}"; do
      case "${REASON}" in
        Error:*) echo "::error title=${SCAN_TYPE} scan::${REASON#Error: }" ;;
      esac
    done
  elif [[ ${EXIT_CODE} -eq 2 ]]; then
    for REASON in "${REASONS[@]}"; do
      case "${REASON}" in
        Warning:*) echo "::warning title=${SCAN_TYPE} scan::${REASON#Warning: }" ;;
      esac
    done
  fi
}

main() {
  export LC_ALL=C
  if [[ "${SKIP_CVE_SCAN}" == "true" ]]; then
    echo "SKIP_CVE_SCAN=true - skipping the ${SCAN_TYPE:-security} scan."
    exit 0
  fi
  setup_temp_files
  print_separator
  echo "Unified Security & License Scanner"
  print_separator
  echo ""
  validate_scan_type
  execute_trivy_scan
  log_info "Loading ignored items configuration..."
  load_ignored_items
  echo ""
  case "${SCAN_TYPE}" in
    image|config|sbom)
      log_info "Processing CVE/misconfiguration scan results..."
      process_cve_scan
      ;;
    license)
      log_info "Processing license scan results..."
      process_license_scan
      ;;
  esac
  print_final_summary
  auto_generate_detected_findings
  publish_step_summary
  exit ${EXIT_CODE}
}

main "${@}"
