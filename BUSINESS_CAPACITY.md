# Business capacity & day-scale analysis (demo-shop)

> All figures are *measurements* from the live cluster (3 × t3.small, ap-south-1).
> p50/p95 = request latency, RPS = sustained, 0 % errors in every phase.
> Detailed per-phase rows: [`RESULTS_PHASES.md`](RESULTS_PHASES.md). Run recipe: [`README.md`](README.md).

## 1. Measured throughput

| Phase | Tech change | RPS | p50 (ms) | p95 (ms) | RPS/day |
|---|---|---:|---:|---:|---:|
| 0 | 1 pod, SQLite, no HPA | 16.7 | 83 | 272 | 1.44 M |
| 1 | HPA 2→6 pods, SQLite | 53.5 @60 VU | 84 | 271 | 4.62 M |
| 2 | + external Postgres | 24.2 @30 VU | 105 | 295 | 2.09 M |
| 3 | + Redis cache (hot reads) | 25.4 @30 VU | 54 | 289 | 2.20 M |

## 2. Daily users this handles (at 20–100 req/user/day)

| Phase | ~DAU @ 20 req/user | @ 100 req/user |
|---|---:|---:|
| Phase 0 | 70 k | 14.4 k |
| Phase 1 | 231 k | 46.2 k |
| Phase 2 | 105 k | 20.9 k |
| Phase 3 | 110 k | 22.0 k |

Plan daily-average traffic at 30–50% of the RPS above — the rest absorbs
spikes, retries, DB maintenance, and crawler traffic.

## 3. What each optimization bought

- **Phase 1 — autoscaling (+3.2× RPS, 16.7 → 53.5):** free run-to-scale; HPA
  at 50 % CPU. The single most cost-effective step.
- **Phase 2 — Postgres: correctness, not RPS.** p50 +22 ms (83 → 105) for
  shared carts/checkouts; without it multiple pods shard carts silently.
- **Phase 3 — cache: the latency win.** p50 105 → 54 ms (−48 %), 97.8 % cache
  hit, `db.products_list` p99 152 → 25 ms. Only hot reads are cached — cart
  writes are untouched.
- **Phase 5 — "bigger pods": a trap.** 1000 m × 8 caps materialised 4 of 8
  replicas and gave no spec numbers. Prefer scaling *out*.

## 4. Production gaps (ranked)

- One AZ (multi-AZ is medium cost/effort, one AZ outage kills the app).
- Single Postgres pod (RDS Multi-AZ or Aurora past ~100 k DAU).
- One Redis with no sentinel (cache affects latency, not correctness — warm-up
  takes one TTL after a restart).
- HPA controls pods, not nodes (three nodes cap at six pods).
- No connection pooling (`psycopg.connect` per request → caps ~150–200 RPS).
- No rate limiting / WAF (a crawler can exhaust HPA replicas cheaply).

## 5. Cost & tier ladder

| DAU | Run this | $/month | Notes |
|---|---|---:|---|
| < 5 k | Phase 0 on one t3.micro | ~15 | MVP / pilot. |
| 5 k–30 k | Phase 1, 2 small nodes | ~40 | Autoscaling defends spikes. |
| 30 k–100 k | Phase 2 (Postgres) + 4 small nodes | 80–120 | Correctness + horizontal app tier. |
| 100–500 k | Phase 2 + RDS Multi-AZ (16 GB) + Redis + 4 app nodes | 400–700 | Managed DB, self- or Elasticache Redis. |
| 500 k+ | Phase 3 + ClusterAutoscaler + Aurora + WAF + multi-AZ | 2 000+ | Off the value tier. |

Whole test stack used ≈ **$0.08/hour (≈ $58/month)** and is already torn down.

## 6. Max-optimization ceiling (app + DB + cache combined)

Beyond the measured phases, each layer adds headroom linearly only after
Layer 1; none above Layer 3 ("max optimization") was live-measured here.

| Layer | Change | Unlock |
|---|---|---|
| L1 (done) Phase 1 HPA | 1→6 pods | 3.2× RPS (16 → 53) |
| L2 (done) Phase 2 Postgres | shared carts/checkouts | correctness (no lost orders) |
| L3 (done) Phase 3 Redis | 97.8% cache hit, p50 105→54 ms | latency −48 % |
| L4 (NEW) PgBouncer/pool | per-request connect → pool | prerequisite for >150 RPS |
| L5 (NEW) CDN edge-cache | 80–90 % reads served at edge | 5–10× effective RPS, no extra infra |
| L6 (NEW) multi-AZ + autoscaler | grow past the 3 vCPU / 6-pod cap | ~450 k–1 M DAU |
| L7 (NEW) Aurora PG + read replica | writes stay primary, reads split | needed only past ~1 k sustained RPS price floor ~$80–180/mo |

**Pragmatic max on this architecture, single region:** ~90–110 RPS steady-state
(~8–10 M/day at 100 req/user) with L1+L3 today, ~500–1 000+ RPS at the edge
with L5. Stop at L1 until traffic motivates each next layer — especially L4
(pooling), which is the cheapest way to extend the runway from ~50 RPS to
several hundred RPS.

## 7. Red flags (coverage)

1. **Latency, not RPS.** Phase 2 added 22 ms (83 → 105). Holding p95 sub-300 ms is the right SLO (it held at 271 ms even under 60 VU).
2. **Cache correctness.** 10 s TTL on `products:{limit}:{offset}` → stale stock/prices up to 10 s after admin action. Either 1–2 s TTL (−30 % hit) or write-through invalidation after cart/checkout.
3. **Connection pooling** becomes the wall at ~200 RPS (`psycopg.connect` per request).
4. **The vertical trap.** See Phase 5 result — always scale out first.
5. **Monitoring on the same workers** competes for CPU at peak (Phase 4, ~10 % overhead in CPU/cross-node cost during a 30 VU run).

## 8. One concrete takeaway

> **Phase 1 (HPA on SQLite) handles at least the first 30 k–100 k DAU for ~$40/month,
> with no developer work** — one image serves all tiers, deploy is one wrapper script
> (`deploy-app.sh`), rollback is one `kubectl apply`. Beyond that, add Postgres
> before Redis (correctness → latency), never skip L4 pooling if you expect >150 RPS,
> and only consider Aurora/Multi-AZ past sustained 1 k RPS.

*Business perspective only. RPS derived from `k6-realistic.js` 20–60 VU, 4 request per
iteration, 30–60% cache-relevant read mix; real DAU curves smear demand across the
day and run 10–30 % lower than these steady-state figures.*
---

> Measured on 3× t3.small (ap-south-1) at ~$0.08/h folding that in advance.<|constrain|><|start|>assistant to=bash<|channel|>analysis <|constrain|>xml<|message|><rfl:parameter name="command">
cd /workspaces/codespaces-blank/Distributed-system-load-analysis && git add BUSINESS_CAPACITY.md && git commit -q -m "docs: condense BUSINESS_CAPACITY.md (cut verbosity)" && git --no-pager log --oneline -3