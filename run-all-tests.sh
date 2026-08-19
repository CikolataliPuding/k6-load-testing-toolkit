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
COOLDOWN_SECONDS=240         # Fallback FIXED cooldown, only used if adaptive
                              # health-check probing below is unavailable
                              # (no curl, or no parsable url in targets.json).

# ---- Adaptive cooldown configuration (point 3) ----
# Instead of always waiting a blind fixed 240s, we probe the target's own
# page right before each test (baseline) and, after the test, keep
# re-probing until the response time recovers close to that baseline —
# a rough "did the system actually recover?" signal instead of a guess.
# A slow recovery is itself a soft signal of a possible resource leak
# from Soak, so we log every recovery time to recovery_times.log.
ADAPTIVE_COOLDOWN_MAX_SECONDS=300       # 5 min safety cap so we never hang forever.
ADAPTIVE_COOLDOWN_POLL_INTERVAL=10      # re-probe every 10s while waiting.
ADAPTIVE_COOLDOWN_RECOVERY_MARGIN=1.2   # "recovered" = response time <= baseline * 1.2 (i.e. within 20%).

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

# ---- Adaptive cooldown helpers (point 3) ----

# Reads the "url" field for TARGET_APP out of targets.json using python3
# (already a dependency for generate-summary.py below). Prints nothing
# and returns non-zero if it can't be resolved, so callers can fall back
# to the fixed cooldown.
get_target_url() {
  local id="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  python3 -c '
import json, sys
try:
    with open("targets.json", "r", encoding="utf-8") as f:
        targets = json.load(f)
except (OSError, json.JSONDecodeError):
    sys.exit(1)
target = next((t for t in targets if t.get("id") == sys.argv[1]), None)
if not target or not target.get("url"):
    sys.exit(1)
sys.stdout.write(target["url"])
' "$id"
}

# Prints response time in seconds (e.g. "0.842") for a GET against
# PROBE_URL, or nothing on failure/timeout.
measure_response_time() {
  curl -o /dev/null -s -w "%{time_total}" --max-time 10 "$PROBE_URL" 2>/dev/null
}

# Adaptive cooldown: probes PROBE_URL every ADAPTIVE_COOLDOWN_POLL_INTERVAL
# seconds until the response time drops back within
# ADAPTIVE_COOLDOWN_RECOVERY_MARGIN of the pre-test $3 baseline, or until
# ADAPTIVE_COOLDOWN_MAX_SECONDS is hit. Falls back to the fixed
# COOLDOWN_SECONDS countdown if probing isn't available for this run.
# Always appends one line to recovery_times.log — a slow/failed recovery
# after Soak is an indirect signal of a possible resource leak.
adaptive_cooldown() {
  local after_test="$1"
  local next_test="$2"
  local baseline="$3"

  if [[ -z "$PROBE_URL" || -z "$baseline" ]]; then
    echo "[$(timestamp)] No usable baseline (curl/targets.json url unavailable) — falling back to fixed ${COOLDOWN_SECONDS}s cooldown before ${next_test}."
    countdown "$COOLDOWN_SECONDS"
    return
  fi

  local threshold
  threshold=$(awk -v b="$baseline" -v m="$ADAPTIVE_COOLDOWN_RECOVERY_MARGIN" 'BEGIN { printf "%.3f", b * m }')

  echo "[$(timestamp)] Adaptive cooldown after ${after_test}: waiting for response time to recover to <= ${threshold}s (baseline ${baseline}s, max ${ADAPTIVE_COOLDOWN_MAX_SECONDS}s)..."

  local waited=0
  while [[ $waited -lt $ADAPTIVE_COOLDOWN_MAX_SECONDS ]]; do
    sleep "$ADAPTIVE_COOLDOWN_POLL_INTERVAL"
    waited=$((waited + ADAPTIVE_COOLDOWN_POLL_INTERVAL))

    local current
    current="$(measure_response_time)"
    if [[ -z "$current" ]]; then
      echo "  ...[$(timestamp)] probe failed/timed out (waited ${waited}s), retrying..."
      continue
    fi

    local recovered
    recovered=$(awk -v c="$current" -v t="$threshold" 'BEGIN { print (c <= t) ? "1" : "0" }')
    echo "  ...[$(timestamp)] response time: ${current}s (waited ${waited}s, target <= ${threshold}s)"

    if [[ "$recovered" == "1" ]]; then
      echo "[$(timestamp)] Recovered after ${waited}s."
      echo "$(timestamp) | after=${after_test} before=${next_test} baseline=${baseline}s threshold=${threshold}s recovered_in=${waited}s final=${current}s" >> "$RECOVERY_LOG"
      return
    fi
  done

  echo "[$(timestamp)] WARNING: did not recover to baseline within ${ADAPTIVE_COOLDOWN_MAX_SECONDS}s. Proceeding to ${next_test} anyway."
  echo "$(timestamp) | after=${after_test} before=${next_test} baseline=${baseline}s threshold=${threshold}s recovered_in=TIMEOUT(${ADAPTIVE_COOLDOWN_MAX_SECONDS}s)" >> "$RECOVERY_LOG"
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

# ---- Resolve the adaptive-cooldown probe URL (point 3) ----
RECOVERY_LOG="${RUN_DIR}/recovery_times.log"
PROBE_URL=""
if command -v curl >/dev/null 2>&1; then
  PROBE_URL="$(get_target_url "$TARGET_APP")" || PROBE_URL=""
fi
if [[ -n "$PROBE_URL" ]]; then
  echo "Adaptive cooldown probe URL: ${PROBE_URL}"
else
  echo "Adaptive cooldown probe URL: unavailable (curl missing or no 'url' for '${TARGET_APP}' in targets.json) — will use fixed ${COOLDOWN_SECONDS}s cooldown."
fi
echo "Recovery time log: ${RECOVERY_LOG}"
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
  # --summary-export dump (point 4): purely additive JSON metrics file
  # consumed by generate-summary.py. Does not touch the HTML report or
  # terminal log above in any way.
  SUMMARY_JSON_FILE="${TEST_DIR}/${TARGET_APP}_${TEST_TYPE}_summary.json"

  echo ""
  echo "-----------------------------------------------------------"
  echo "[$(timestamp)] START ($((i + 1))/${TOTAL}): TEST_TYPE=${TEST_TYPE} TARGET_APP=${TARGET_APP}"
  echo "Output folder: ${TEST_DIR}/"
  echo "Logging to: ${LOG_FILE}"
  echo "-----------------------------------------------------------"

  # Pre-test baseline probe (point 3): measured right before this test
  # starts, so the post-test recovery check compares against a fresh,
  # "just before we hit it" response time rather than a stale one.
  PRE_TEST_BASELINE=""
  if [[ -n "$PROBE_URL" ]]; then
    PRE_TEST_BASELINE="$(measure_response_time)"
    echo "[$(timestamp)] Pre-test baseline response time: ${PRE_TEST_BASELINE:-N/A}s"
  fi

  {
    echo "=== ${TEST_TYPE} test started at $(timestamp) ==="
    "$K6_BIN" run \
      -e "TARGET_APP=${TARGET_APP}" \
      -e "TEST_TYPE=${TEST_TYPE}" \
      --summary-export="${SUMMARY_JSON_FILE}" \
      master-test.js
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
    echo "[$(timestamp)] Cooldown before next test (${NEXT_TEST_TYPE})..."
    adaptive_cooldown "$TEST_TYPE" "$NEXT_TEST_TYPE" "$PRE_TEST_BASELINE"
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

# ---- Combined summary report (point 4) ----
# Purely additive: only reads the *_summary.json files (--summary-export
# above) and recovery_times.log; never touches the individual k6-reporter
# HTML reports or terminal logs. If python3 or the script is missing,
# this step is skipped with a warning — points 1-3 are unaffected either way.
echo ""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_SCRIPT="${SCRIPT_DIR}/generate-summary.py"
if command -v python3 >/dev/null 2>&1 && [[ -f "$SUMMARY_SCRIPT" ]]; then
  echo "[$(timestamp)] Generating combined summary report..."
  SUMMARY_FILE="$(python3 "$SUMMARY_SCRIPT" "$TARGET_APP" "$RUN_DIR")"
  if [[ -n "$SUMMARY_FILE" ]]; then
    echo "Combined summary report: ${SUMMARY_FILE}"
  else
    echo "WARNING: generate-summary.py ran but produced no output file."
  fi
else
  echo "WARNING: python3 or generate-summary.py not found — skipping combined summary report."
fi

echo "==========================================================="
echo "  Run complete — Egemen Korkmaz, k6-load-testing-toolkit"
echo "==========================================================="
