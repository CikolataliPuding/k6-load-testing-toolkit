import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { htmlReport } from "https://raw.githubusercontent.com/benc-uk/k6-reporter/main/dist/bundle.js";

// ---- Read target configurations ----
const appConfigs = new SharedArray('configs', function () {
  return JSON.parse(open('./targets.json'));
});

const targetId = __ENV.TARGET_APP;
const testType = __ENV.TEST_TYPE || 'load';

const targetApp = appConfigs.find(app => app.id === targetId);
if (!targetApp) {
  throw new Error(`'${targetId}' Application with ID not found in targets.json!`);
}

// ---- 5 TEST PROFILES (all defined) ----
// NOTE: load/spike/soak/stress durations below have been SHORTENED for
// internship/demo purposes. Run order for the demo automation is
// Load -> Spike -> Soak -> Stress (least destructive -> most destructive;
// Soak intentionally runs before Stress so the leak/degradation check
// happens against a clean, unbroken system). See docs/test-durations.md.
const scenarioProfiles = {
  load: {
    // PRODUCTION RECOMMENDATION (original/full-scale):
    // stages: [
    //   { duration: '1m', target: 150 },
    //   { duration: '2m', target: 150 },   // steady-state: at least 20-60min recommended
    //   { duration: '1m', target: 0 },
    // ],
    executor: 'ramping-vus', startVUs: 0,
    stages: [
      { duration: '30s', target: 150 },
      { duration: '1m',  target: 150 },
      { duration: '30s', target: 0 },
    ],
  },
  spike: {
    // PRODUCTION RECOMMENDATION (original/full-scale, still closed-model):
    // stages: [
    //   { duration: '30s', target: 40 },
    //   { duration: '20s', target: 500 },   // sudden rise
    //   { duration: '1m',  target: 500 },
    //   { duration: '20s', target: 40 },    // sudden drop
    //   { duration: '1m',  target: 20 },    // recovery
    //   { duration: '30s', target: 0 },
    // ],
    //
    // OPEN MODEL SWITCH (Little's Law rationale): this used to be
    // `ramping-vus` (a CLOSED model) — kept below for reference:
    //
    //   executor: 'ramping-vus', startVUs: 0,
    //   stages: [
    //     { duration: '20s', target: 40 },
    //     { duration: '15s', target: 500 },   // sudden rise
    //     { duration: '40s', target: 500 },
    //     { duration: '15s', target: 40 },    // sudden drop
    //     { duration: '30s', target: 20 },    // recovery
    //     { duration: '20s', target: 0 },
    //   ],
    //
    // In a closed model, a fixed pool of VUs each wait for their previous
    // request to finish before starting the next one. By Little's Law
    // (L = lambda * W), if the server slows down (W grows) the arrival
    // rate (lambda) is automatically throttled down too, since a limited
    // number of VUs can't fire more requests than their response time
    // allows. That self-throttling UNDERSTATES how severe a real
    // flash-crowd is: real users don't politely wait their turn to start
    // a new request — new arrivals keep piling on regardless of how slow
    // the server has become.
    //
    // `ramping-arrival-rate` is an OPEN model: it targets a planned
    // number of new iterations started per second, independent of how
    // long each iteration/request takes. If the server slows down, k6
    // spins up more VUs (up to maxVUs) to keep hitting the target arrival
    // rate, which is what actually happens during a real sudden traffic
    // spike.
    executor: 'ramping-arrival-rate',
    startRate: 40,          // iterations/sec at t=0, mirrors the old startVUs=40 warm-up level
    timeUnit: '1s',
    preAllocatedVUs: 200,   // pre-allocated worker pool, sized for the 200/s peak
    maxVUs: 600,            // headroom above preAllocatedVUs in case iterations run slower than 1s
    stages: [
      { duration: '20s', target: 40 },
      { duration: '15s', target: 200 },   // sudden rise
      { duration: '40s', target: 200 },
      { duration: '15s', target: 40 },    // sudden drop
      { duration: '30s', target: 20 },    // recovery
      { duration: '20s', target: 0 },
    ],
  },
  soak: {
    // PRODUCTION RECOMMENDATION (original/full-scale):
    // executor: 'constant-vus',
    // vus: 30,
    // duration: '30m',   // increase to 2-8 hours, or even days, for a true soak test.
    executor: 'constant-vus',
    vus: 30,
    duration: '12m',
  },
  stress: {
    // PRODUCTION RECOMMENDATION (original/full-scale, manually-guessed VU steps):
    // stages: [
    //   { duration: '2m', target: 100 },
    //   { duration: '2m', target: 200 },
    //   { duration: '2m', target: 400 },
    //   { duration: '2m', target: 600 },
    //   { duration: '2m', target: 0 },
    // ],
    //
    // Previous demo-shortened version — kept for reference:
    //   executor: 'ramping-vus', startVUs: 0,
    //   stages: [
    //     { duration: '1m', target: 100 },
    //     { duration: '1m', target: 200 },
    //     { duration: '1m', target: 400 },
    //     { duration: '1m', target: 600 },
    //     { duration: '1m', target: 0 },
    //   ],
    //
    // BREAKPOINT EXECUTOR: switched from hand-picked fixed VU steps to
    // k6's official breakpoint-testing pattern (see k6 docs "Breakpoint
    // testing"): an open-model `ramping-arrival-rate` that just keeps
    // ramping the request rate up, combined with an `abortOnFail`
    // threshold on http_req_failed below. Instead of us guessing which
    // VU count breaks the system, k6 keeps raising load on its own and
    // the test stops ITSELF the moment the real error-rate threshold is
    // crossed — that stopping point is the observed breaking point.
    // See handleSummary() below for where this is reported.
    executor: 'ramping-arrival-rate',
    startRate: 50,           // iterations/sec at t=0
    timeUnit: '1s',
    preAllocatedVUs: 200,    // worker pool pre-allocated for the ramp
    maxVUs: 600,            // headroom so k6 can keep pushing rate even as responses slow down
    stages: [
      // Demo-shortened single ramp (~5-8min budget); a real breakpoint
      // run typically ramps for 15min+ toward a much higher target so
      // the breaking point isn't reached artificially early.
      { duration: '6m', target: 500 },
    ],
  },
  // scalability: not part of the automated run-all-tests.sh sequence,
  // still executed manually (untouched/full-scale).
  scalability: {
    executor: 'ramping-vus', startVUs: 0,
    stages: [
      { duration: '1m', target: 100 },
      { duration: '2m', target: 200 },
      { duration: '2m', target: 300 },
      { duration: '1m', target: 0 },
    ],
  },
};

if (!scenarioProfiles[testType]) {
  throw new Error(`'${testType}' is invalid. Valid options: load, stress, soak, spike, scalability`);
}

// ---- Test type-specific realistic thresholds ----
const thresholdsByType = {
  load:  { http_req_duration: ['p(95)<2000'], http_req_failed: ['rate<0.01'] },
  // Breakpoint executor: automatic breakage detection instead of manual
  // guessing (see scenarioProfiles.stress above). `abortOnFail: true`
  // makes k6 stop the whole test run as soon as the error rate crosses
  // 10%, so the ramp doesn't keep grinding a broken system for no
  // reason. `delayAbortEval` gives it a few seconds of samples first so
  // a single early blip doesn't trigger a false abort.
  stress: {
    http_req_failed: [
      { threshold: 'rate<0.10', abortOnFail: true, delayAbortEval: '10s' },
    ],
  },
  soak:        { http_req_duration: ['p(95)<2500'], http_req_failed: ['rate<0.02'] },
  spike:       { http_req_failed: ['rate<0.20'] },
  scalability: { http_req_duration: ['p(95)<2000'], http_req_failed: ['rate<0.02'] },
};

// ---- RUN ONLY THE SELECTED TEST TYPE ----
export const options = {
  scenarios: { [testType]: scenarioProfiles[testType] },
  thresholds: thresholdsByType[testType],
  insecureSkipTLSVerify: true,  // ignore self-signed certs for demo purposes
};

// ---- LOGIN: fetch a token once at the beginning of the test (optional) ----
// If "loginUrl" and "credentials" are defined in targets.json, a dynamic token will be fetched.
export function setup() {
  if (targetApp.loginUrl && targetApp.credentials) {
    const res = http.post(
      targetApp.loginUrl,
      JSON.stringify(targetApp.credentials),
      { headers: { 'Content-Type': 'application/json' } }
    );
    try {
      const body = res.json();
      const token = body.token || body.access_token || (body.data && body.data.token);
      return { token };
    } catch (e) {
      return { token: null };
    }
  }
  return { token: null };
}

export default function (data) {
  let headers = Object.assign({}, targetApp.headers);

  // If a fresh token came from setup(), replace the placeholder in the header
  if (data.token) {
    headers['Authorization'] = `Bearer ${data.token}`;
  }

  let res;
  if (targetApp.method === 'GET') {
    res = http.get(targetApp.url, { headers });
  } else if (targetApp.method === 'POST') {
    res = http.post(targetApp.url, targetApp.payload, { headers });
  }

  const checks = {
    [`${targetApp.name} - successful (2xx)`]: (r) => r.status >= 200 && r.status < 300,
  };
  // Optional, config-driven (targets.json): a 2xx status alone doesn't
  // prove a login actually succeeded — plenty of PHP apps re-render the
  // same login page with HTTP 200 and an inline error on bad credentials.
  // If a target defines "failureIndicator" (a string that only appears
  // in the body on a failed login, e.g. "Invalid username or password"),
  // also fail the check when that string shows up in a "successful" response.
  if (targetApp.failureIndicator) {
    checks[`${targetApp.name} - no failure indicator in body`] =
      (r) => !r.body || !r.body.includes(targetApp.failureIndicator);
  }
  check(res, checks);

  // Closed-model executors (load/soak/scalability use ramping-vus /
  // constant-vus) rely on this sleep as "think time" between a VU's
  // requests. Open-model executors (spike/stress use
  // ramping-arrival-rate) already control request pacing externally via
  // their target rate — an extra fixed 1s per iteration there only
  // inflates how long each iteration occupies a VU, forcing higher
  // preAllocatedVUs/maxVUs for no realism benefit, so it's skipped there.
  if (testType !== 'spike' && testType !== 'stress') {
    sleep(1);
  }
}

export function handleSummary(data) {
  const filename = `${targetApp.id}_${testType}_report.html`;
  console.log(`Test finished! Report: ${filename}`);

  // Breakpoint reporting (point 2): print where the stress/breakpoint
  // run actually stopped, so the breaking point doesn't have to be
  // eyeballed out of raw metrics. Purely additive console output — does
  // not change what gets written to the HTML report below.
  if (testType === 'stress') {
    const reqRate = data.metrics.http_reqs && data.metrics.http_reqs.values.rate;
    const errRate = data.metrics.http_req_failed && data.metrics.http_req_failed.values.rate;
    const peakVUs = data.metrics.vus_max && data.metrics.vus_max.values.value;
    console.log(
      `BREAKPOINT: system started failing at ~${reqRate ? reqRate.toFixed(1) : 'N/A'} req/s ` +
      `(~${peakVUs != null ? peakVUs : 'N/A'} VUs allocated), ` +
      `error rate at stop: ${errRate != null ? (errRate * 100).toFixed(1) : 'N/A'}%`
    );
  }

  return { [filename]: htmlReport(data) };
}