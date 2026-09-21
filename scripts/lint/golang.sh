#!/usr/bin/env bash
# Runs one Go lint check, selected by the matrix leg's LINTER value.
#
# Every leg of the `lint` matrix runs this script with a different LINTER, so
# the four checks stay one code path instead of four near-identical steps.
# `fmt` cannot go through run_linted: `go fmt` rewrites files instead of
# reporting, so the check is "did it rewrite anything", and the diff it left
# behind is the only useful thing to show the developer. `vet` delegates to
# go-vet.sh, which filters findings annotated with `// govet:ignore`. The
# remaining two are ordinary linters and run through run_linted, which puts
# their own output in the job summary when they fail.
#
# Exit codes: 0 the check passed; 1 formatting drift, or LINTER names a check
# this workflow does not know; otherwise the linter's own exit code.
#
# Env:
#   LINTER             which check to run: fmt, vet, golangci-lint or gosec
#   GOLANGCI_TIMEOUT   value for `golangci-lint run --timeout` (that leg only)
#   GITHUB_WORKSPACE   runner-provided; locates the checked-out CI library
set -euo pipefail

# `?` rather than `:?`: an empty LINTER has to keep falling through to the
# unknown-check branch below, exactly as it did when this ran inline under -u.
: "${LINTER?LINTER must be set}"

# shellcheck source=scripts/lint/summary.sh
# shellcheck disable=SC1091 # resolved at runtime from the .ci-library checkout,
# so shellcheck cannot follow it without -x; the directive above names the file.
source "${GITHUB_WORKSPACE}/.ci-library/scripts/lint/summary.sh"

case "${LINTER}" in
  fmt)
    go fmt ./...
    DRIFT="$(git --no-pager diff)"
    if [[ -n "${DRIFT}" ]]; then
      echo "${DRIFT}"
      echo "::error title=go fmt::Formatting drift. Run 'go fmt ./...' and 'go mod tidy' locally and push the result."
      {
        echo "### 🐹 Go lint: fmt"
        echo ""
        echo "❌ \`go fmt ./...\` rewrote these files, so the committed source is not gofmt-clean:"
        echo ""
        echo '```'
        git --no-pager diff --stat
        echo '```'
        echo ""
        echo "Run \`go fmt ./...\` and \`go mod tidy\` locally and push the result."
        echo ""
      } >> "${GITHUB_STEP_SUMMARY}"
      exit 1
    fi
    echo "Formatting and dependency check passed."
    printf '### 🐹 Go lint: fmt\n\n✅ Already gofmt-clean.\n\n' >> "${GITHUB_STEP_SUMMARY}"
    ;;
  vet)
    bash "${GITHUB_WORKSPACE}/.ci-library/scripts/lint/go-vet.sh"
    ;;
  golangci-lint)
    run_linted "🐹 Go lint: golangci-lint" golangci-lint run --timeout "${GOLANGCI_TIMEOUT}"
    ;;
  gosec)
    run_linted "🐹 Go lint: gosec" gosec -exclude-generated -exclude-dir=.go-cache ./...
    ;;
  *)
    echo "::error title=Lint::Unknown Go check '${LINTER}'."
    # shellcheck disable=SC2016 # backticks are markdown, not command substitution
    printf '### 🐹 Go lint: %s\n\n❌ `%s` is not a Go check this workflow knows. The `linters` input accepts: fmt, vet, golangci-lint, gosec.\n\n' \
      "${LINTER}" "${LINTER}" >> "${GITHUB_STEP_SUMMARY}"
    exit 1
    ;;
esac
