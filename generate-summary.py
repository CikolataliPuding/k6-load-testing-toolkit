#!/usr/bin/env python3
"""
generate-summary.py — combined summary report for run-all-tests.sh (point 4).

Reads the k6 --summary-export JSON files (one per test type, written by
run-all-tests.sh) and recovery_times.log (written by its adaptive cooldown,
point 3), and builds a single HTML page with one row per test so metrics
across Load/Spike/Soak/Stress can be compared at a glance.

This script is purely additive and read-only with respect to the existing
outputs: it never modifies the individual k6-reporter HTML reports
(<target>_<type>_report.html) or the terminal logs
(<target>_<type>_terminal_log.txt) — it only reads the *_summary.json
files and recovery_times.log, and writes one new file:
<RUN_DIR>/<target>_summary.html

Usage:
  python3 generate-summary.py <TARGET_APP> [RUN_DIR]

  RUN_DIR defaults to ./<TARGET_APP>, matching the folder run-all-tests.sh
  creates for that target.

Design note: if a test's summary JSON is missing (e.g. that test crashed
before producing one), its row is rendered with "N/A" values instead of
failing the whole report — this script's job (point 4) is independent of
whether points 1-3 succeeded for every individual test.
"""
import json
import os
import re
import sys
from datetime import datetime

TEST_ORDER = ["load", "spike", "soak", "stress"]


def load_summary(run_dir, target_app, test_type):
    path = os.path.join(
        run_dir,
        f"{target_app}_{test_type}",
        f"{target_app}_{test_type}_summary.json",
    )
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def metric_value(metrics, name, *value_keys):
    m = metrics.get(name)
    if not m:
        return None
    values = m.get("values", {})
    for key in value_keys:
        if key in values:
            return values[key]
    return None


def threshold_passed(result):
    """k6's --summary-export format for a threshold result varies by
    version: sometimes a plain bool (True = passed), sometimes an object
    like {"ok": true}. Handle both so this doesn't crash on either."""
    if isinstance(result, bool):
        return result
    if isinstance(result, dict):
        return result.get("ok", True)
    return True


def count_failed_thresholds(metrics):
    failed = 0
    total = 0
    for m in metrics.values():
        thresholds = m.get("thresholds")
        if not thresholds:
            continue
        for _, result in thresholds.items():
            total += 1
            if not threshold_passed(result):
                failed += 1
    return failed, total


def parse_recovery_log(run_dir):
    """Returns {test_type: recovery_label} keyed by the test that just finished."""
    log_path = os.path.join(run_dir, "recovery_times.log")
    recoveries = {}
    if not os.path.isfile(log_path):
        return recoveries
    # recovered_in is either a "start-end" window (e.g. "24-36s") or
    # "TIMEOUT(300s)" — both matched by the character class below.
    pattern = re.compile(
        r"after=(?P<after>\w+)\s+before=(?P<before>\w+).*?recovered_in=(?P<recovered>[\w.()-]+)"
    )
    with open(log_path, "r", encoding="utf-8") as f:
        for line in f:
            match = pattern.search(line)
            if match:
                recoveries[match.group("after")] = match.group("recovered")
    return recoveries


def build_row(run_dir, target_app, test_type, recoveries):
    data = load_summary(run_dir, target_app, test_type)

    recovery_label = recoveries.get(test_type)
    if recovery_label is None:
        recovery_label = "N/A (last test)" if test_type == "stress" else "N/A"
    elif not recovery_label.startswith("TIMEOUT"):
        recovery_label = f"{recovery_label}"

    if data is None:
        return {
            "test_type": test_type,
            "total_requests": "N/A",
            "error_rate": "N/A",
            "p95": "N/A",
            "thresholds_breached": "N/A",
            "breakpoint": "N/A",
            "recovery": recovery_label,
            "missing": True,
        }

    metrics = data.get("metrics", {})
    total_requests = metric_value(metrics, "http_reqs", "count")
    error_rate = metric_value(metrics, "http_req_failed", "rate")
    p95 = metric_value(metrics, "http_req_duration", "p(95)")
    failed, total = count_failed_thresholds(metrics)

    breakpoint_str = "N/A"
    if test_type == "stress":
        req_rate = metric_value(metrics, "http_reqs", "rate")
        peak_vus = metric_value(metrics, "vus_max", "value")
        if req_rate is not None or peak_vus is not None:
            breakpoint_str = f"~{req_rate:.1f} req/s" if req_rate is not None else "N/A req/s"
            if peak_vus is not None:
                breakpoint_str += f" (~{int(peak_vus)} VUs)"

    return {
        "test_type": test_type,
        "total_requests": f"{int(total_requests):,}" if total_requests is not None else "N/A",
        "error_rate": f"{error_rate * 100:.2f}%" if error_rate is not None else "N/A",
        "p95": f"{p95:.0f} ms" if p95 is not None else "N/A",
        "thresholds_breached": f"{failed} / {total}" if total else "0 / 0",
        "breakpoint": breakpoint_str,
        "recovery": recovery_label,
        "missing": False,
    }


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render_html(target_app, rows, generated_at):
    row_html = []
    for r in rows:
        css_class = ' class="missing"' if r["missing"] else ""
        row_html.append(f"""      <tr{css_class}>
        <td>{esc(r['test_type'].capitalize())}</td>
        <td>{esc(r['total_requests'])}</td>
        <td>{esc(r['error_rate'])}</td>
        <td>{esc(r['p95'])}</td>
        <td>{esc(r['thresholds_breached'])}</td>
        <td>{esc(r['breakpoint'])}</td>
        <td>{esc(r['recovery'])}</td>
      </tr>""")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{esc(target_app)} - k6 Test Summary</title>
<style>
  body {{ font-family: -apple-system, "Segoe UI", Roboto, sans-serif; margin: 2rem; background: #f7f7f9; color: #1a1a1a; }}
  h1 {{ font-size: 1.4rem; margin-bottom: 0.25rem; }}
  .meta {{ color: #666; margin-bottom: 1.5rem; font-size: 0.9rem; }}
  table {{ border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  th, td {{ padding: 0.6rem 0.9rem; text-align: left; border-bottom: 1px solid #e5e5e5; }}
  th {{ background: #24292e; color: #fff; font-weight: 600; }}
  tr:last-child td {{ border-bottom: none; }}
  tr.missing td {{ color: #999; font-style: italic; }}
  tr:hover td {{ background: #fafafa; }}
</style>
</head>
<body>
  <h1>{esc(target_app)} - Combined k6 Test Summary</h1>
  <p class="meta">Generated {esc(generated_at)} - Order: Load &rarr; Spike &rarr; Soak &rarr; Stress</p>
  <table>
    <thead>
      <tr>
        <th>Test</th>
        <th>Total Requests</th>
        <th>Error Rate</th>
        <th>P95 Duration</th>
        <th>Thresholds Breached</th>
        <th>Breakpoint (Stress only)</th>
        <th>Recovery Time (before next test)</th>
      </tr>
    </thead>
    <tbody>
{chr(10).join(row_html)}
    </tbody>
  </table>
</body>
</html>
"""


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 generate-summary.py <TARGET_APP> [RUN_DIR]", file=sys.stderr)
        sys.exit(1)

    target_app = sys.argv[1]
    run_dir = sys.argv[2] if len(sys.argv) > 2 else target_app

    recoveries = parse_recovery_log(run_dir)
    rows = [build_row(run_dir, target_app, t, recoveries) for t in TEST_ORDER]

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    html = render_html(target_app, rows, generated_at)

    out_path = os.path.join(run_dir, f"{target_app}_summary.html")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)

    print(out_path)


if __name__ == "__main__":
    main()
