# k6 Load Testing Toolkit

A configuration-driven, reusable [Grafana k6](https://k6.io) load testing infrastructure. It enables five different test types—Load, Stress, Soak, Spike, and Scalability—to be executed against multiple targets defined in an external configuration file using a single master script.

## Why k6?

For this project, k6 was preferred over alternatives such as JMeter and Gatling for the following reasons:

* Scripts are written in JavaScript, making them easy to learn and suitable for version control as code.
* It is lightweight because it is written in Go, allowing it to generate higher loads with fewer resources compared to JVM-based tools.
* It provides natural compatibility with CI/CD integration and automation workflows.

## Features

* **Configuration-driven architecture:** Target information is stored separately from the source code in `targets.json`. New targets can be added without modifying the test scripts.
* **Five predefined test profiles:** Load, Stress, Soak, Spike, and Scalability. Each profile includes its own load pattern and success thresholds.
* **Dynamic authentication:** The `setup()` function obtains a fresh token at the beginning of each test. Credentials are not hardcoded into the script.
* **Automatic HTML reporting:** A visual and shareable report is generated automatically at the end of each test using [k6-reporter](https://github.com/benc-uk/k6-reporter).

## Installation

```bash
# Install k6 on Debian, Ubuntu, or Kali Linux
curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6

# Alternatively, refer to the official documentation:
# https://grafana.com/docs/k6/latest/set-up/install-k6/
```

## Usage

1. Copy `targets.json.example` as `targets.json` and configure it with your own targets:

   ```bash
   cp targets.json.example targets.json
   ```

   > `targets.json` is listed in `.gitignore` and must never be committed, as it may contain real credentials.

2. Run the desired test type:

   ```bash
   k6 run -e TARGET_APP=<id-from-targets.json> -e TEST_TYPE=load master-test.js
   k6 run -e TARGET_APP=<id> -e TEST_TYPE=stress master-test.js
   k6 run -e TARGET_APP=<id> -e TEST_TYPE=soak master-test.js
   k6 run -e TARGET_APP=<id> -e TEST_TYPE=spike master-test.js
   k6 run -e TARGET_APP=<id> -e TEST_TYPE=scalability master-test.js
   ```

3. After the test is completed, a report named `<id>_<test-type>_report.html` is generated automatically.

## `targets.json` Structure

```json
[
  {
    "id": "example-homepage",
    "name": "Example Application - Homepage",
    "url": "https://example.com/",
    "method": "GET",
    "payload": null,
    "headers": {
      "Accept": "text/html"
    }
  }
]
```

For targets that require authentication, the `loginUrl` and `credentials` fields can be added. The `setup()` function automatically uses these fields during authentication.

## Demo Automation: `run-all-tests.sh`

`run-all-tests.sh` runs Load, Spike, Soak, and Stress sequentially (not in parallel) against a single `TARGET_APP`, in that specific order:

```bash
./run-all-tests.sh <TARGET_APP>
./run-all-tests.sh kurum-do-login
```

* **Order — Load → Spike → Soak → Stress:** least destructive first, most destructive last. Soak deliberately runs before Stress so the leak/degradation check happens against a clean, unbroken system rather than one already weakened by the stress test. (`scalability` is not part of this automation and is still run manually.)
* A fixed **4-minute (240s) cooldown** is inserted between each test, with a countdown printed to the terminal every 30s so it's clear the script is still running.
* Results are organized per test into their own folder: `<TARGET_APP>/<TARGET_APP>_<TEST_TYPE>/`, e.g. `deneme/deneme_load/`, `deneme/deneme_spike/`. Each folder contains that test's terminal log (`..._terminal_log.txt`) and HTML report (`..._report.html`).
* Start/end timestamps are printed for every test and cooldown.
* The k6 binary path is configurable via the `K6_BIN` variable at the top of the script.
* If a test fails (non-zero k6 exit code), the failure is logged and the script **continues** with the remaining tests rather than aborting the whole run. A summary of failures and all generated HTML reports is printed at the end.

## A Note on Test Durations

The test durations in this repo (Load ~2min, Spike ~2-3min, Soak ~10-15min, Stress ~5-8min) have been SHORTENED to fit an internship/demo context. The original recommended values are kept as comments in the code (`master-test.js`).

Industry-standard recommendations for a real/production environment:

* Load Test steady-state: at least 20-60 minutes
* Soak Test: several hours to several days
* Stress Test: a few minutes of stabilization after each load increase

A FIXED 4-minute cooldown is used between tests. Note: a more advanced approach would be an adaptive health-check mechanism that measures whether the system has actually returned to baseline instead of using a fixed delay (logging the recovery time itself as a metric) — this repo currently uses a simple/fixed duration, noted here as an area for future improvement.

## Alternative Structure: `lib/` Directory

The `lib/scenario.js` file and individual files such as `load_test.js` and `stress_test.js` provide an alternative implementation based on a “one file per test type” approach.

The login and API scenario is defined in a single location inside `lib/scenario.js`, while each test file specifies only its own load profile through the `options` configuration.

## Ethical Use Disclaimer

This toolkit must be used **only** on systems that you own or for which you have received explicit written and signed authorization.

Do not directly target third-party shared infrastructure, such as cloud-based authentication services, as doing so may violate the service provider’s terms of use.

For more information, see the `docs/ethical-notes.md` file.

## License

MIT
