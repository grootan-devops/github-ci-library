#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${MOCK_CHARTS//[[:space:]]/}" ]]; then
  echo "::error::Set mock-chart to space-separated chart directories." >&2
  exit 1
fi

read -r -a mock_charts <<< "${MOCK_CHARTS}"
report_dir="${RUNNER_TEMP}/chart-unittest"
mkdir -p "${report_dir}"
: > "${RUNNER_TEMP}/helm-unittest.log"

status=0
chart_index=0
for mock_chart in "${mock_charts[@]}"; do
  chart_path="${CHART_DIR}/${mock_chart}"
  if [[ ! -f "${chart_path}/Chart.yaml" ]]; then
    echo "::error::Mock chart '${chart_path}' lacks Chart.yaml." >&2
    exit 1
  fi
  if ! compgen -G "${chart_path}/tests/*_test.yaml" >/dev/null; then
    echo "::error::No test suites under ${chart_path}/tests/." >&2
    exit 1
  fi

  set +e
  helm unittest --strict \
    --output-type JUnit \
    --output-file "${report_dir}/unittest-report-${chart_index}.xml" \
    --file "${chart_path}/tests/*_test.yaml" \
    "${chart_path}" 2>&1 | tee -a "${RUNNER_TEMP}/helm-unittest.log"
  pipeline_statuses=("${PIPESTATUS[@]}")
  set -e

  helm_failed="${pipeline_statuses[0]}"
  tee_failed="${pipeline_statuses[1]}"
  if (( helm_failed != 0 || tee_failed != 0 )); then
    status=1
  fi
  chart_index=$((chart_index + 1))
done

exit "${status}"
