# DB-only analysis (pgbench)

Isolates database performance from the app, so you can see how the DB behaves at
each **data size** and **concurrency** level, and correlate it with the app-level
metrics (`shop_db_query_seconds`).

## Run

```bash
kubectl apply -f apps/demo-shop/phases/phase2-postgres.yaml   # Postgres must be up
./scripts/db-bench.sh                                        # 1k/10k/100k rows x 10/50/100 clients
SCALES="1000 100000 1000000" CLIENTS="50 200" DURATION=120 ./scripts/db-bench.sh
```

Each iteration: applies schema → `TRUNCATE` + seeds `$ROWS` products → `ANALYZE`
→ runs `pgbench` with the app's hot-path mix (paginated list read, PK point read,
cart insert, cart read, cart delete).

Logs land in `/tmp/dbbench/pgbench_scale<rows>_clients<c>.log`.

## What to record per run

| Field | Where in pgbench output | Why it matters |
|---|---|---|
| `tps` | last line | transactions/sec = DB ceiling at that concurrency |
| `latency average` | summary | per-transaction cost (5 statements) |
| `number of failed transactions` | summary | correctness/pressure signal |
| `latency stddev` | percentile block | tail behaviour / queueing |
| Postgres CPU | `kubectl -n demo top pod -l app=postgres` | is DB CPU-bound or lock-bound? |

## How to read it

- **Rows ↑, clients constant** → latency grows roughly with log(rows) once the
  working set stops fitting in `shared_buffers`; expect a knee around when the
  table exceeds a few hundred MB (t3.small has only 2 GB RAM).
- **Clients ↑, rows constant** → TPS rises then flattens (lock/IO/CPU bound);
  latency grows roughly linearly once saturated. The first sign is **stddev
  growing faster than the mean**.
- **Failed transactions > 0** → contention on the same rows or resource limits;
  add retries/pooling before adding hardware.
- Compare `shop_db_query_seconds` p99 (app) against pgbench latency: a gap means
  the cost is in the app/network, not the DB.

## Scaling checklist

| Rows | Sweet-spot clients | Typical tps (2× t3.small, 800m limit) | Notes |
|---|---|---|---|
| 1,000 | fill | measure | everything in cache |
| 10,000 | fill | measure | still cache-resident |
| 100,000 | measure knee | measure | first IO/latency growth |
| 1,000,000 | measure knee | measure | expect big latency jump |

(Fill the last column from your actual runs; these are the rows to report.)

## What to change after you find the knee
1. **Too slow at high concurrency** → add a pooler (PgBouncer) in front; the app
   opens a connection per request today.
2. **Reads dominate** → Redis cache (Phase 3) removes most of this load; confirm
   by re-running with cache hit ratio >90%.
3. **Single writer ceiling** → this is the trigger for read replicas, and only
   then sharding (see `DB_EVOLUTION.md`).
4. **Latency grows with rows** → add covering indexes for the hot list query
   (`products(id)` is covered by PK; add `products(name)` if you filter).

## Clean up
```bash
kubectl -n demo delete job pgbench
```
