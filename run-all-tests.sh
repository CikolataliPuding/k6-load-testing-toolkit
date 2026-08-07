#!/usr/bin/env bash
#
# run-all-tests.sh — sequential demo test orchestration for master-test.js
#
# Runs Load -> Spike -> Soak -> Stress against a single TARGET_APP, in that
# order, with a fixed cooldown between each test. The order is deliberate:
# least destructive first, most destructive last. Soak runs before Stress
# so the leak/degradation check happens against a clean, unbroken system
# rather than one already weakened by the stress test.
#
# Usage:
#   ./run-all-tests.sh <TARGET_APP>
#   ./run-all-tests.sh kurum-do-login
#
# See docs/test-durations.md / README.md for context on why the test
# durations here are shortened compared to production recommendations.

set -uo pipefail
# NOTE: intentionally NOT using `set -e`. If one test fails (e.g. threshold
# breach, non-zero k6 exit code), the script logs the failure and CONTINUES
# to the next test in the sequence rather than aborting the whole run.

# ---- Configuration ----
K6_BIN="k6"                 # Path to the k6 binary. Edit if k6 is not on PATH,
                             # e.g. K6_BIN="/usr/local/bin/k6"
COOLDOWN_SECONDS=240         # 4 minutes fixed cooldown between tests.
TEST_ORDER=("load" "spike" "soak" "stress")

TARGET_APP="${1:-}"

if [[ -z "$TARGET_APP" ]]; then
  echo "Usage: $0 <TARGET_APP>"
  echo "Example: $0 kurum-do-login"
  exit 1
fi

FAILED_TESTS=()
REPORT_FILES=()

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# Countdown printed to the terminal during the cooldown between tests,
# instead of a silent `sleep`, so it's clear the script is still alive
# and not stuck. Prints a mark every 30s.
countdown() {
  local remaining=$1
  local step=30
  while [[ $remaining -gt 0 ]]; do
    local wait=$step
    if [[ $remaining -lt $step ]]; then
      wait=$remaining
    fi
    sleep "$wait"
    remaining=$((remaining - wait))
    echo "  ...cooldown: ${remaining}s remaining"
  done
}

echo "==========================================================="
echo "  k6 load-testing-toolkit — demo run"
echo "  by Egemen Korkmaz"
echo "==========================================================="
echo "=== run-all-tests.sh started at $(timestamp) ==="
echo "TARGET_APP=${TARGET_APP}"
echo "Order: ${TEST_ORDER[*]}"
echo "Cooldown between tests: ${COOLDOWN_SECONDS}s"
echo "k6 binary: ${K6_BIN}"
echo "==========================================================="

TOTAL=${#TEST_ORDER[@]}

# ---- Per-run output folder ----
# Everything for this TARGET_APP goes under RUN_DIR/, one subfolder per
# test type, e.g. deneme/deneme_load/, deneme/deneme_spike/, ...
RUN_DIR="${TARGET_APP}"
mkdir -p "$RUN_DIR"
echo "Output folder: ${RUN_DIR}/"
echo "==========================================================="

for i in "${!TEST_ORDER[@]}"; do
  TEST_TYPE="${TEST_ORDER[$i]}"
  TEST_DIR="${RUN_DIR}/${TARGET_APP}_${TEST_TYPE}"
  mkdir -p "$TEST_DIR"

  LOG_FILE="${TEST_DIR}/${TARGET_APP}_${TEST_TYPE}_terminal_log.txt"
  # master-test.js writes the report to the current directory using this
  # fixed name; we move it into TEST_DIR once the run finishes.
  RAW_REPORT_FILE="${TARGET_APP}_${TEST_TYPE}_report.html"
  REPORT_FILE="${TEST_DIR}/${TARGET_APP}_${TEST_TYPE}_report.html"

  echo ""
  echo "-----------------------------------------------------------"
  echo "[$(timestamp)] START ($((i + 1))/${TOTAL}): TEST_TYPE=${TEST_TYPE} TARGET_APP=${TARGET_APP}"
  echo "Output folder: ${TEST_DIR}/"
  echo "Logging to: ${LOG_FILE}"
  echo "-----------------------------------------------------------"

  {
    echo "=== ${TEST_TYPE} test started at $(timestamp) ==="
    "$K6_BIN" run -e "TARGET_APP=${TARGET_APP}" -e "TEST_TYPE=${TEST_TYPE}" master-test.js
    STATUS=$?
    echo "=== ${TEST_TYPE} test finished at $(timestamp) with exit code ${STATUS} ==="
  } > "$LOG_FILE" 2>&1
  STATUS=$?

  if [[ $STATUS -ne 0 ]]; then
    echo "[$(timestamp)] FAILED: ${TEST_TYPE} exited with code ${STATUS}. See ${LOG_FILE}. Continuing with next test."
    FAILED_TESTS+=("${TEST_TYPE} (exit ${STATUS})")
  else
    echo "[$(timestamp)] OK: ${TEST_TYPE} completed successfully."
  fi

  if [[ -f "$RAW_REPORT_FILE" ]]; then
    mv -f "$RAW_REPORT_FILE" "$REPORT_FILE"
    REPORT_FILES+=("$REPORT_FILE")
  fi

  echo "[$(timestamp)] END: TEST_TYPE=${TEST_TYPE}"

  # Skip cooldown after the last test.
  if [[ $((i + 1)) -lt $TOTAL ]]; then
    NEXT_TEST_TYPE="${TEST_ORDER[$((i + 1))]}"
    echo "[$(timestamp)] Cooldown: waiting ${COOLDOWN_SECONDS}s before next test (${NEXT_TEST_TYPE})..."
    countdown "$COOLDOWN_SECONDS"
    echo "[$(timestamp)] Cooldown finished."
  fi
done

echo ""
echo "==========================================================="
echo "=== run-all-tests.sh finished at $(timestamp) ==="

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  echo "Some tests reported failures (see individual log files):"
  for f in "${FAILED_TESTS[@]}"; do
    echo "  - ${f}"
  done
else
  echo "All tests completed successfully."
fi

echo ""
echo "Generated HTML reports:"
if [[ ${#REPORT_FILES[@]} -eq 0 ]]; then
  echo "  (none found)"
else
  for r in "${REPORT_FILES[@]}"; do
    echo "  - ${r}"
  done
fi
echo "==========================================================="
echo "  Run complete — Egemen Korkmaz, k6-load-testing-toolkit"
echo "==========================================================="
