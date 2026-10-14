# Capacity journey (narrative)

> Canonical, runnable version with commands and the results table: `RESULTS_PHASES.md`.
> This page is the short story.

Goal: show, on one small cluster (1 control-plane + 2× t3.small, unchanged
throughout), how a service goes from "a handful of users" to "hundreds" through
single-variable changes — and be able to prove **where** the time went.

Legend: **measured** = from the original `hpa-example` study (`results/results.md`);
**to measure** = framework in place, fill from your run.

## Phase 0 — One pod, no scaling (measured)
~4 RPS, p95 5–15s, 26–33% errors, errors from ~20 users.
**Why:** the pod sits pinned at its CPU limit; extra users only queue.

## Phase 1 — Horizontal scaling + right-sized limits (measured)
HPA 1→6 @ 50% CPU, `500m` limits, PDB. ~12.5 RPS, p95 ~2.3s, <1% errors, ~70–100 users.
**Why:** six pods ≈ six times the CPU budget without exceeding the node's ~3600m.
**Failed alternative (measured):** 1000m × 8 regressed to 8.7 RPS / 4.4% errors — node
contention + T3 credit burn. Grow nodes before pod limits.

## Phase 2 — Fix the data tier (to measure)
SQLite → PostgreSQL; pooled connections; indexes; pagination.
**Why:** SQLite is per-pod and single-writer; at N replicas each pod has a *different*
database, so carts/checkouts are inconsistent and writes serialize.
**Tradeoff:** network hop and DB CPU contention can cost raw RPS before pooling.

## Phase 3 — Cache hot reads (to measure)
Redis in front of `/products` (10s TTL, LRU).
**Why:** `/products` is the read hotspot; the cache removes most of its DB load.
**Tradeoff:** staleness up to TTL; cache warm-up after restarts.

## Phase 4 — The cost of observability (to measure)
Prometheus + Grafana (+ optional Jaeger).
**Why:** proves monitoring shouldn't share a worker at peak — quantify it rather
than assume it.

## Phase 5 — Beyond a single writer (to measure, only if needed)
Read replicas, then sharding (`DB_EVOLUTION.md`).
**Why:** reads scale with replicas; the single primary is the write ceiling.
**Tradeoff:** replication lag / stale reads; sharding adds cross-shard transaction
and resharding complexity.

## Reproduce
```bash
./scripts/run-load.sh              # app-level capacity, prints summary
TRACE=true ./scripts/run-load.sh   # + client→app→DB traces in Jaeger
./scripts/db-bench.sh              # DB-only scale sweep (rows × clients)
```
Compare phases with `shop_db_query_seconds` (DB time), `shop_cache_events_total`
(hit ratio) and Jaeger waterfalls — not just the RPS number.

## Guardrails that keep the ladder honest
- Same hardware, same k6 script, same VU levels for every phase.
- Change one thing per phase.
- Keep k6 CPU under ~15m so the runner is never the bottleneck.
- Trace the slowest request in each phase so each claim has a cause attached.
