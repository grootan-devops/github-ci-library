#!/usr/bin/env bash
# Generate a CycloneDX SBOM for the project with Trivy.
#
# Maven is the awkward case. Trivy reads a Java project's dependencies out of
# the local repository, so against a cold ~/.m2 it resolves nothing and writes
# an SBOM with zero components that the downstream scan then passes vacuously.
# When the Java dependency job has already populated the workspace cache we
# link it into place; when it has not we resolve inline and say so. If that
# inline resolution fails we stop here rather than hand Trivy an empty local
# repository, because a silently empty SBOM is worse than a slow one and worse
# than a red job.
#
# A Trivy failure here leaves the SBOM scan with nothing to check, so the error
# is written to the step summary as well as the log. Without it the scan job's
# clean summary is the only thing a reader sees, and it reads like a pass.
#
# Exit codes: 0 when an SBOM was produced, 1 when Maven dependency resolution
# failed, otherwise Trivy's own exit code.
#
# Env:
#   SBOM_FILE            CycloneDX output file (default: sbom.cdx.json)
#   GITHUB_WORKSPACE     runner-provided; locates the restored Maven cache
#   GITHUB_STEP_SUMMARY  runner-provided; the failure notice is appended here
set -euo pipefail

: "${SBOM_FILE:=sbom.cdx.json}"

if [[ -f pom.xml ]]; then
  if [[ -d "${GITHUB_WORKSPACE}/.m2/repository" ]]; then
    mkdir -p ~/.m2
    ln -sfn "${GITHUB_WORKSPACE}/.m2/repository" ~/.m2/repository
  else
    echo "::warning title=SBOM::Maven cache did not restore — resolving inline. Run the Java dependency job first to avoid this."
    # go-offline populates the local repository outright; dependency:resolve is
    # the narrower fallback for the projects whose plugins or profiles make
    # go-offline unhappy. Both failing means the local repository stays empty,
    # and Trivy would go on to write an SBOM with no components that the scan
    # job passes without having checked anything. Fail instead of shipping it.
    if ! mvn dependency:go-offline -q -B -DskipTests; then
      if ! mvn dependency:resolve -q -B -DskipTests; then
        echo "::error title=SBOM::Maven could not resolve dependencies, so no SBOM was generated."
        {
          echo "### 📄 SBOM"
          echo ""
          echo "❌ Maven dependency resolution failed, so no SBOM was generated."
          echo ""
          echo "Trivy reads a Java project's dependencies out of the local repository. Against an empty one it would have written an SBOM with zero components, and the SBOM scan would have reported no vulnerabilities without looking at a single dependency."
          echo ""
          echo "Run the Java dependency job first so the \`.m2\` cache is restored, or fix the resolution failure in the log above."
          echo ""
        } >> "${GITHUB_STEP_SUMMARY}"
        exit 1
      fi
    fi
  fi
fi

set +e
TRIVY_OUTPUT="$(trivy fs --format cyclonedx --output "${SBOM_FILE}" \
  --skip-version-check --skip-db-update --skip-java-db-update . 2>&1)"
TRIVY_RESULT=$?
set -e

if [[ -n "${TRIVY_OUTPUT}" ]]; then
  echo "${TRIVY_OUTPUT}"
fi

if [[ "${TRIVY_RESULT}" -ne 0 ]]; then
  echo "::error title=SBOM::Trivy could not produce a CycloneDX document."
  {
    echo "### 📄 SBOM"
    echo ""
    echo "❌ No SBOM was produced, so the SBOM scan has nothing to check. Trivy reported:"
    echo ""
    echo '```'
    tail -n 30 <<< "${TRIVY_OUTPUT}"
    echo '```'
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
  exit "${TRIVY_RESULT}"
fi
