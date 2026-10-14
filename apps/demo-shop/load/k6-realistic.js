import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.TARGET_URL || 'http://demo-shop.demo.svc.cluster.local';
export const options = {
  stages: [
    { duration: '1m', target: 20 },
    { duration: '2m', target: 20 },
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
