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
#   ./run-all-tests.sh <TARGET_APP> [options]
#   ./run-all-tests.sh kurum-do-login
#   ./run-all-tests.sh kurum-do-login --tests=load,spike
#   ./run-all-tests.sh kurum-do-login --no-adaptive-cooldown --no-summary
#   ./run-all-tests.sh kurum-do-login --menu
#
# Options:
#   --tests=load,spike,soak,stress   Which tests to run (any subset, any
#                                     order in the flag — always executed in
#                                     the canonical load->spike->soak->stress
#                                     order). Default: all four.
#   --no-adaptive-cooldown           Always use the fixed cooldown below,
#                                     skip curl-based health-check probing.
#   --no-summary                     Skip generating the combined
#                                     <TARGET_APP>_summary.html at the end.
#   --menu                           Prompt interactively for the above
#                                     instead of passing flags.
#   -h, --help                       Show usage and exit.
#
# See docs/test-durations.md / README.md for context on why the test
# durations here are shortened compared to production recommendations.

set -uo pipefail
# NOTE: intentionally NOT using `set -e`. If one test fails (e.g. threshold
# breach, non-zero k6 exit code), the script logs the failure and CONTINUES
# to the next test in the sequence rather than aborting the whole run.

# Make every relative path used below (targets.json, master-test.js,
# generate-summary.py) resolve correctly no matter which directory this
# script is invoked FROM — previously they were relative to the caller's
# CWD, so running it via an absolute path from elsewhere would silently
# fail to find targets.json / master-test.js.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
ADAPTIVE_COOLDOWN_POLL_INTERVAL=12      # re-probe every 12s while waiting.
ADAPTIVE_COOLDOWN_RECOVERY_MARGIN=1.2   # "recovered" = response time <= baseline * 1.2 (i.e. within 20%).

ALL_TESTS=("load" "spike" "soak" "stress")
TEST_ORDER=("${ALL_TESTS[@]}")

print_usage() {
  cat <<USAGE
Usage: $0 <TARGET_APP> [options]

Options:
  --tests=load,spike,soak,stress   Which tests to run (comma-separated
                                    subset; always executed in the
                                    canonical load->spike->soak->stress
                                    order regardless of flag order).
                                    Default: all four.
  --no-adaptive-cooldown           Always use the fixed ${COOLDOWN_SECONDS}s
                                    cooldown; skip curl-based health-check
                                    probing (point 3).
  --no-summary                     Skip generating the combined
                                    <TARGET_APP>_summary.html at the end.
  --menu                           Prompt interactively for the above
                                    instead of passing flags.
  -h, --help                       Show this help and exit.

Examples:
  $0 kurum-do-login
  $0 kurum-do-login --tests=load,spike
  $0 kurum-do-login --no-adaptive-cooldown --no-summary
  $0 kurum-do-login --menu
USAGE
}

# ---- CLI options (toggle-able switches) ----
TARGET_APP=""
SELECTED_TESTS=""
DISABLE_ADAPTIVE_COOLDOWN=0
DISABLE_SUMMARY=0
INTERACTIVE_MENU=0

for arg in "$@"; do
  case "$arg" in
    --tests=*)
      SELECTED_TESTS="${arg#*=}"
      ;;
    --no-adaptive-cooldown)
      DISABLE_ADAPTIVE_COOLDOWN=1
      ;;
    --no-summary)
      DISABLE_SUMMARY=1
      ;;
    --menu)
      INTERACTIVE_MENU=1
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --*)
      echo "ERROR: unknown option '${arg}'" >&2
      print_usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$TARGET_APP" ]]; then
        TARGET_APP="$arg"
      else
        echo "ERROR: unexpected extra argument '${arg}'" >&2
        print_usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$TARGET_APP" ]]; then
  print_usage
  exit 1
fi

# ---- Interactive menu (--menu): prompts instead of requiring flags ----
if [[ $INTERACTIVE_MENU -eq 1 ]]; then
  echo "=== Interactive options menu (leave blank to accept the default) ==="
  read -r -p "Tests to run [load,spike,soak,stress]: " menu_tests
  if [[ -n "$menu_tests" ]]; then
    SELECTED_TESTS="$menu_tests"
  fi
  read -r -p "Enable adaptive cooldown? [Y/n]: " menu_adaptive
  if [[ "$menu_adaptive" =~ ^[Nn] ]]; then
    DISABLE_ADAPTIVE_COOLDOWN=1
  fi
  read -r -p "Generate combined summary report at the end? [Y/n]: " menu_summary
  if [[ "$menu_summary" =~ ^[Nn] ]]; then
    DISABLE_SUMMARY=1
  fi
  echo "==========================================================="
fi

# ---- Apply --tests= / menu selection, preserving canonical order ----
if [[ -n "$SELECTED_TESTS" ]]; then
  IFS=',' read -ra REQUESTED_TESTS <<< "$SELECTED_TESTS"
  for r in "${REQUESTED_TESTS[@]}"; do
    known=0
    for t in "${ALL_TESTS[@]}"; do
      [[ "$t" == "$r" ]] && known=1
    done
    if [[ $known -eq 0 ]]; then
      echo "WARNING: --tests contains unknown test name '${r}', ignoring it." >&2
    fi
  done

  FILTERED_TESTS=()
  for t in "${ALL_TESTS[@]}"; do
    for r in "${REQUESTED_TESTS[@]}"; do
      if [[ "$t" == "$r" ]]; then
        FILTERED_TESTS+=("$t")
        break
      fi
    done
  done

  if [[ ${#FILTERED_TESTS[@]} -eq 0 ]]; then
    echo "ERROR: --tests='${SELECTED_TESTS}' matched none of: ${ALL_TESTS[*]}" >&2
    exit 1
  fi
  TEST_ORDER=("${FILTERED_TESTS[@]}")
fi

# ---- Pre-flight checks ----
# Fail fast on structural problems instead of discovering them after
# burning through some/all of 4 tests' worth of cooldowns (the previous
# behavior: a missing k6 binary or a typo'd TARGET_APP would make every
# single test "fail" the same way, each still followed by a full cooldown).
if ! command -v "$K6_BIN" >/dev/null 2>&1; then
  echo "ERROR: k6 binary '${K6_BIN}' not found on PATH. Edit K6_BIN at the top of this script, or install k6." >&2
  exit 1
fi

if [[ ! -f "targets.json" ]]; then
  echo "ERROR: targets.json not found in ${SCRIPT_DIR}. Copy example.targets.json to targets.json and fill in your target(s)." >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  # Judge success/failure from an explicit marker printed to stdout, NOT
  # from the exit code alone: on some systems (e.g. Windows with the
  # Microsoft Store's "python3" PATH alias and no real Python installed)
  # `command -v python3` finds something, but running it prints an
  # unrelated install prompt and produces no real output. Trusting only
  # the exit code there previously caused a false "TARGET_APP not found"
  # even for a target that genuinely exists in targets.json. Any output
  # that isn't one of our expected markers is treated as "can't tell",
  # not as "not found" — so it degrades to a skipped check with a
  # warning instead of a wrong hard failure.
  PREFLIGHT_OUTPUT="$(python3 -c '
import json, sys
try:
    with open("targets.json", "r", encoding="utf-8") as f:
        targets = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    print(f"INVALID:{e}")
    sys.exit(0)
found = any(t.get("id") == sys.argv[1] for t in targets)
print("FOUND" if found else "NOTFOUND")
' "$TARGET_APP" 2>/dev/null)"

  case "$PREFLIGHT_OUTPUT" in
    FOUND)
      ;;
    NOTFOUND)
      echo "ERROR: TARGET_APP '${TARGET_APP}' not found in targets.json (check the 'id' field matches exactly)." >&2
      exit 1
      ;;
    INVALID:*)
      echo "ERROR: targets.json is not valid JSON (${PREFLIGHT_OUTPUT#INVALID:})." >&2
      exit 1
      ;;
    *)
      echo "WARNING: python3 on PATH didn't behave as expected (no usable output) — skipping the targets.json pre-flight check; a bad TARGET_APP will only be caught once k6 tries to run."
      ;;
  esac
else
  echo "WARNING: python3 not found — skipping the targets.json pre-flight check; a bad TARGET_APP will only be caught once k6 tries to run."
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

# Averages 2 samples (1s apart) instead of trusting a single curl call.
# A lone sample can be thrown off by a cold TCP/TLS handshake or a random
# network blip, which would then badly skew the whole recovery threshold
# for the rest of that cooldown. Falls back to whichever single sample
# succeeded if the other one fails.
measure_baseline() {
  local s1 s2
  s1="$(measure_response_time)"
  sleep 1
  s2="$(measure_response_time)"
  if [[ -n "$s1" && -n "$s2" ]]; then
    awk -v a="$s1" -v b="$s2" 'BEGIN { printf "%.3f", (a + b) / 2 }'
  elif [[ -n "$s1" ]]; then
    echo "$s1"
  else
    echo "$s2"
  fi
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
  # window_start/window_end bracket each poll: since we only sample every
  # ADAPTIVE_COOLDOWN_POLL_INTERVAL seconds, the actual recovery moment
  # could have happened anywhere inside that window, not exactly at
  # window_end — so we report the whole window as a range instead of
  # pretending we caught the precise second.
  while [[ $waited -lt $ADAPTIVE_COOLDOWN_MAX_SECONDS ]]; do
    local window_start=$waited
    sleep "$ADAPTIVE_COOLDOWN_POLL_INTERVAL"
    waited=$((waited + ADAPTIVE_COOLDOWN_POLL_INTERVAL))
    local window_end=$waited

    local current
    current="$(measure_response_time)"
    if [[ -z "$current" ]]; then
      echo "  ...[$(timestamp)] probe failed/timed out (window ${window_start}-${window_end}s), retrying..."
      continue
    fi

    local recovered
    recovered=$(awk -v c="$current" -v t="$threshold" 'BEGIN { print (c <= t) ? "1" : "0" }')
    echo "  ...[$(timestamp)] response time: ${current}s (window ${window_start}-${window_end}s, target <= ${threshold}s)"

    if [[ "$recovered" == "1" ]]; then
      echo "[$(timestamp)] Recovered sometime within ${window_start}-${window_end}s."
      echo "$(timestamp) | after=${after_test} before=${next_test} baseline=${baseline}s threshold=${threshold}s recovered_in=${window_start}-${window_end}s final=${current}s" >> "$RECOVERY_LOG"
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
# KNOWN LIMITATION: this always sends a plain GET to the target's "url",
# while the actual load test (for POST-login targets like kurum-do-login)
# hammers that same URL with POST. If GET serves a cheap static form page
# while POST does the real DB/auth work, "recovered" here may just mean
# "the lightweight path is fast again", not "the heavy path is". We
# deliberately do NOT probe with a real POST-login here: repeating the
# actual login payload every ADAPTIVE_COOLDOWN_POLL_INTERVAL seconds
# during cooldown would itself generate load on the exact path we're
# trying to let recover, and many login endpoints lock the account out
# after N attempts in a time window — turning a health-check into a
# self-inflicted denial of service. If you need a truer signal, point
# PROBE_URL (below) at a cheap, read-only endpoint that still exercises
# the same backend (e.g. a DB-backed status/health page), not the login
# handler itself.
RECOVERY_LOG="${RUN_DIR}/recovery_times.log"
PROBE_URL=""
if [[ $DISABLE_ADAPTIVE_COOLDOWN -eq 1 ]]; then
  echo "Adaptive cooldown: disabled via --no-adaptive-cooldown — using fixed ${COOLDOWN_SECONDS}s cooldown."
else
  if command -v curl >/dev/null 2>&1; then
    PROBE_URL="$(get_target_url "$TARGET_APP")" || PROBE_URL=""
  fi
  if [[ -n "$PROBE_URL" ]]; then
    echo "Adaptive cooldown probe URL: ${PROBE_URL}"
  else
    echo "Adaptive cooldown probe URL: unavailable (curl missing or no 'url' for '${TARGET_APP}' in targets.json) — will use fixed ${COOLDOWN_SECONDS}s cooldown."
  fi
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
  # starts (2-sample average, see measure_baseline), so the post-test
  # recovery check compares against a fresh, "just before we hit it"
  # response time rather than a stale or single-fluke-sample one.
  PRE_TEST_BASELINE=""
  if [[ -n "$PROBE_URL" ]]; then
    PRE_TEST_BASELINE="$(measure_baseline)"
    echo "[$(timestamp)] Pre-test baseline response time: ${PRE_TEST_BASELINE:-N/A}s"
  fi

  # BUG FIX: `{ ... }` is a shell GROUP, not a subshell, so STATUS set
  # inside it persists after the closing brace. A second `STATUS=$?`
  # right after `} > "$LOG_FILE" 2>&1` would instead capture the exit
  # code of the LAST command run inside the group — the trailing
  # `echo`, which always returns 0 — silently making every test look
  # like it succeeded regardless of k6's real exit code. Only the
  # capture INSIDE the group (right after the k6 invocation) is correct;
  # do not add another `STATUS=$?` after the group.
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
if [[ $DISABLE_SUMMARY -eq 1 ]]; then
  echo "Combined summary report: skipped (--no-summary). The per-test *_summary.json files are still there if you want to run generate-summary.py manually later."
else
  # SCRIPT_DIR was already resolved once at the top (and we already `cd`'d
  # into it), so this just reuses it instead of recomputing.
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
fi

echo "==========================================================="
echo "  Run complete — Egemen Korkmaz, k6-load-testing-toolkit"
echo "==========================================================="

# Non-zero exit if any test failed, so CI/cron/automation calling this
# script can actually detect a failed run instead of always seeing 0
# (this only works now that the STATUS-capture bug above is fixed —
# before, FAILED_TESTS was always empty regardless of what happened).
if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
