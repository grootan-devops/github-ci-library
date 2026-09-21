#!/usr/bin/env bash
# Render the Trivy database cache outcome into the job step summary.
#
# A working cache is invisible in the log, so a run that silently rebuilt the
# databases from scratch reads exactly like one that restored them in seconds.
# This table states which of the two happened, whether the entry was written
# back, and how large it ended up -- enough to trace a pipeline that is slowly
# getting slower to a cache entry that never sticks.
#
# Exit codes: always 0. The step runs with `if: always()` and must not turn an
# otherwise passing job red.
#
# Env:
#   CACHE_HIT        "true" when the restore step matched the `trivy-db` entry
#   REFRESHED        "true" when this run replaces the entry (default: empty)
#   JAVA_DB          trivy-java-db outcome; empty when it was not warmed
#   TRIVY_CACHE_DIR  cache directory to measure (set by the workflow env block)
set -euo pipefail

: "${CACHE_HIT:=}"
: "${REFRESHED:=}"
: "${JAVA_DB:=}"

if [[ "${CACHE_HIT}" == "true" ]]; then
  RESTORED="restored from the existing \`trivy-db\` entry"
else
  RESTORED="rebuilt — no \`trivy-db\` entry matched, so this run downloaded the databases"
fi
if [[ "${REFRESHED}" == "true" ]]; then
  WRITTEN="yes — this run replaces the \`trivy-db\` entry"
else
  WRITTEN="no — already refreshed today, or \`actions: write\` was not granted"
fi
SIZE="$(du -sh "${TRIVY_CACHE_DIR}" 2>/dev/null | awk '{print $1}' || true)"
{
  echo "### 🗄️ Trivy database cache"
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  echo "| **Cache** | ${RESTORED} |"
  echo "| **Written back** | ${WRITTEN} |"
  # Set only when the Java DB was actually warmed.
  if [[ -n "${JAVA_DB}" ]]; then
    echo "| **Java DB** | ${JAVA_DB} |"
  fi
  if [[ -n "${SIZE}" ]]; then
    echo "| **Size** | ${SIZE} |"
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
