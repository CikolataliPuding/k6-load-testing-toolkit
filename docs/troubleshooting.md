# Troubleshooting / Error Reference

A single place to look up an error or exit code you saw while running
`run-all-tests.sh`, `master-test.js` (via k6), or `generate-summary.py`.
Each entry: what you'll see, what it actually means, what to do about it.

## `run-all-tests.sh` exit codes

| Exit code | Meaning |
|---|---|
| `0` | All 4 tests ran; none of them exited with a non-zero code. |
| `1` | Either a pre-flight check failed (see below — nothing ran), or at least one test exited non-zero (see the "Some tests reported failures" list printed at the end and `FAILED_TESTS`). |

## Pre-flight errors (printed immediately, before any test runs)

```
ERROR: k6 binary 'k6' not found on PATH. Edit K6_BIN at the top of this script, or install k6.
```
**Cause:** `k6` isn't installed, or isn't on `PATH` under that name.
**Fix:** Install k6 (see README "Installation"), or set `K6_BIN` at the top of `run-all-tests.sh` to the full path (e.g. `/usr/local/bin/k6`).

```
ERROR: targets.json not found in <path>. Copy example.targets.json to targets.json and fill in your target(s).
```
**Cause:** `targets.json` doesn't exist yet — it's gitignored on purpose (it can hold real credentials), so a fresh clone never has one.
**Fix:** `cp example.targets.json targets.json` and edit it.

```
ERROR: targets.json is not valid JSON (<python error detail>).
```
**Cause:** A syntax mistake in `targets.json` (trailing comma, missing quote, etc.).
**Fix:** Fix the JSON. The Python error detail after the colon tells you roughly where (line/column).

```
ERROR: TARGET_APP '<id>' not found in targets.json (check the 'id' field matches exactly).
```
**Cause:** The id you passed as `./run-all-tests.sh <id>` doesn't match any `"id"` field in `targets.json` — usually a typo.
**Fix:** Check `targets.json`'s `"id"` values match exactly (case-sensitive).

```
WARNING: python3 not found — skipping the targets.json pre-flight check; a bad TARGET_APP will only be caught once k6 tries to run.
WARNING: python3 on PATH didn't behave as expected (no usable output) — skipping the targets.json pre-flight check; ...
```
**Cause:** No usable `python3` (or, on some Windows setups, a Microsoft Store "python3" PATH alias that doesn't actually run Python). Not fatal — the check is just skipped, and a bad `TARGET_APP` will surface later as the k6-level error below instead.
**Fix:** Install a real `python3` if you want the fast pre-flight check; otherwise ignore, it's a degrade-gracefully warning, not an error.

## CLI flag errors/warnings (`--tests`, `--no-adaptive-cooldown`, `--no-summary`, `--menu`)

```
ERROR: unknown option '<flag>'
```
**Cause:** A typo'd or unsupported flag was passed.
**Fix:** Run `./run-all-tests.sh --help` for the exact list of supported flags.

```
WARNING: --tests contains unknown test name '<name>', ignoring it.
```
**Cause:** `--tests=` included something other than `load`, `spike`, `soak`, or `stress` (typo, e.g. `--tests=laod`).
**Fix:** Not fatal — that one name is just skipped; the rest of a valid list still runs. Check spelling if that wasn't intentional.

```
ERROR: --tests='<value>' matched none of: load spike soak stress
```
**Cause:** Every name in `--tests=` was invalid, leaving nothing to run.
**Fix:** Fix the test names; must be a comma-separated subset of `load,spike,soak,stress`.

## k6 / `master-test.js` errors (surface inside each test's `_terminal_log.txt`)

```
Error: '<id>' Application with ID not found in targets.json!
```
**Cause:** Same root cause as the pre-flight `TARGET_APP` error above, but this is the version thrown from inside `master-test.js` itself (you'll see this if the pre-flight check was skipped, e.g. no `python3`).
**Fix:** Check the `id` in `targets.json`.

```
Error: '<type>' is invalid. Valid options: load, stress, soak, spike, scalability
```
**Cause:** `TEST_TYPE` env var was something other than one of the 5 known profiles — shouldn't happen via `run-all-tests.sh` (it only ever passes the 4 fixed values), but can happen if you run `k6 run -e TEST_TYPE=...` manually with a typo.
**Fix:** Use one of the 5 valid values.

**k6's own exit codes** (these show up as the `exit code <N>` in `FAILED: <type> exited with code <N>`, and in each test's terminal log). The most common one you'll actually hit with this toolkit:

| Exit code | Meaning |
|---|---|
| `0` | Test completed, all thresholds passed. |
| `99` | **Thresholds have failed** — at least one `thresholds` condition in `options` was crossed. For the Stress test this is often the *expected*, intended outcome: `abortOnFail: true` on `http_req_failed` is what implements the breakpoint pattern (see README) — a `99` there means the breakpoint was found, not that something is "broken" in the toolkit itself. |
| other non-zero | k6-internal errors (bad script, `setup()`/`teardown()` threw, interrupted, etc.) — the exact numbers vary a bit by k6 version; check the surrounding log text in `_terminal_log.txt` for the actual error message, that's more reliable than memorizing every code. |

## Adaptive cooldown messages (informational, not necessarily errors)

```
[timestamp] No usable baseline (curl/targets.json url unavailable) — falling back to fixed 240s cooldown before <next>.
```
**Cause:** Either `curl` isn't installed, or `targets.json`'s `url` field for this target couldn't be read. The script just falls back to the old fixed-wait behavior — nothing is broken.

```
[timestamp] WARNING: did not recover to baseline within 300s. Proceeding to <next> anyway.
```
**Cause:** The target's response time never dropped back within 20% of its pre-test baseline within the 5-minute cap. This is itself a **signal worth paying attention to** — logged to `recovery_times.log` as `recovered_in=TIMEOUT(300s)` — a slow/failed recovery (especially right after Soak) can indicate a resource leak. It is not a script bug; the script deliberately moves on rather than hanging forever.

## `generate-summary.py`

```
AttributeError: 'bool' object has no attribute 'get'
```
**Status: fixed.** This was a real bug hit during development: k6's `--summary-export` JSON represents a passed/failed threshold differently across versions — sometimes as `{"ok": true}`, sometimes as a plain `true`/`false`. The original code only handled the object form. Fixed by `threshold_passed()` in `generate-summary.py`, which now accepts either shape. If you ever see this exact error again, it likely means a k6 version introduced a third format — check what `<target>_<type>_summary.json`'s `"thresholds"` values actually look like and extend `threshold_passed()` accordingly.

## Known limitation: static assets (CSS/JS/images) aren't part of the load

k6's `http.get`/`http.post` fetch **exactly the URL you give them** — unlike a real browser, k6 does not parse the returned HTML and automatically fetch the `<link>`/`<script>`/`<img>` resources it references. So a test against `index.php` only measures that one request; the page's stylesheet, JS bundle, and images are never requested during the test, even though a real visitor's browser would fetch all of them.

**Does it matter?** Usually not for this toolkit's purpose: static assets are typically served from cache/CDN/a static file server and rarely stress the same backend (PHP/DB) that a login endpoint does — the real bottleneck this toolkit is aimed at (login/auth) is unaffected by this gap.

**If you do want static assets included**, two options, in increasing order of effort:
1. Add extra entries to `targets.json` for each static asset URL and reference them from a small addition to `master-test.js` (e.g. via `http.batch()` to fetch several in parallel per iteration, mimicking how a browser loads them concurrently).
2. Use k6's browser-automation module (`k6/browser`, requires k6 v0.42+) for a real, JS-rendering, all-resources-loaded page test — much heavier to set up and run, but actually simulates a browser rather than a single HTTP request.

Neither is implemented in this toolkit today; this section exists so the gap is a documented, deliberate scope decision rather than a silent surprise.
