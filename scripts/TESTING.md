# Load & Capacity Testing Guide

All testing flows through one script:

```bash
./scripts/test-suite.sh <type> [options]
```

**Prereqs:** the app must be deployed (`./scripts/deploy-app.sh 3`) and `KUBECONFIG` set (the script defaults to `./kubeconfig` in the repo root).

---

## Test types

### 1. Ladder — VU ramp to find capacity ceiling

```bash
./scripts/test-suite.sh ladder          # 10 → 20 → 30 → 40 → 50 → 60
VUS=100 ./scripts/test-suite.sh ladder  # up to 100 VUs
STEP=20 ./scripts/test-suite.sh ladder  # custom step size
```

### 2. Single run — fixed VU count

```bash
./scripts/test-suite.sh single          # 30 VUs, 1m ramp, 2m hold
VU=50 HOLD=3m ./scripts/test-suite.sh single
```

### 3. DB benchmark — pgbench sweep (Postgres + Redis)

```bash
./scripts/test-suite.sh db
SCALES="5000 50000" CLIENTS="20 80" DURATION=30 ./scripts/test-suite.sh db
```

### 5. Smoke test — health check + 1 request

```bash
./scripts/test-suite.sh smoke
```

### 6. Custom — full env-var control

```bash
TRACE=true ./scripts/test-suite.sh custom
VUS=80 RAMP=30s HOLD=5m TRACE=true TARGET_URL=http://demo-shop.demo.svc.cluster.local \
  ./scripts/test-suite.sh custom
```

### 7. HPA watch — autoscaling live

```bash
VUS=40 ./scripts/test-suite.sh hpa
```

### 8. Metrics snapshot

```bash
./scripts/test-suite.sh metrics    # top nodes/pods, HPA, pod list
```

### 9. Report — collect k6 job logs

```bash
./scripts/test-suite.sh report     # saves to ./results/
```

### 10. All-in-one

```bash
./scripts/test-suite.sh all        # smoke → ladder → db → report
```

---

## Environment variables

| Variable | Default | Used by | Description |
|---|---|---|---|
| `VUS` | 60 | ladder, custom | Max VUs for the ladder |
| `VU` | 30 | single | Fixed VU count |
| `RAMP` | 1m | all | Ramp-up duration |
| `HOLD` | 2m | all | Steady-state duration |
| `STEP` | 10 | ladder | VU increment |
| `TRACE` | false | custom | Export spans to Jaeger |
| `TARGET_URL` | `http://demo-shop.demo.svc.cluster.local` | custom, capacity | k6 target URL |
| `SCALES` | `1000 10000 100000` | db | pgbench row counts |
| `CLIENTS` | `10 50 100` | db | pgbench concurrency |
| `DURATION` | 60 | db | Seconds per pgbench step |
| `DRY_RUN` | false | all | Print commands, don't execute |
| `REPORT_DIR` | `./results` | report | Where to save logs |

---

## Watch while a run is active (separate terminals)

```bash
kubectl -n demo get hpa demo-shop --watch
kubectl -n demo get pods -w
kubectl -n demo top nodes
kubectl -n demo top pods
```

---

## Reading the results

Each k6 run ends with a line like:

```
SUMMARY p50=70 p90=305 p95=609 RPS=25.09 ERR=0.00%
```

| Metric | Meaning |
|---|---|
| `p50` | Median response time (ms) |
| `p90` | 90th-percentile response time (ms) |
| `p95` | 95th-percentile response time (ms) |
| `RPS` | Requests per second (throughput) |
| `ERR` | Error rate (%) |

### What to look for

- **Capacity ceiling**: the VU level where RPS plateaus and p95 climbs sharply.
- **Scaling confirmation**: HPA should show replicas increasing with VU count.
- **Error onset**: ERR should stay at 0.00%; any non-zero value means the system is saturated.

---

## Typical workflow

```bash
# 1. Deploy the app
./scripts/deploy-app.sh 3

# 2. Quick smoke test
./scripts/test-suite.sh smoke

# 3. Find the ceiling
./scripts/test-suite.sh ladder

# 4. Watch scaling at a high VU level
VUS=60 ./scripts/test-suite.sh hpa

# 5. DB-only bottleneck check
./scripts/test-suite.sh db

# 6. Collect all logs
./scripts/test-suite.sh report
```

---

## Tracing (optional)

Enable `TRACE=true` to export k6 spans to Jaeger:

```bash
TRACE=true VUS=30 ./scripts/test-suite.sh custom
```

Open Jaeger UI:
```bash
kubectl -n demo port-forward svc/jaeger 16686:16686
# → http://localhost:16686
```

---

## Clean up test jobs

```bash
kubectl -n demo delete jobs -l app=k6
kubectl -n demo delete jobs -l app=pgbench
```
