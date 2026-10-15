import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.TARGET_URL || 'http://demo-shop.demo.svc.cluster.local';

// Load profile is env-driven so a VU ladder needs no file edits:
//   VUS=10 HOLD=2m ./scripts/run-load.sh
const VUS = Number(__ENV.VUS || 20);
const RAMP = __ENV.RAMP || '1m';
const HOLD = __ENV.HOLD || '2m';

export const options = {
  stages: [
    { duration: RAMP, target: VUS },
    { duration: HOLD, target: VUS },
    { duration: '1m', target: 0 },
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

export default function () {
  const uid = `u${__VU}`;
  // resolve a valid id dynamically (table ids may not start at 1 after app/bench runs)
  let r = http.get(`${BASE}/products?limit=1`, { tags: { flow: 'browse' } });
  check(r, { 'products 200': (x) => x.status === 200 });
  let pid = 1;
  try { pid = r.json('items.0.id') || 1; } catch (e) {}
  r = http.get(`${BASE}/products/${pid}`, { tags: { flow: 'browse' } });
  check(r, { 'product 200': (x) => x.status === 200 });
  r = http.post(`${BASE}/cart`, JSON.stringify({ user_id: uid, product_id: pid, qty: 1 }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { flow: 'cart' },
  });
  check(r, { 'cart 200': (x) => x.status === 200 });
  sleep(1);
  r = http.post(`${BASE}/checkout/${uid}`, null, { tags: { flow: 'checkout' } });
  check(r, { 'checkout 200': (x) => x.status === 200 });
  sleep(2);
}