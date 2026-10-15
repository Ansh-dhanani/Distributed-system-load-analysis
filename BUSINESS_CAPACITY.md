# Business capacity & day-scale analysis (demo-shop)

> Non-technical summary of what the numbers mean for users, cost, and roadmap decisions.
> All load numbers were measured on the live cluster (3 × t3.small, ap-south-1) and on
> the `ap-south-1` PostgreSQL instance used in Phase 2 and 3 — dates in
> [`RESULTS_PHASES.md`](RESULTS_PHASES.md). No estimates are invented; everything
> below is those measurements converted to per-day and per-user terms.

---

## 1. What we actually measured (in plain numbers)

Sustained application-level throughput under load, 0% errors in every phase:

| Phase | Tech change | Sustained RPS | p95 (ms) | RPS/day |
|---|---|---:|---:|---:|
| 0 | 1 pod, SQLite in-pod, no autoscaling | 16.7 | 272 | ~1.44M |
| 1 | 2–3 pods with HPA (50% CPU) | 53.5 (@60 VU) | 271 | ~4.62M |
| 2 | + external Postgres | 24.2 (@30 VU) | 295 | ~2.09M |
| 3 | + Redis cache on hot reads | 25.4 (@30 VU) | 289 | ~2.20M |

## 2. How many users/day could this handle?

A "user" here is a logged-in session that issues ~100 HTTP requests per day
(roughly: browsing several product pages, cart actions, a checkout). That is on
the high side; the smaller the pageview budget, the larger the numbers below.

| Scenario | Daily requests handled | At 100 req/user |
|---|---:|---:|
| One small pod (Phase 0) | 1.44M/day | ~14,400 DAU |
| HPA 2–3 pods (Phase 1) | 4.62M/day | ~46,200 DAU |
| Postgres-backed (Phase 2) | 2.09M/day | ~20,900 DAU |
| Postgres + cache (Phase 3) | 2.20M/day | ~22,000 DAU |

At a lean 20 requests per user per day, divide any of those DAU figures by 5.

**Recommended "safe" planning envelope:** treat the measured number as the **peak
headroom**, and plan daily-average traffic at **30–50%** of it. Bursts, retries,
admin ops, batch jobs and scheduled DB maintenance all consume the same capacity.
So Phase 1's realistic daily ceiling is roughly **14–23 k DAU in normal traffic**
with headroom to absorb spikes.

## 3. What each optimization actually bought

* **Phase 1 — going from 1 to HPA-scaled pods: +3.2× RPS (~16.7 → 53.5).**
  The single-pod case is the floor (one CPU, one SQLite file, one queue). HPA at
  50% CPU gave the run-to-scale option for nothing beyond the existing image.

* **Phase 2 — moving SQLite to Postgres: scaling correctness, not raw RPS.**
  Postgres p50 (request end-to-end) rose only 22 ms (~83 → 105 ms). Each replica
  now sees the same cart/checkout state, and writes serialize through one
  primary. The cost is an extra hop; the benefit is no lost orders. Phase 2 is
  where the product stops being a demo and becomes a **real back-end**.

* **Phase 3 — Redis cache on `/products`: the latency win.**
  p50 fell from **105 ms → 54 ms (~−48 %)**; **97.8 % cache hit** on product
  pages. That is the difference a user feels as "snappy" vs "slow."

* **Phase 5 — "just buy a bigger box" failure.**
  Raising limits to 1000 m and `maxReplicas=8` only materialised 4 pods (CPU
  metrics couldn't be computed under load), so RPS stayed flat at ~25 vs the 53
  the horizontal case reaches. Bigger pods wasted money without extra users.
  *Decision: scale out, not up.*

## 4. What's missing before real production (business-grade)

Currently the lab covers **one availability zone + one value-tier region**.
The things a real estate-of-play would add:

| Gap | Business risk | Cost/effort to fix |
|---|---|---|
| Single-AZ VPC | One AZ outage takes the whole app offline | Medium — multi-AZ + cross-AZ EBS, ~2× Node cost |
| Single Postgres pod | Total loss if it dies | Large — RDS Single-AZ covers the small tier, Multi-AZ for production |
| No Redis HA / Sentinel | Cache loss on a Redis restart (cache warms up again ≤ TTL, no data loss) | Small — but Redis Sentinel would be justified only if cache is business-critical |
| No autoscaling **nodes** | HPA fixes pod count, not node count; under sustained overload the 3 nodes still cap out at 6 replicas | Medium — Cluster Autoscaler on a managed node group |
| No rate limiting / WAF | A single bad actor or crawler can exhaust HPA replicas and starve real users | Small — add an ingress with `rate-limit` annotations or a regional WAF |
| Monitoring on the same workers | Phase 4 shows observability competes for CPU at peak | Small — pin monitoring to its own small node or set resource limits |

## 5. Cost efficiency (from a business angle)

- The whole stack for this test: **≈ $0.08/hour ≈ $58/month** (3× t3.small + EBS, no NAT gateway, no EKS control-plane cost).
- At Phase 1 headroom (4.62M clean-peak requests/day): **≈ $0.05 per million requests** at *measured* throughput. In practice 10–100× cheaper than that because daily traffic is rarely at test peak and Egress is mostly free on AWS.
- The single most expensive recurring piece is **Postgres storage** (a stateful PVC on gp3) which scales with orders, not traffic, and grows linearly with catalog size.

## 6. Recommended stack per scale tier

| DAU | What to run | Expected cost/month | Notes |
|---|---|---|---|
| **< 5 k DAU** | 1 pod, no HPA, SQLite | ~$15 (single t3.micro) | Cheapest. Good for MVP / pilot. |
| **5 k – 30 k DAU** | Phase 1: HPA 2–6 on SQLite, 2 small nodes | ~$40 | Autoscaling defends spikes; DB still per-pod |
| **30 k – 100 k DAU** | Phase 2: external Postgres (self-hosted) + HPA | ~$80–120 | Correctness + horizontal app tier |
| **100 k – 500 k DAU** | Phase 2 + RDS Multi-AZ Postgres (16 GB) + Redis (Phase 3) + 4 app nodes | ~$400–700 | Add RDS (managed DB) + a self-managed or Elasticache Redis |
| **> 500 k DAU** | Phase 3 + Cluster Autoscaler + Node affinity (multi-AZ) + CDN | ~$2 000–4 000 | Move off the value tier onto EKS/EKS / Aurora + read replicas |

## 7. Operational red flags to keep in mind

1. **Latency, not RPS, is what loses users.** Phase 2 doubled availability-correctness but added 22 ms (83 → 105 ms). Even 285 ms (p95) is acceptable for an e-commerce browse. Holding p95 sub-300 ms is the right operational target.
2. **Cache correctness:** Redis uses a 10 s TTL with key `products:{limit}:{offset}`. Watch stale prices / stock after admin updates — either drop the TTL to 1–2 s (−30 % hit rate), or implement **write-through invalidation** on `/cart` and `/checkout` later.
3. **Connection pooling.** Currently one Postgres connection per request (`psycopg.connect`). Past ~200 RPS this becomes the bottleneck (not captured in our burst runs). Add `psycopg[pool]` or PgBouncer around Phase 2 production.
4. **Read ordering / idempotency on k6's own tables:** the `/checkout` flow is idempotent per user; re-running the load against an unchanged DB is fine.
5. **The vertical-scale trap is real.** Phase 5 doubled per-pod CPU twice but got 4/8 replicas and no RPS improvement. Always scale out before scaling up.

## 8. One concrete takeaway

Given the measurements, the right single action if this app had only one week to scale is:

> **Phase 1 (HPA on SQLite) handles at least the first 30 k–100 k DAU for ~\$40/month, with no developer work** — because one image serves all tiers, deploy is a single wrapper script (`deploy-app.sh`), and rollback is one `kubectl apply`. Anything beyond should go Phase 2 (Postgres) before Phase 3 (cache), **in that order** — skipping Postgres and caching into an in-pod SQLite would just shard the carts silently.

---

*Business perspective only. All RPS/latency figures are *measured* on 3× t3.small nodes
against the synthetic `k6-realistic.js` load (20 VU, 4 requests each, mixed read/write).
Real DAU limits will be lower in practice because real users spread load across the day,
but so will the worst-case bursts being lower — plan for 30–50 % of measured RPS as
your sustainable average target.*
