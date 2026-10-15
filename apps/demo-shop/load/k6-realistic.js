import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.TARGET_URL || 'http://demo-shop.demo.svc.cluster.local';

// Load profile is env-driven so a VU ladder needs no file edits:
//   VUS=10 ./scripts/run-load.sh
//   VUS=30 HOLD=3m ./scripts/run-load.sh
const VUS = Number(__ENV.VUS || 20);
const RAMP = __ENV.RAMP || '1m';
const HOLD = __ENV.HOLD || '2m';

export const options = {
  stages: [
    { duration: RAMP, target: VUS },
    { duration: HOLD, target: VUS },
    { duration: '1m', target: 0 },
  ],
};

export default function () {
  const uid = `u${__VU}`;
  let r = http.get(`${BASE}/products`, { tags: { flow: 'browse' } });
  check(r, { 'products 200': (x) => x.status === 200 });
  r = http.get(`${BASE}/products/${1 + Math.floor(Math.random() * 3)}`, { tags: { flow: 'browse' } });
  check(r, { 'product 200': (x) => x.status === 200 });
  r = http.post(`${BASE}/cart`, JSON.stringify({ user_id: uid, product_id: 1, qty: 1 }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { flow: 'cart' },
  });
  check(r, { 'cart 200': (x) => x.status === 200 });
  sleep(1);
  r = http.post(`${BASE}/checkout/${uid}`, null, { tags: { flow: 'checkout' } });
  check(r, { 'checkout 200': (x) => x.status === 200 });
  sleep(2);
}
