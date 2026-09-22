#!/usr/bin/env bash
# Download the Trivy vulnerability, policy and Java databases once per run.
#
# Every later image, SBOM and config scan in the pipeline fetches these itself
# on a cold cache, so the same few hundred megabytes are pulled once per scan
# and the upstream registry starts rate-limiting a busy repository. Warming
# them here means the downstream scans restore them from the shared cache
# instead. A failed vulnerability-database download is only slow, so it is a
# warning; a failed trivy-java-db download is fatal later, because an image or
# SBOM scan of a Java artifact passes --skip-java-db-update and cannot recover
# from a cold cache, so that one gets the louder message.
#
# Writes `vuln_db` and, when the Java DB was warmed, `java_db` to GITHUB_OUTPUT;
# the summary step renders them.
#
# Exit codes: 0. A database that will not download is a warning, not a build
# failure.
#
# Env:
#   ENABLE_JAVA_DB  "true" also downloads trivy-java-db (~900MB)
#   TRIVY_HOST      shared Trivy server; when set, the vulnerability database
#                   is not downloaded (default: empty)
set -euo pipefail

: "${ENABLE_JAVA_DB:?ENABLE_JAVA_DB must be set}"
: "${TRIVY_HOST:=}"

# With a Trivy server configured, `trivy.sh` passes --server for image and SBOM
# scans and those never consult the local database -- so downloading it here is
# several hundred megabytes spent on a file nothing reads. The GitLab library
# warms only the checks bundle and the Java DB for the same reason.
if [[ -n "${TRIVY_HOST}" ]]; then
  VULN_DB="skipped — TRIVY_HOST is set, so image and SBOM scans use the server"
  echo "TRIVY_HOST is set; not downloading trivy-db."
elif trivy image --download-db-only --skip-version-check 2>&1 | tee "${RUNNER_TEMP}/vuln-db.log"; then
  VULN_DB="downloaded"
else
  VULN_DB="⚠️ **download failed** — every later scan downloads the database itself"
  echo "::warning title=Trivy cache::trivy-db did not download; image and SBOM scans will each fetch it."
fi
echo "vuln_db=${VULN_DB}" >> "${GITHUB_OUTPUT}"

mkdir -p .trivy-checks-warm
trivy config --skip-version-check .trivy-checks-warm || true
rmdir .trivy-checks-warm 2>/dev/null || true

if [[ "${ENABLE_JAVA_DB}" == "true" ]]; then
  echo "Warming trivy-java-db for downstream image and SBOM scans..."
  if trivy image --download-java-db-only --skip-version-check 2>&1 | tee "${RUNNER_TEMP}/java-db.log"; then
    JAVA_DB="downloaded"
  else
    JAVA_DB="⚠️ **download failed** — a later image or SBOM scan of a Java artifact will fail on the cold cache"
    echo "::warning title=Trivy cache::trivy-java-db did not download. Image and SBOM scans of Java artifacts will fail against this cache."
  fi
  echo "java_db=${JAVA_DB}" >> "${GITHUB_OUTPUT}"
else
  echo "enable-java-db is false — skipping trivy-java-db."
fi
