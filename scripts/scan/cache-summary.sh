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
#   CACHE_HIT        "true" when today's dated entry already existed
#   CACHE_DAY        the UTC day forming today's key (default: empty)
#   VULN_DB          trivy-db outcome
#   JAVA_DB          trivy-java-db outcome; empty when it was not warmed
#   TRIVY_CACHE_DIR  cache directory to measure (set by the workflow env block)
set -euo pipefail

: "${CACHE_HIT:=}"
: "${CACHE_DAY:=}"
: "${VULN_DB:=}"
: "${JAVA_DB:=}"
# Defaulted like its siblings: the step is `if: always()`, and aborting on an
# unbound variable would replace the diagnostic with no output at all.
: "${TRIVY_CACHE_DIR:=}"

if [[ "${CACHE_HIT}" == "true" ]]; then
  RESTORED="restored \`trivy-db-${CACHE_DAY}\` — already warmed today"
  WRITTEN="no — today's entry already exists"
else
  RESTORED="seeded from the most recent earlier entry, or built from scratch"
  WRITTEN="yes — saved as \`trivy-db-${CACHE_DAY}\` when this job ends"
fi
SIZE=""
if [[ -n "${TRIVY_CACHE_DIR}" && -d "${TRIVY_CACHE_DIR}" ]]; then
  SIZE="$(du -sh "${TRIVY_CACHE_DIR}" 2>/dev/null | awk '{print $1}' || true)"
fi
{
  echo "### 🗄️ Trivy database cache"
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  echo "| **Cache** | ${RESTORED} |"
  echo "| **Written back** | ${WRITTEN} |"
  if [[ -n "${VULN_DB}" ]]; then
    echo "| **Vulnerability DB** | ${VULN_DB} |"
  fi
  # Set only when the Java DB was actually warmed.
  if [[ -n "${JAVA_DB}" ]]; then
    echo "| **Java DB** | ${JAVA_DB} |"
  fi
  if [[ -n "${SIZE}" ]]; then
    echo "| **Size** | ${SIZE} |"
  fi
  echo ""
} >> "${GITHUB_STEP_SUMMARY}"
