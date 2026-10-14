# Observability

Signals available per run:

| Signal | Where | Enabled by |
|---|---|---|
| Health/readiness | `GET /health` (reports active db + cache) | always |
| Request metrics | `GET /metrics` (Prometheus text) | always |
| Request logs | stdout JSON (`rid`, `path`, `status`, `latency_ms`, `pod`) | always |
| DB query timing | `shop_db_query_seconds` histogram per op | always |
| Cache hit ratio | `shop_cache_events_total{result}` | REDIS_URL set |
| Distributed traces | OTLP → Jaeger | `OTEL_EXPORTER_OTLP_ENDPOINT` set |
| App metrics | Prometheus scrape of pods labelled `app=demo-shop` | monitoring playbook |

## Deploy monitoring (optional, lightweight)
```bash
cd infra/ansible && ansible-playbook -i inventory.yml site.yml --tags monitoring
```

## Access UIs
```bash
kubectl -n demo port-forward svc/prometheus 9090:9090
kubectl -n demo port-forward svc/grafana 3000:3000     # admin/admin
kubectl -n demo port-forward svc/jaeger 16686:16686
```

## Enable tracing for one run
```bash
kubectl -n demo set env deploy/demo-shop \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger.demo.svc.cluster.local:4318
```
See `TRACING.md` for client-side k6 spans (`--traces-output=otel=...`).
Disable again with `kubectl -n demo set env deploy/demo-shop OTEL_EXPORTER_OTLP_ENDPOINT-`

## Useful queries (Prometheus)
```promql
sum by (pod) (rate(shop_requests_total[1m]))                        # RPS per pod/node
histogram_quantile(0.95, sum by (le) (rate(shop_request_latency_seconds_bucket[5m])))
histogram_quantile(0.99, sum by (le,op) (rate(shop_db_query_seconds_bucket[5m])))
sum(rate(shop_cache_events_total{result="hit"}[5m]))               # cache hits
sum(rate(shop_requests_total{status=~"5.."}[1m]))                   # error rate
```

## Remove monitoring
```bash
kubectl -n demo delete deploy prometheus grafana jaeger
kubectl -n demo delete svc prometheus grafana jaeger
kubectl -n demo delete configmap prometheus-config grafana-datasource grafana-dashboards-provider grafana-dashboard
kubectl -n demo delete sa prometheus
kubectl delete clusterrole demo-prometheus
kubectl delete clusterrolebinding demo-prometheus
```
