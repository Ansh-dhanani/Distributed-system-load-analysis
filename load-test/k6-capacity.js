// k6 load profile: staged ramp to a target VU level.
// Usage (inside cluster, see ../README.md):
//   1. copy this file to the control plane as /tmp/k6cap.js with the
//      desired VUS baked in (edit the stages below), then:
//   2. kubectl -n demo create configmap k6-script --from-file=k6.js=/tmp/k6cap.js \
//        --dry-run=client -o yaml | kubectl apply -f -
//   3. kubectl -n demo delete job k6 --ignore-not-found --wait=true
//   4. kubectl apply -f k6-job.yaml
//   5. kubectl -n demo wait --for=condition=complete job/k6 --timeout=600s
//   6. kubectl -n demo logs job/k6
import http from 'k6/http';
import { check, sleep } from 'k6';

// Edit targets per run, e.g. 20 / 50 for baseline, 30 / 80 / 150 for HPA runs.
const RAMP_VU = 30;
const HOLD_VU = 30;

export const options = {
  stages: [
    { duration: '30s', target: RAMP_VU },
    { duration: '2m', target: HOLD_VU },
    { duration: '30s', target: 0 },
  ],
};

const TARGET = __ENV.TARGET_URL || 'http://php-apache.demo.svc.cluster.local';

export default function () {
  const res = http.get(TARGET);
  check(res, { 'status is 200': (r) => r.status === 200 });
  sleep(0.1);
}
