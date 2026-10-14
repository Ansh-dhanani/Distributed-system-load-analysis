# Phased results & analysis (demo-shop)

Every phase changes **one thing only**. Infra, HPA settings, k6 script and VU level
stay identical so the deltas are attributable.

Run any phase with:
```bash
./scripts/run-load.sh            # defaults to apps/demo-shop/load/k6-realistic.js
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
| 0 baseline | | | | | | | | | | |
| 1 HPA | | | | | | | | | | |
| 2 Postgres | | | | | | | | | | |
| 3 +Redis | | | | | | | | | | |
| 4 +monitoring | | | | | | | | | | |
| 5 1000m×8 | | | | | | | | | | |

## Deep-dive per phase (tracing)
```bash
TRACE=true ./scripts/run-load.sh
kubectl -n demo port-forward svc/jaeger 16686:16686
```
In Jaeger, pick the slowest trace and note the breakdown:
`k6.client` → route span (with `k8s.pod`) → `db.*` spans → `work.*`.
This is what justifies each phase's claim: e.g. Phase 3's win shows up as
`db.products_list` shrinking to near zero, not as a mysterious RPS bump.
