// k6 load profile: staged ramp to a target VU level.
// Set the level with env vars — no file edits needed:
//   VUS=30 HOLD=2m ./scripts/run-load.sh load-test/k6-capacity.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const VUS = Number(__ENV.VUS || 30);
const RAMP = __ENV.RAMP || '30s';
const HOLD = __ENV.HOLD || '2m';

export const options = {
  stages: [
    { duration: RAMP, target: VUS },
    { duration: HOLD, target: VUS },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    'http_req_duration': ['p(95)<5000', 'p(99)<5000'],
  },
};

export function handleSummary(data) {
  const d = data.metrics.http_req_duration.values;
  const rps = data.metrics.http_reqs.values.rate;
  const fail = data.metrics.http_req_failed.values.rate;
  const p50 = (d['med'] !== undefined ? d['med'] : d['p(50)']) !== undefined
    ? (d['med'] !== undefined ? d['med'] : d['p(50)']).toFixed(0)
    : 'n/a';
  const p90 = d['p(90)'] !== undefined ? d['p(90)'].toFixed(0) : 'n/a';
  const p95 = d['p(95)'] !== undefined ? d['p(95)'].toFixed(0) : 'n/a';
  const p99 = d['p(99)'] !== undefined ? d['p(99)'].toFixed(0) : 'n/a';
  return {
    stdout:
      '\nSUMMARY ' +
      `p50=${p50} p90=${p90} p95=${p95} p99=${p99} ` +
      `RPS=${rps.toFixed(2)} ERR=${(fail * 100).toFixed(2)}%\n`,
  };
}

const TARGET = __ENV.TARGET_URL || 'http://php-apache.demo.svc.cluster.local';

export default function () {
  const res = http.get(TARGET);
  check(res, { 'status is 200': (r) => r.status === 200 });
  sleep(0.1);
}