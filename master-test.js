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
    // PRODUCTION RECOMMENDATION (original/full-scale):
    // stages: [
    //   { duration: '30s', target: 40 },
    //   { duration: '20s', target: 500 },   // sudden rise
    //   { duration: '1m',  target: 500 },
    //   { duration: '20s', target: 40 },    // sudden drop
    //   { duration: '1m',  target: 20 },    // recovery
    //   { duration: '30s', target: 0 },
    // ],
    executor: 'ramping-vus', startVUs: 0,
    stages: [
      { duration: '20s', target: 40 },
      { duration: '15s', target: 500 },   // sudden rise
      { duration: '40s', target: 500 },
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
    // PRODUCTION RECOMMENDATION (original/full-scale):
    // stages: [
    //   { duration: '2m', target: 100 },
    //   { duration: '2m', target: 200 },
    //   { duration: '2m', target: 400 },
    //   { duration: '2m', target: 600 },
    //   { duration: '2m', target: 0 },
    // ],
    executor: 'ramping-vus', startVUs: 0,
    stages: [
      { duration: '1m', target: 100 },
      { duration: '1m', target: 200 },
      { duration: '1m', target: 400 },
      { duration: '1m', target: 600 },
      { duration: '1m', target: 0 },
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
  load:        { http_req_duration: ['p(95)<2000'], http_req_failed: ['rate<0.01'] },
  stress:      { http_req_failed: ['rate<0.15'] },
  soak:        { http_req_duration: ['p(95)<2500'], http_req_failed: ['rate<0.02'] },
  spike:       { http_req_failed: ['rate<0.20'] },
  scalability: { http_req_duration: ['p(95)<2000'], http_req_failed: ['rate<0.02'] },
};

// ---- RUN ONLY THE SELECTED TEST TYPE ----
export const options = {
  scenarios: { [testType]: scenarioProfiles[testType] },
  thresholds: thresholdsByType[testType],
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

  check(res, {
    [`${targetApp.name} - successful (2xx)`]: (r) => r.status >= 200 && r.status < 300,
  });

  sleep(1);
}

export function handleSummary(data) {
  const filename = `${targetApp.id}_${testType}_report.html`;
  console.log(`Test finished! Report: ${filename}`);
  return { [filename]: htmlReport(data) };
}