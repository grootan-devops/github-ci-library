#!/usr/bin/env bash
# Posts a Microsoft Teams Adaptive Card for a release.
#
# Port of the GitLab `Release:Notification:Teams` job. The card template, the
# markdown-to-TextBlock fallback renderer and the multi-webhook fan-out are
# unchanged; only the links and fact set point at GitHub.
#
# Required environment:
#   TAG                                    release tag
# Optional:
#   RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL    comma-separated webhook URLs; unset = skip
#   RELEASE_CHANGELOG_CARD_FILE_NAME       pre-rendered card fragment
#   RELEASE_CHANGELOG_FILE_NAME            markdown fallback source
#   SONAR_EXTERNAL_URL / SONAR_PROJECT_KEY adds a SonarQube button
set -euo pipefail

: "${TAG:?TAG must be set}"
: "${RELEASE_CHANGELOG_FILE_NAME:=RELEASE_CHANGELOG.md}"
: "${RELEASE_CHANGELOG_CARD_FILE_NAME:=RELEASE_CHANGELOG_CARD.json}"
: "${RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL:=}"
: "${SONAR_EXTERNAL_URL:=}"
: "${SONAR_PROJECT_KEY:=}"
: "${PROJECT_TITLE:=${GITHUB_REPOSITORY##*/}}"
: "${COMMIT_AUTHOR:=${GITHUB_ACTOR:-unknown}}"
: "${COMMIT_TIMESTAMP:=$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"

ACTIONS='[
  {"type":"Action.OpenUrl","title":"🚀 Release Page","url":"'"${REPO_URL}/releases/tag/${TAG}"'","style":"positive"},
  {"type":"Action.OpenUrl","title":"📂 Source Code","url":"'"${REPO_URL}/tree/${TAG}"'"},
  {"type":"Action.OpenUrl","title":"📦 Release Assets","url":"'"${REPO_URL}/releases/tag/${TAG}"'"}
]'
if [[ -n "${SONAR_EXTERNAL_URL}" && -n "${SONAR_PROJECT_KEY}" ]]; then
  ACTIONS=$(jq --arg url "${SONAR_EXTERNAL_URL}/dashboard?id=${SONAR_PROJECT_KEY}" \
    '. + [{"type":"Action.OpenUrl","title":"🔍 SonarQube","url":$url}]' <<<"${ACTIONS}")
fi

jq -n \
  --arg title "🚀 ${PROJECT_TITLE} · ${TAG}" \
  --arg fallback "Release notification: ${PROJECT_TITLE} version ${TAG}." \
  --arg speak "Release notification for ${PROJECT_TITLE}, version ${TAG}. Published by ${COMMIT_AUTHOR} on ${COMMIT_TIMESTAMP}. Release notes are included in this card." \
  --arg author "${COMMIT_AUTHOR}" \
  --arg timestamp "${COMMIT_TIMESTAMP}" \
  --arg sha "${GITHUB_SHA:-unknown}" \
  --arg ref "${GITHUB_REF_NAME:-unknown}" \
  --argjson actions "${ACTIONS}" \
  '{
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    type: "AdaptiveCard",
    version: "1.4",
    fallbackText: $fallback,
    speak: $speak,
    msteams: { width: "Full" },
    body: [
      { type: "TextBlock", text: $title, weight: "Bolder", size: "Large", wrap: true, maxLines: 2 },
      { type: "ColumnSet", spacing: "Medium", columns: [
          { type: "Column", width: "auto", items: [
              { type: "Image", url: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png", size: "Small", altText: "GitHub" }
          ]},
          { type: "Column", width: "stretch", items: [
              { type: "TextBlock", text: $author, weight: "Bolder", size: "Default", spacing: "None", wrap: true },
              { type: "TextBlock", text: $timestamp, isSubtle: true, size: "Small", spacing: "None", wrap: true }
          ]}
      ]},
      { type: "FactSet", spacing: "Small", facts: [
          { title: "🔖 Commit", value: $sha },
          { title: "🌿 Branch", value: $ref }
      ]},
      { type: "TextBlock", text: "📋 Release Notes", weight: "Bolder", size: "Medium", spacing: "Medium", separator: true },
      { type: "Container", id: "release-notes", spacing: "Small", items: [] }
    ],
    actions: $actions
  }' > message_template.json

# Render the card body from markdown when the check job did not already do it.
if [[ ! -s "${RELEASE_CHANGELOG_CARD_FILE_NAME}" ]]; then
  if [[ -f "${RELEASE_CHANGELOG_FILE_NAME}" ]]; then
    jq -R -s -c '
      def clean_text: sub("\r$"; "") | gsub("[ \t]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
      split("\n") | reduce .[] as $line (
        [];
        if ($line | startswith("### ")) then
          . + [{
            type: "TextBlock",
            text: ($line | sub("^### +"; "") | clean_text),
            weight: "Bolder",
            size: "Default",
            spacing: "Medium",
            wrap: true
          }]
        elif ($line | startswith("- ")) then
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
    ' "${RELEASE_CHANGELOG_FILE_NAME}" > "${RELEASE_CHANGELOG_CARD_FILE_NAME}" 2>/dev/null \
      || echo "[]" > "${RELEASE_CHANGELOG_CARD_FILE_NAME}"
  else
    echo "[]" > "${RELEASE_CHANGELOG_CARD_FILE_NAME}"
  fi
fi

jq --slurpfile release_notes "${RELEASE_CHANGELOG_CARD_FILE_NAME}" '
  (.body[] | select(.id == "release-notes") | .items) = ($release_notes[0] // [])
  | {
      type: "message",
      attachments: [
        { contentType: "application/vnd.microsoft.card.adaptive", content: . }
      ]
    }
' message_template.json > message.json

if [[ -z "${RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL}" ]]; then
  echo "⚠️ Notice: RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL is not set or empty. Skipping sending notification."
  exit 0
fi

SENT_COUNT=0
IFS=',' read -r -a WEBHOOKS <<< "${RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL}"
for URL in "${WEBHOOKS[@]}"; do
  CLEAN_URL="$(printf '%s' "${URL}" | xargs)"
  if [[ -z "${CLEAN_URL}" ]]; then
    continue
  fi

  echo "Sending notification to Teams Workflow..."
  if ! HTTP_CODE="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
      -H "Content-Type: application/json" \
      --data-binary @message.json \
      "${CLEAN_URL}")"; then
    echo "::error title=Teams notification::Could not reach Teams Workflow endpoint."
    exit 1
  fi

  case "${HTTP_CODE}" in
    2??)
      echo "✅ Teams Workflow accepted the payload: HTTP ${HTTP_CODE}"
      SENT_COUNT=$((SENT_COUNT + 1))
      ;;
    *)
      echo "::error title=Teams notification::Teams Workflow rejected the payload: HTTP ${HTTP_CODE}"
      exit 1
      ;;
  esac
done

if [[ ${SENT_COUNT} -eq 0 ]]; then
  echo "⚠️ Notice: No valid webhook URLs provided in RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL."
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  # shellcheck disable=SC2016 # backticks are markdown, not command substitution
  printf '### 📣 Teams notification\n\nDelivered to %s webhook(s) for `%s`.\n\n' "${SENT_COUNT}" "${TAG}" >> "${GITHUB_STEP_SUMMARY}"
fi
