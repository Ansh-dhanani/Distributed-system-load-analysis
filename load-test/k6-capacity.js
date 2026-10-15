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
};

const TARGET = __ENV.TARGET_URL || 'http://php-apache.demo.svc.cluster.local';

export default function () {
  const res = http.get(TARGET);
  check(res, { 'status is 200': (r) => r.status === 200 });
  sleep(0.1);
}
