# End-to-end tracing (client -> app -> DB)

A single k6 request can be followed end-to-end: k6 emits a client span, the app
creates a server span, and every DB operation / work step becomes a child span.
Jaeger shows the waterfall and which pod/node served it.

## 1. Start the collector
```bash
kubectl -n demo apply -f monitoring/jaeger.yaml
kubectl -n demo port-forward svc/jaeger 16686:16686     # UI
```

## 2. Turn on tracing in the app (sends spans to Jaeger)
```bash
kubectl -n demo set env deploy/demo-shop \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger.demo.svc.cluster.local:4318
```

## 3. Run k6 with client-side trace export
Current k6 (v2.x) has a built-in traces output:
```bash
k6 run \
  --traces-output=otel=http://jaeger.demo.svc.cluster.local:4318,proto=http \
  apps/demo-shop/load/k6-realistic.js
```
Equivalent via env var: `K6_TRACES_OUTPUT=otel=http://jaeger...:4318,proto=http`.

If k6 runs as an in-cluster Job, just use the wrapper:
```bash
TRACE=true ./scripts/run-load.sh      # rewrites the Job with --traces-output and
                                      # enables app tracing, then cleans up after
```

## 4. What you see in Jaeger (service `demo-shop`)
- `k6` client span (duration = full client-observed latency)
  - `GET /products` / `POST /cart` / `POST /checkout`
    - `db.products_list` (db.system, db.operation, db.duration_ms)
    - `work.*` spans (simulated work)
- Each app span carries `k8s.pod` (which node/pod served it), `request.id`,
  `http.status`.

k6's built-in `--traces-output` sends k6's **own** spans to Jaeger but does not
attach a `traceparent` to the HTTP requests, so by default the k6 span and the
app span appear as **two separate traces**. To join them into one trace, add
context propagation in the script (the `http-instrumentation-tempo` jslib, or
the experimental `k6/experimental/tracing` client with `propagator: "w3c"`).
The app-side waterfall (route → `db.*` → `work.*`) is complete either way,
which is what the phase analysis relies on.

## 5. Correlate a trace id with logs
Logs are JSON with `rid` and the pod name; grep the serving pod's log for the
matching request to see the same event from the application side.

## 6. Turn tracing off when not needed (zero overhead)
```bash
kubectl -n demo set env deploy/demo-shop OTEL_EXPORTER_OTLP_ENDPOINT-
```

## Note
Prometheus metrics remain available regardless of tracing, so capacity numbers
(RPS/p95/DB-time/cache ratio) never depend on the collector being up.
Also: trace export has a cost on the **generator** at high VU counts — keep it on
for deep dives, off for headline throughput runs.
