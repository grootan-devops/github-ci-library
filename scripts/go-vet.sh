#!/usr/bin/env bash
# go vet, honouring a `// govet:ignore` pragma on the line above a finding.
#
# Port of the GitLab `Go:Vet` job. go vet has no native suppression mechanism,
# so findings are filtered against the preceding source line.
set -euo pipefail

GO_VET_OUTPUT=$(go vet ./... 2>&1 || true)
GO_VET_FILTERED_OUTPUT=""

while IFS= read -r LINE; do
  # Package banners and toolchain notices are not findings.
  if [[ "${LINE}" =~ ^#\  ]] || [[ "${LINE}" =~ ^\[[^]]+\] ]]; then
    continue
  fi

  if [[ "${LINE}" =~ ^([^:]+):([0-9]+): ]]; then
    GO_VET_FILE=${BASH_REMATCH[1]}
    GO_VET_LINE_NO=${BASH_REMATCH[2]}
    GO_VET_PREV_LINE_NUM=$((GO_VET_LINE_NO - 1))
    GO_VET_PREV_LINE=$(sed "${GO_VET_PREV_LINE_NUM}q;d" "${GO_VET_FILE}" 2>/dev/null | tr -d '\r')

    if [[ "${GO_VET_PREV_LINE}" =~ ^[[:space:]]*//[[:space:]]*govet:ignore ]]; then
      continue
    fi
  fi

  GO_VET_FILTERED_OUTPUT+="${LINE}"$'\n'
done <<< "${GO_VET_OUTPUT}"

if grep -qv '^[[:space:]]*$' <<<"${GO_VET_FILTERED_OUTPUT}"; then
  printf "%s" "${GO_VET_FILTERED_OUTPUT}" >&2
  echo "::error title=go vet::go vet reported findings. Fix them, or annotate an accepted one with '// govet:ignore' on the preceding line."
  exit 1
fi

echo "go vet passed."
