#!/usr/bin/env bash
# Decide whether the Sonar analysis cache entry should be re-saved today.
#
# actions/cache/save refuses to overwrite a key that already exists, so a
# long-lived analysis cache would freeze on the day it was first written and
# slowly stop matching the project. Deleting the entry through the caches API
# lets the save step write a fresh one -- but at most once a day, so repeated
# pushes to the default branch do not churn the cache. A calling workflow that
# withheld `actions: read`/`write` gets a warning annotation and an unchanged
# entry, never a failed build.
#
# Writes `save=true|false` to GITHUB_OUTPUT; the cache/save step keys off it.
#
# Exit codes: always 0. A caches API that refuses the delete is a warning, not
# a build failure.
#
# Env:
#   GH_TOKEN    token presented to the caches API
#   CACHE_KEY   exact cache key to look for and replace
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${CACHE_KEY:?CACHE_KEY must be set}"

STAMP=".sonar/.cached-on"
TODAY="$(date -u +%Y-%m-%d)"

# The caches API matches `key` as a PREFIX, so filter for the exact key.
# jq does the filtering: `--jq` is a `gh api` flag that curl rejects outright,
# and the discarded stderr turned that into "no entry" on every run, so the
# delete below never fired and the entry froze on the day it was first saved.
LOOKUP_STATUS=0
# `-f` so a 403/404 fails the pipeline with curl's own message; without it the
# JSON error body reaches jq and the log shows a puzzling "Cannot iterate over
# null" instead of the permission problem that actually caused it.
EXISTING="$(curl -sSf -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/caches?key=${CACHE_KEY}" \
  | jq -r --arg key "${CACHE_KEY}" '[.actions_caches[] | select(.key == $key)] | length')" || LOOKUP_STATUS=$?

# A token without `actions: read` cannot list caches; treat that as "no entry"
# so the job still finishes, but say so rather than pretending the check ran.
if [[ "${LOOKUP_STATUS}" -ne 0 ]]; then
  echo "::warning title=Sonar cache::Could not list caches for '${CACHE_KEY}'; assuming there is none. Grant 'actions: read' in the calling workflow."
  EXISTING=0
fi

if [[ "${EXISTING}" == "0" ]]; then
  mkdir -p .sonar && echo "${TODAY}" > "${STAMP}"
  echo "save=true" >> "${GITHUB_OUTPUT}"
  exit 0
fi

if [[ -f "${STAMP}" ]] && [[ "$(cat "${STAMP}")" == "${TODAY}" ]]; then
  echo "Analysis cache was already refreshed today; keeping it."
  echo "save=false" >> "${GITHUB_OUTPUT}"
  exit 0
fi

mkdir -p .sonar && echo "${TODAY}" > "${STAMP}"
if curl -sS -X DELETE -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" -o /dev/null -w "%{http_code}" "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/caches?key=${CACHE_KEY}" | grep -qE "^(200|204)$"; then
  echo "save=true" >> "${GITHUB_OUTPUT}"
else
  echo "::warning title=Sonar cache::Could not replace '${CACHE_KEY}'. Grant 'actions: write' in the calling workflow to let it refresh."
  echo "save=false" >> "${GITHUB_OUTPUT}"
fi
