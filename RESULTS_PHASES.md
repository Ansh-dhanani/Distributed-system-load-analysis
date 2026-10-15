# Phased results & analysis (demo-shop)

> **Updated with a live AWS run** (ap-south-1, 3× t3.small, containerd 2.2.1,
> Kubernetes v1.36.5, AMI ami-065d2b03fb493085a). Cells report the headline `VUS`
> level actually driven; k6 VU ladder defined by env (`VUS=... ./scripts/run-load.sh`).

Every phase changes **one thing only**. Infra, HPA settings, k6 script and VU level
stay identical so the deltas are attributable.

Run any phase with:
```bash
./scripts/run-load.sh            # defaults to apps/demo-shop/load/k6-realistic.js
# VU level is env-driven (no file edits):  VUS=10 ./scripts/run-load.sh
```

Record for each phase: RPS, p50/p95/p99, error %, replicas, CPU/mem, **p99 DB
query time**, **cache hit ratio**, plus a Jaeger trace ID of a slow request.

---

## Phase 0 — Baseline: 1 replica, no autoscaling
| Item | Value |
|---|---|
| Apply | `kubectl apply -f apps/demo-shop/k8s/deployment.yaml` then `kubectl -n demo scale deploy/demo-shop --replicas=1` and delete HPA (`kubectl -n demo delete hpa demo-shop`) |
| VUs | 5 / 10 / 20 |
| Why this is the floor | single pod, CPU-bound, no headroom; latency grows linearly with VUs |

Expect: RPS flat as VUs rise, p95 climbs, first errors ~20 VUs.
**Reason:** the pod is the ceiling; extra concurrency only queues in the server.

---

## Phase 1 — Kubernetes scaling: HPA 1→6 @ 50% CPU
| Item | Value |
|---|---|
| Apply | `kubectl apply -f apps/demo-shop/k8s/deployment.yaml` (HPA included, min 2) |
| VUs | 10 / 30 / 60 |
| Measured baseline for reference | ~12.5 RPS @30 VU, p95 2.3s, 0.4% errors (hpa-example study) |

**Why it helps:** each pod is capped at 500m, so 6 pods give ~6× the CPU ceiling
without exceeding the ~3600m allocatable on 2× t3.small.
**Watch:** HPA scale-up lag (metrics every 15s + 60s stabilization) is the main
source of p95 outliers early in the run.

---

## Phase 2 — External DB: SQLite → PostgreSQL
| Item | Value |
|---|---|
| Apply | `kubectl apply -f apps/demo-shop/phases/phase2-postgres.yaml` |
| VUs | same as Phase 1 |
| Record extra | `shop_db_query_seconds` p99 per op, Postgres CPU/locks |

**Why:** SQLite is per-pod + single-writer; with 2–6 replicas each pod sees a
*different* database, so carts/checkouts are inconsistent and writes serialize.
**Cost/tradeoff:** network hop (~0.2–1ms) + Postgres competes for the same node CPU.
**Expected:** write-heavy endpoints improve correctness and p99 DB time; raw RPS may
dip slightly versus in-pod SQLite until connections are pooled.

---

## Phase 3 — Cache layer: Redis in front of hot reads
| Item | Value |
|---|---|
| Apply | `kubectl apply -f apps/demo-shop/phases/phase2-postgres.yaml` then `-f apps/demo-shop/phases/phase3-cache.yaml` |
| Record extra | `shop_cache_events_total{result}` hit ratio, p95 on `/products` |

**Why:** `/products` was the DB hotspot; a 10s TTL LRU cache removes most reads.
**Tradeoff:** stale reads up to TTL, extra hop, cache warm-up on restart.
**Expected:** read RPS and p95 improve most; `/products/{id}` and cart writes unchanged.

---

## Phase 4 — Observe the cost of observability
| Item | Value |
|---|---|
| Apply | `ansible-playbook -i inventory.yml site.yml --tags monitoring` |
| VUs | same as Phase 3 |
| Record extra | Prometheus CPU/mem on the node it lands on |

**Why:** metrics/logging/tracing are not free. Confirms monitoring should not share
a worker at peak (or should be tagged out during headline runs).

---

## Phase 5 — Counter-example: vertical scaling
| Item | Value |
|---|---|
| Apply | `kubectl -n demo set env deploy/demo-shop ...`; or bump `limits.cpu` to 1000m and `maxReplicas` to 8 |
| VUs | 30 |

**Why it regresses (measured):** 8 × 1000m = 8000m burst demand vs ~3600m allocatable
+ T3 CPU-credit burn → 12.5 → 8.7 RPS, errors 0.4% → 4.4%.
**Takeaway:** grow node capacity before pod limits. Keep this phase in the deck — the
failure is the lesson.

---

## Results table (fill in per run)

| Phase | VUs | RPS | p50 | p95 | p99 | Errors % | Replicas | p99 DB (ms) | Cache hit % | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 baseline (1 pod, no HPA, SQLite) | 5/10/20 | 16.69 @20VU | 83 | 272 | 468 | 0.00 | 1 | n/a (SQLite) | n/a | RPS scales linearly 4.37→16.69; p50→p95 flat-ish; no pod saturation observed only because single pod |
| 1 HPA 2→6 (+SQLite) | 10/30/60 | 53.49 @60VU | 84 | 271 | 463 | 0.00 | 2→3 | 463 | n/a | HPA scaled 2→3 at 60 VU; p95 barely moves (271 vs 272) under 3 pods — ceiling not CPU yet |
| 2 External DB Postgres | 20 (headline) | 16.23 | 105 | 289 | 478 | 0.00 | 5 | products_list 152 / checkout 148 | n/a | Selection push over network adds ~20ms p50; HPA now scales (5 pods at 20 VU — Postgres DB time lifted pod CPU threshold) |
| 3 + Redis cache | 20 (headline) | 15.85 | 54 | 284 | 467 | 0.00 | 4 | product_get 50 / checkout 97 (list 25) | 97.8 | Cache makes p50 −48%, RPS ≈ flat; hit ratio 978/1000; p99 DB for /products collapsed; cart/checkout unchanged (no cache) |
| 4 +monitoring | — | n/a | — | — | — | — | pods +prom,grafana,jaeger | — | — | Install succeeded (jaeger service port-names fixed). Overhead not isolated — monitor CPU is on the same workers; recommend tagging it out for headline runs |
| 5 vertical 1000m×8 | 30 | 25.44 | 54 | 287 | n/a | 0.00 | 4/8 | — | — | Only 4 of 8 replicas materialized (CPU 10%/50% target unable to compute under load-cap), so the documented T3 regression did not reproduce in this run |
"

## DB benchmark sweep (`scripts/db-bench.sh`, libpq-concurrent)

Captured during Phase 2. `SCALES × CLIENTS` (rows scale factor × concurrent
clients), 30 s each, all runs 0 % failed transactions.

| scale (rows) | 10 clients (avg ms) | 50 clients (avg ms) | 100 clients (avg ms) |
|---|---|---|---|
| 1000  | 17.1  | 92.8  | 204.8 |
| 10000 | 28.1  | 149.1 | 323.8 |
| 100000 | 131.2 | 679.2 | 1399.4 |

Read: latency is client-bound at low data sizes, then data-size bound at 100 k
rows (one ORDER BY + LIMIT still scans up to the page under the existing index).

## Deep-dive per phase (tracing)
```bash
TRACE=true ./scripts/run-load.sh
kubectl -n demo port-forward svc/jaeger 16686:16686
```
In Jaeger, pick the slowest trace and note the breakdown:
`k6.client` → route span (with `k8s.pod`) → `db.*` spans → `work.*`.
This is what justifies each phase's claim: e.g. Phase 3's win shows up as
`db.products_list` shrinking to near zero, not as a mysterious RPS bump.

**Run note (this live run):** Jaeger received only `jaeger-all-in-one` as a service — app spans did not land despite TRACE=true (OTLP exporter wiring /
startup ordering). HTTP/DB timing comes from the `shop_request_latency_seconds` /
`shop_db_query_seconds` Prometheus histograms, so the numerical claims stand;
the trace ID is intentionally blank pending that investigation. Monitoring
was deployed for p99 capture; Phase 4's "cost of observability" delta is left as a TODO here because monitoring was on during all headline runs.
