#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${MOCK_CHARTS//[[:space:]]/}" ]]; then
  echo "::error::Set mock-chart to space-separated chart directories." >&2
  exit 1
fi

read -r -a MOCK_CHART_LIST <<< "${MOCK_CHARTS}"
REPORT_DIR="${RUNNER_TEMP}/chart-unittest"
mkdir -p "${REPORT_DIR}"
: > "${RUNNER_TEMP}/helm-unittest.log"

STATUS=0
CHART_INDEX=0
for MOCK_CHART_DIR in "${MOCK_CHART_LIST[@]}"; do
  MOCK_CHART_PATH="${CHART_DIR}/${MOCK_CHART_DIR}"
  if [[ ! -f "${MOCK_CHART_PATH}/Chart.yaml" ]]; then
    echo "::error::Mock chart '${MOCK_CHART_PATH}' lacks Chart.yaml." >&2
    exit 1
  fi
  if ! compgen -G "${MOCK_CHART_PATH}/tests/*_test.yaml" >/dev/null; then
    echo "::error::No test suites under ${MOCK_CHART_PATH}/tests/." >&2
    exit 1
  fi

  set +e
  helm unittest --strict \
    --output-type JUnit \
    --output-file "${REPORT_DIR}/unittest-report-${CHART_INDEX}.xml" \
    --file "${MOCK_CHART_PATH}/tests/*_test.yaml" \
    "${MOCK_CHART_PATH}" 2>&1 | tee -a "${RUNNER_TEMP}/helm-unittest.log"
  PIPELINE_STATUSES=("${PIPESTATUS[@]}")
  set -e

  HELM_FAILED="${PIPELINE_STATUSES[0]}"
  TEE_FAILED="${PIPELINE_STATUSES[1]}"
  if (( HELM_FAILED != 0 || TEE_FAILED != 0 )); then
    STATUS=1
  fi
  CHART_INDEX=$((CHART_INDEX + 1))
done

exit "${STATUS}"
