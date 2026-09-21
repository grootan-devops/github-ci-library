#!/usr/bin/env bash
# Decide whether the shared `trivy-db` cache entry should be re-saved today.
#
# actions/cache/save refuses to overwrite a key that already exists, so the
# `trivy-db` entry would freeze on the day it was first written and every scan
# in the organisation would keep restoring that day's vulnerability data.
# Deleting the entry through the caches API lets the save step write a fresh
# one -- but at most once a day, so repeated pushes to the default branch do
# not churn a multi-hundred-megabyte cache, and never noisily when the calling
# workflow withheld `actions: write`.
#
# The key is the literal string `trivy-db` and must stay byte-identical to the
# `key:` on the cache restore and save steps; any drift and every entry misses.
#
# Writes `save=true|false` to GITHUB_OUTPUT; the cache/save step keys off it.
#
# Exit codes: always 0. A caches API that refuses the delete is a warning, not
# a build failure.
#
# Env:
#   GH_TOKEN         token presented to the caches API
#   TRIVY_CACHE_DIR  cache directory, absolute (set by the workflow env block)
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${TRIVY_CACHE_DIR:?TRIVY_CACHE_DIR must be set}"

# Anchored to TRIVY_CACHE_DIR, not to the cwd: the job runs its steps from
# `project-path`, while trivy and actions/cache both use the absolute
# workspace-level directory. A relative path here would stamp and probe a
# second, empty .trivycache under a monorepo child, so the once-a-day
# short-circuit below could never fire.
STAMP="${TRIVY_CACHE_DIR}/.warmed-on"
TODAY="$(date -u +%Y-%m-%d)"

# The caches API matches `key` as a PREFIX, so filter for the exact key.
# curl and jq are checked separately, and neither failure is allowed to read as
# "no entry exists": a caller that withheld `actions: read`/`write` gets a 403
# whose JSON error body would otherwise count as zero entries, skipping the
# delete while still reporting a refresh in the step summary.
if ! CACHES="$(curl -sSf -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/caches?key=trivy-db")"; then
  echo "::warning title=Trivy cache::Could not read the caches API, so the 'trivy-db' entry was left alone. Grant 'actions: write' in the calling workflow to let it refresh."
  echo "save=false" >> "${GITHUB_OUTPUT}"
  exit 0
fi

if ! EXISTING="$(jq -r '[.actions_caches[] | select(.key == "trivy-db")] | length' <<<"${CACHES}")"; then
  echo "::warning title=Trivy cache::The caches API returned a body this script cannot read, so the 'trivy-db' entry was left alone."
  echo "save=false" >> "${GITHUB_OUTPUT}"
  exit 0
fi

if [[ "${EXISTING}" == "0" ]]; then
  mkdir -p "${TRIVY_CACHE_DIR}" && echo "${TODAY}" > "${STAMP}"
  echo "No 'trivy-db' entry yet; this run writes it."
  echo "save=true" >> "${GITHUB_OUTPUT}"
  exit 0
fi

if [[ -f "${STAMP}" ]] && [[ "$(cat "${STAMP}")" == "${TODAY}" ]] \
   && compgen -G "${TRIVY_CACHE_DIR}/db/*" > /dev/null 2>&1; then
  echo "'trivy-db' was already refreshed today and holds the database; keeping it."
  echo "save=false" >> "${GITHUB_OUTPUT}"
  exit 0
fi

mkdir -p "${TRIVY_CACHE_DIR}" && echo "${TODAY}" > "${STAMP}"
if curl -sS -X DELETE -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" -o /dev/null -w "%{http_code}" "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/caches?key=trivy-db" | grep -qE "^(200|204)$"; then
  echo "Replaced the 'trivy-db' entry with today's databases."
  echo "save=true" >> "${GITHUB_OUTPUT}"
else
  echo "::warning title=Trivy cache::Could not replace the 'trivy-db' entry. Grant 'actions: write' in the calling workflow to let it refresh."
  echo "save=false" >> "${GITHUB_OUTPUT}"
fi
