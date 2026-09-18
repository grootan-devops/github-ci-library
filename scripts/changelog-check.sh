#!/usr/bin/env bash
# Verifies the release version has a changelog entry and renders that entry as
# a Microsoft Teams Adaptive Card fragment.
#
# Port of the GitLab `Changelog:Check Existence` job. The awk extraction, the
# full-file fallback and the jq card rendering are byte-for-byte the same.
#
# Required environment:
#   RELEASE_VERSION                     version whose section must exist
# Optional:
#   CHANGELOG_FILE_NAME                 default ./CHANGELOG.md
#   RELEASE_CHANGELOG_FILE_NAME         default RELEASE_CHANGELOG.md
#   RELEASE_CHANGELOG_CARD_FILE_NAME    default RELEASE_CHANGELOG_CARD.json
set -euo pipefail

: "${RELEASE_VERSION:?RELEASE_VERSION must be set}"
: "${CHANGELOG_FILE_NAME:=./CHANGELOG.md}"
: "${RELEASE_CHANGELOG_FILE_NAME:=RELEASE_CHANGELOG.md}"
: "${RELEASE_CHANGELOG_CARD_FILE_NAME:=RELEASE_CHANGELOG_CARD.json}"

echo "Checking if ${RELEASE_VERSION} version exist in ${CHANGELOG_FILE_NAME}..."

if [[ ! -f ${CHANGELOG_FILE_NAME} ]]; then
  echo "::error title=Changelog::${CHANGELOG_FILE_NAME} changelog is missing in the repo"
  exit 1
fi

awk -v ver="${RELEASE_VERSION}" '/^#+ \[/ { if (p) { exit }; if ($2 == "["ver"]") { p=1; next} } p && NF' "${CHANGELOG_FILE_NAME}" > "${RELEASE_CHANGELOG_FILE_NAME}"

if [[ ! -s ${RELEASE_CHANGELOG_FILE_NAME} ]]; then
  echo "changelog is empty. Make sure the changelog is following the keepachangelog.com standards."
  echo "Falling back to copying full changelogs from ${CHANGELOG_FILE_NAME}"
  cp "${CHANGELOG_FILE_NAME}" "${RELEASE_CHANGELOG_FILE_NAME}"
  if ! grep -q "${RELEASE_VERSION//./\\.}" "${RELEASE_CHANGELOG_FILE_NAME}"; then
    echo "::error title=Changelog::Changelog is either empty or doesnt have release version ${RELEASE_VERSION} specified in the ${CHANGELOG_FILE_NAME} file"
    exit 1
  fi
fi

jq -Rs '
  def clean_text:
    gsub("`"; "")
    | gsub("\\*\\*"; "");
  split("\n")
  | reduce .[] as $line (
      [];
      if ($line | test("^#{3,} +")) then
        . + [{
          type: "TextBlock",
          text: ($line | sub("^#{3,} +"; "") | clean_text),
          weight: "Bolder",
          spacing: (if length == 0 then "None" else "Medium" end),
          wrap: true
        }]
      elif ($line | test("^- +")) then
        . + [{
          type: "TextBlock",
          text: ("• " + ($line | sub("^- +"; "") | clean_text)),
          spacing: "Small",
          wrap: true
        }]
      elif ($line | length == 0) then .
      else
        . + [{
          type: "TextBlock",
          text: ($line | clean_text),
          spacing: "Small",
          wrap: true
        }]
      end
    )
' "${RELEASE_CHANGELOG_FILE_NAME}" > "${RELEASE_CHANGELOG_CARD_FILE_NAME}"

jq -e 'length > 0' "${RELEASE_CHANGELOG_CARD_FILE_NAME}" > /dev/null

cat "${RELEASE_CHANGELOG_FILE_NAME}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 📋 Changelog entry for \`${RELEASE_VERSION}\`"
    echo ""
    cat "${RELEASE_CHANGELOG_FILE_NAME}"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi
