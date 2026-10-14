# DB Evolution Plan (demo-shop)

Goal: show realistic DB capacity ladder behind the same Kubernetes scaling setup.

## Phase 1 — SQLite on pod (current)
- Config: emptyDir SQLite, one database **per replica** (HPA keeps ≥2 running).
- Pros: zero infra, fast for small data, simple.
- Cons: single-writer bottleneck, no replication, pod data loss on eviction, and
  because each pod has its *own* SQLite file, carts written on pod A are invisible
  to pod B (the inconsistency Phase 2 fixes).
- Expected: fine for 20–50 VUs and <= 100k rows; lock contention under writes.

## Phase 2 — Managed/external PostgreSQL single primary
- Move DB to Postgres (RDS or self-hosted), app connects via env.
- Add connection pooling, indexes on hot columns, read/write separation optional.
- Pros: durability, better concurrency, standard observability.
- Tradeoff: network hop + cost; writes still single node.

## Phase 3 — Read replicas + caching
- Add Redis (or in-memory) cache for hot reads; Postgres read replicas.
- App routes reads to replicas, writes to primary.
- Pros: read scaling, tail latency down.
- Tradeoff: replication lag/stale reads, cache invalidation complexity.

## Phase 4 — Sharding (only if needed)
- Shard by tenant/user_id or product range; routing layer (Vitess/Citus/custom).
- Pros: write throughput scale.
- Tradeoff: complex transactions, resharding cost, operational burden.

## Measurement discipline
- Keep app/HPA constant across phases; change only data layer.
- Run same k6 flow at 20/50/80 VUs and record RPS/p95/errors + DB metrics (connections, replication lag, cache hit rate).
- Assumption: network within cluster; monitoring stays on dedicated node or off hot workers.
